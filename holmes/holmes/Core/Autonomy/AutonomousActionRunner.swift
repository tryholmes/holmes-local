import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - AutonomousActionRunner
// The ORCHESTRATOR of the autonomy pipeline: takes ActionPlanner's inert
// ActionPlan and runs it end to end under the gates. Division of labor:
//   • AutonomyPolicy  — the global "Autonomous actions" master switch (default
//     OFF) and the per-playbook Observe/Draft/Confirm/Auto level.
//   • AutonomyGate    — mayAct (master + enabled + level + rate budget),
//     requiresConfirmation (the irreversible-confirm invariant), and
//     recipientGrounded (send recipients ⊆ observed addresses).
//   • BackendRouter   — dispatches ONE step to the right actuator (computer /
//     app / composio) with its own fail-closed backstop (`confirmMarker`) and
//     returns undo closures for structured file ops.
//   • HolmesBrain.run — the model screenshot→act loop, used for the steps a
//     static plan literally cannot pre-compute: pointing verbs with no
//     coordinate (the Finder drag has no API and no pre-known pixels). The
//     loop brings its own live gates — ComputerUseEngine.isIrreversible AX
//     checks at click time, MCP approval cards — so a planned send that got
//     approved as an INTENT still re-confirms as the ACTUAL click.
//   • This class     — level semantics (.confirm = whole plan on ONE
//     ConfirmationBus card; .auto = free reversible steps, one card per
//     gate-flagged step), the ⌘⌥Esc check between steps, the durable
//     MemoryStore "action" trail, the completion notification, and the
//     "undo last run" affordance built from collected undo closures.

// MARK: - AutonomyGate.isMasterEnabled (glue)

extension AutonomyGate {
    /// The master-switch alias BackendRouter re-checks at dispatch time.
    /// Delegates to AutonomyPolicy — the single source of truth — so Settings,
    /// the entry gate (mayAct), and mid-run dispatch can never disagree.
    static var isMasterEnabled: Bool { AutonomyPolicy.shared.masterEnabled }
}

// MARK: - AutonomousActionRunner

/// Runs an ActionPlan end to end under the playbook's autonomy level.
/// @Observable so the MainPanel can show the status line and the undo affordance.
@MainActor
@Observable
final class AutonomousActionRunner {
    static let shared = AutonomousActionRunner()
    private init() {}

    // MARK: Published state

    /// Single-flight: one autonomous run at a time (PlaybookEngine.isExecuting
    /// already serializes fires; this guards manual/scheduled overlap too).
    private(set) var isRunning = false
    private(set) var isUndoing = false
    /// Live progress line for the MainPanel.
    private(set) var statusLine: String = ""
    /// Display record of the most recent run; `canUndoLastRun` sits beside it.
    private(set) var lastRun: CompletedRun?

    /// Collected inverses for the most recent run, consumed LIFO by undoLast().
    /// Off the observation graph — closures aren't display state.
    @ObservationIgnored private var undoActionsForLastRun: [UndoAction] = []
    @ObservationIgnored private var notificationPermissionRequested = false

    var canUndoLastRun: Bool { !undoActionsForLastRun.isEmpty }

    /// What the panel shows about the last completed (or aborted) run.
    struct CompletedRun {
        let goal: String
        let playbookId: String
        let finishedAt: Date
        let stepsExecuted: Int
        let stepsPlanned: Int
        let succeeded: Bool
        /// "done", "cancelled (⌘⌥Esc)", "declined", "step failed: …", …
        let note: String
    }

    /// One best-effort inverse, run LIFO by undoLast(). Bodies come from
    /// BackendRouter.StepResult.undo (move-back / restore-from-Trash) plus the
    /// runner's own ⌘Z inverse for direct typing.
    private struct UndoAction {
        let summary: String
        let body: () async -> Void
    }

    // MARK: - Run

    /// Executes `plan` under the playbook's level.
    ///   .observe — records what WOULD run (executes nothing) and returns.
    ///   .draft   — refuses: draft plans belong to PlaybookEngine's draft path.
    ///   .confirm — presents the WHOLE plan via ConfirmationBus.decide and runs
    ///              every step on that one approval.
    ///   .auto    — runs reversible steps freely; a step the gate/router flags
    ///              raises a single ConfirmationBus card for THAT step.
    /// Honors ⌘⌥Esc between steps, logs every executed step to MemoryStore
    /// (kind "action") with what + when + reversibility, fires a notification
    /// on completion, and collects undo closures for undoLast(). Sends can only
    /// pass through AutonomyGate.recipientGrounded + a confirmation surface.
    func run(_ plan: ActionPlan, playbookId: String, level: AutonomyLevel) async {
        guard !isRunning, !isUndoing else {
            print("[Holmes] Autonomy: skipped '\(playbookId)' — another run is in flight")
            return
        }
        guard !plan.steps.isEmpty else { return }

        // Observe: log the would-have plan for trust-building, execute nothing.
        // Allowed even while the master switch is off — observing is not an
        // action, and this log is how the user decides to opt a playbook in.
        if level == .observe {
            let listing = plan.steps.enumerated()
                .map { "\($0.offset + 1). \($0.element.summary)" }
                .joined(separator: " · ")
            await MemoryStore.shared.record(
                kind: "action",
                app: ScreenEngine.shared.latestActiveApp,
                activity: "autonomy-observed",
                summary: "Observed (not executed): \(shorten(plan.goal, max: 120))",
                detail: "playbook=\(playbookId) level=observe steps=\(plan.steps.count)\n\(listing)")
            print("[Holmes] Autonomy: observe-only — logged plan for '\(playbookId)', nothing executed")
            return
        }

        // Draft plans never reach the runner — that's PlaybookEngine's surface.
        if level == .draft {
            print("[Holmes] Autonomy: routing bug — draft-level plan for '\(playbookId)' sent to the runner; use the draft pipeline")
            return
        }

        // The entry gate: global master switch (default OFF), the playbook's
        // own enable, effective level ≥ .confirm, and the hourly rate budget.
        guard AutonomyGate.mayAct(playbookId: playbookId) else {
            print("[Holmes] Autonomy: refused '\(playbookId)' — AutonomyGate.mayAct said no (master switch, level, enable, or rate budget)")
            return
        }

        // Recipient grounding BEFORE anything runs: every structured recipient
        // in every step must appear in plan.knownAddresses — the set the
        // planner extracted from OBSERVED context, never from model prose. One
        // ungrounded address kills the whole run, at every level.
        for step in plan.steps where !AutonomyGate.recipientGrounded(step, knownAddresses: plan.knownAddresses) {
            await recordRunNote(playbookId: playbookId, plan: plan,
                                summary: "Autonomy run refused — ungrounded recipient",
                                detail: "step '\(step.summary)' addresses someone not present in observed context")
            postNotification(title: "Holmes stopped an automation",
                             body: "A step addressed someone not present in what Holmes observed. Nothing was sent.")
            print("[Holmes] Autonomy: grounding refusal — '\(step.summary)'")
            return
        }

        // ── PREFLIGHT ───────────────────────────────────────────────────────
        // Refuse a run that CANNOT succeed before it narrates "On it", consumes
        // rate budget, or half-executes and dies at step 3 — the honest fix for
        // "it keeps saying step failed". The refusal is user-visible with the
        // exact missing thing.
        if let reason = await preflightFailure(plan: plan) {
            await recordRunNote(playbookId: playbookId, plan: plan,
                                summary: "Autonomy run refused — preflight",
                                detail: reason)
            postNotification(title: "Holmes can't run this yet", body: String(reason.prefix(140)))
            print("[Holmes] Autonomy: preflight refusal — \(reason)")
            return
        }

        // Composio steps need the MCP host up before the router can resolve
        // tools (an unresolvable tool classifies as needs-confirm, fail closed).
        let composioApps = DefaultPlaybooks.all.first(where: { $0.id == playbookId })?.composioApps ?? []
        if plan.steps.contains(where: { $0.backend.lowercased() == "composio" }) {
            await MCPClient.shared.startAll() // no-op if already started
        }

        isRunning = true
        defer { isRunning = false }
        AutonomyGate.recordAct(playbookId: playbookId) // consume rate budget once per started run
        statusLine = "Running: \(shorten(plan.goal, max: 80))"
        // Fresh actuator session: clears a stale ⌘⌥Esc flag and the stale
        // screenshot so nothing maps coordinates against an old frame.
        ComputerUseEngine.shared.beginRun()
        ScreenGlowController.shared.set(state: .thinking)

        // Speak the opening intent — "On it — <goal>." — so the run announces
        // itself before the first action lands.
        narrate("On it — \(shorten(plan.goal, max: 90)).")
        // Light up the notch HUD: WHAT Holmes is doing, over the live context.
        NotchWindowController.shared.beginTask(shorten(plan.goal, max: 70))

        // .confirm — the WHOLE plan on one card; that single approval covers
        // the run (BackendRouter's userConfirmed contract names this exact case).
        let wholePlanApproved: Bool
        if level == .confirm {
            guard await approveWholePlan(plan, playbookId: playbookId, composioApps: composioApps) else {
                await finishRun(plan: plan, playbookId: playbookId, executed: 0,
                                succeeded: false, note: "declined", notifyBody: nil)
                return
            }
            wholePlanApproved = true
        } else {
            wholePlanApproved = false
        }

        var executedCount = 0
        var failedStepCount = 0   // steps that failed even after a retry — skipped, not fatal
        undoActionsForLastRun = []

        for segment in Self.segmentize(plan.steps) {
            // Kill switch between steps: ⌘⌥Esc aborts before the NEXT dispatch.
            if ComputerUseEngine.shared.isCancelled {
                await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                succeeded: false, note: "cancelled (⌘⌥Esc)",
                                notifyBody: "Stopped by the kill switch after \(executedCount) of \(plan.steps.count) steps.")
                return
            }

            switch segment {
            case .router(let step):
                // .auto: a gate/router-flagged step pauses for ONE card, just
                // for itself. (.confirm already approved the whole plan.)
                var confirmed = wholePlanApproved
                if !confirmed, BackendRouter.requiresConfirmation(step, composioApps: composioApps) {
                    guard await approveStep(step) else {
                        await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                        succeeded: false, note: "step declined",
                                        notifyBody: "You declined “\(shorten(step.summary, max: 60))”. The run stopped there.")
                        return
                    }
                    confirmed = true
                }
                // Narrate the step as it starts (after any confirm), one line.
                narrateStep(step)
                NotchWindowController.shared.stepProgress(
                    shorten(step.summary, max: 60),
                    fraction: Double(executedCount) / Double(max(1, plan.steps.count)))
                var result = await BackendRouter.run(step, composioApps: composioApps, userConfirmed: confirmed)
                // The router's fail-closed backstop can flag a confirm the
                // pre-check missed (dispatch-time knowledge). Honor its
                // protocol: raise the card now and retry exactly once.
                if !result.ok, result.text.hasPrefix(BackendRouter.confirmMarker), !confirmed {
                    guard await approveStep(step) else {
                        await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                        succeeded: false, note: "step declined",
                                        notifyBody: "You declined “\(shorten(step.summary, max: 60))”. The run stopped there.")
                        return
                    }
                    result = await BackendRouter.run(step, composioApps: composioApps, userConfirmed: true)
                }
                // One flaky step must not kill the whole task. A transient miss (a
                // slow UI, a stale coordinate, a control not yet on screen) usually
                // clears on a second try — so retry ONCE, and if it still fails, log
                // it and move on to the next step rather than aborting the run. The
                // end-of-run summary reports how many steps were skipped.
                if !result.ok {
                    let retry = await BackendRouter.run(step, composioApps: composioApps, userConfirmed: confirmed)
                    if retry.ok {
                        result = retry
                    } else {
                        failedStepCount += 1
                        await logExecutedStep(step, playbookId: playbookId, level: level, via: "router",
                                              ok: false, confirmed: confirmed, note: retry.text)
                        continue
                    }
                }
                await logExecutedStep(step, playbookId: playbookId, level: level, via: "router",
                                      ok: true, confirmed: confirmed, note: nil)
                statusLine = shorten(result.text, max: 100)
                collectUndo(for: step, routerUndo: result.undo)
                executedCount += 1

            case .model(let steps):
                // .auto: every gate-flagged step in the segment gets its single
                // card BEFORE the loop starts — the user approves the planned
                // irreversible INTENTS up front; the loop's live AX/MCP gates
                // still re-confirm the actual send at execution time.
                if !wholePlanApproved {
                    for step in steps where BackendRouter.requiresConfirmation(step, composioApps: composioApps) {
                        guard await approveStep(step) else {
                            await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                            succeeded: false, note: "step declined",
                                            notifyBody: "You declined “\(shorten(step.summary, max: 60))”. The run stopped there.")
                            return
                        }
                    }
                }
                // Narrate the visible on-screen work about to happen (high-level).
                narrate(shorten(steps.first?.summary ?? "Working on the next steps.", max: 110))
                NotchWindowController.shared.stepProgress(
                    shorten(steps.first?.summary ?? "Working…", max: 60),
                    fraction: Double(executedCount) / Double(max(1, plan.steps.count)))
                let error = await executeModelSegment(steps, plan: plan, playbookId: playbookId)
                for step in steps {
                    await logExecutedStep(step, playbookId: playbookId, level: level, via: "model-loop",
                                          ok: error == nil, confirmed: wholePlanApproved, note: error)
                }
                if let error {
                    await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                    succeeded: false, note: "segment failed: \(shorten(error, max: 120))",
                                    notifyBody: shorten(error, max: 120))
                    return
                }
                // A ⌘⌥Esc that landed MID-loop surfaces here after the loop
                // wound down — report honestly instead of counting the segment.
                if ComputerUseEngine.shared.isCancelled {
                    await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                                    succeeded: false, note: "cancelled (⌘⌥Esc)",
                                    notifyBody: "Stopped by the kill switch mid-run.")
                    return
                }
                executedCount += steps.count
            }
        }

        let undoHint = undoActionsForLastRun.isEmpty ? "" : " Undo is available in the Holmes panel."
        let skipHint = failedStepCount == 0 ? "" : " \(failedStepCount) step\(failedStepCount == 1 ? "" : "s") skipped."
        await finishRun(plan: plan, playbookId: playbookId, executed: executedCount,
                        succeeded: true, note: failedStepCount == 0 ? "done" : "done (\(failedStepCount) skipped)",
                        notifyBody: "\(executedCount) of \(plan.steps.count) steps completed.\(skipHint)\(undoHint)")
    }

    // MARK: - Undo

    /// Runs the collected inverses of the most recent run, newest first (LIFO),
    /// then consumes them — one undo per run, like a single ⌘Z at plan scale.
    /// Best-effort by design: file moves/trashes come back via BackendRouter's
    /// real undo closures; direct typing gets a refocus + ⌘Z; everything else
    /// was either harmless (opens, reads) or user-confirmed before it ran.
    func undoLast() async {
        guard !isRunning, !isUndoing, let run = lastRun, !undoActionsForLastRun.isEmpty else { return }
        isUndoing = true
        defer { isUndoing = false }
        statusLine = "Undoing: \(shorten(run.goal, max: 80))"
        // Undo is user-initiated — clear a stale kill flag so it can post events.
        ComputerUseEngine.shared.beginRun()

        var attempted = 0
        for action in undoActionsForLastRun.reversed() {
            if ComputerUseEngine.shared.isCancelled { break }
            await action.body()
            attempted += 1
            await MemoryStore.shared.record(
                kind: "action",
                app: ScreenEngine.shared.latestActiveApp,
                activity: "autonomy-undo",
                summary: "Undid: \(shorten(action.summary, max: 120))",
                detail: "playbook=\(run.playbookId) run=\(shorten(run.goal, max: 120))")
        }
        undoActionsForLastRun = []
        statusLine = "Undid \(attempted) step\(attempted == 1 ? "" : "s")"
        postNotification(title: "Holmes undid the last run",
                         body: "\(attempted) step\(attempted == 1 ? "" : "s") reversed — \(shorten(run.goal, max: 80))")
        print("[Holmes] Autonomy: undo — reversed \(attempted) step(s) of '\(run.playbookId)'")
    }

    /// Stashes the step's inverse, when one exists. BackendRouter supplies real
    /// closures for structured file ops (move back / restore from Trash); the
    /// runner adds a refocus-then-⌘Z inverse for direct typing, captured with
    /// the app that was frontmost AT EXECUTION TIME so an undo hours later
    /// still targets the right app. Opens/keys/reads get no closure — closing
    /// a window the user may now be working in is not "undo".
    private func collectUndo(for step: PlannedStep, routerUndo: (() async -> Void)?) {
        if let routerUndo {
            undoActionsForLastRun.append(UndoAction(summary: step.summary, body: routerUndo))
            return
        }
        guard step.action == "type" else { return }
        let appAtExecution = ScreenEngine.shared.latestActiveApp
        undoActionsForLastRun.append(UndoAction(
            summary: step.summary,
            body: { @MainActor in
                if !appAtExecution.isEmpty {
                    _ = await ComputerUseEngine.shared.perform(
                        action: "open_app", input: ["name": appAtExecution])
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
                _ = await ComputerUseEngine.shared.perform(
                    action: "key", input: ["text": "cmd+z"])
            }))
    }

    // MARK: - Segmentation

    /// How steps get executed. Pre-planned steps go one at a time through
    /// BackendRouter; a CONTIGUOUS run of steps that need live sight becomes
    /// one HolmesBrain screenshot→act session scoped to exactly those steps.
    private enum Segment {
        case router(PlannedStep)
        case model([PlannedStep])
    }

    /// The pointing verbs whose coordinates only exist against a live frame.
    private static let pointingVerbs: Set<String> = [
        "mouse_move", "left_click", "right_click", "middle_click", "double_click",
        "triple_click", "left_mouse_down", "left_mouse_up", "left_click_drag", "scroll"
    ]

    /// A step no static plan can carry to completion: a pointing verb with no
    /// pre-supplied coordinate. The model loop must SEE the screen to place it
    /// (the Finder drag is the canonical case — no API, no pre-known pixels).
    private static func needsLiveSight(_ step: PlannedStep) -> Bool {
        pointingVerbs.contains(step.action) && step.input["coordinate"] == nil
    }

    /// Groups the ordered steps, preserving order — "open Finder (router),
    /// drag the file (model), press ⌘W (router)" stays three dispatches.
    private static func segmentize(_ steps: [PlannedStep]) -> [Segment] {
        var segments: [Segment] = []
        var pendingModel: [PlannedStep] = []
        for step in steps {
            if needsLiveSight(step) {
                pendingModel.append(step)
            } else {
                if !pendingModel.isEmpty {
                    segments.append(.model(pendingModel))
                    pendingModel = []
                }
                segments.append(.router(step))
            }
        }
        if !pendingModel.isEmpty { segments.append(.model(pendingModel)) }
        return segments
    }

    // MARK: - Model-driven execution

    /// Executes a contiguous run of live-sight steps through the existing
    /// HolmesBrain screenshot→act loop — the model drives Clicky against real
    /// frames, exactly the product's core loop. The goal is scoped HARD to the
    /// listed steps, and the loop brings its own gates: irreversible pixel
    /// actions re-confirm via ConfirmationBus at click time (live AX label,
    /// not planned intent), and non-read-only MCP tools raise approval cards.
    /// Returns nil on success, else a human-readable error.
    private func executeModelSegment(_ steps: [PlannedStep], plan: ActionPlan,
                                     playbookId: String) async -> String? {
        let listing = steps.enumerated()
            .map { index, step in
                "\(index + 1). \(step.summary) (verb hint: \(step.backend)/\(step.action))"
            }
            .joined(separator: "\n")

        // The grounding constraint travels INTO the loop as an explicit order:
        // the only addresses the model may ever use are the observed ones.
        let grounding: String
        if plan.knownAddresses.isEmpty {
            grounding = "\n- You may NOT address any email or message to anyone: no recipient appeared in the observed context."
        } else {
            grounding = "\n- Any email/message may ONLY be addressed to: \(plan.knownAddresses.sorted().joined(separator: ", ")). Never introduce another recipient."
        }

        let goal = """
        You are executing part of an approved automation plan (playbook '\(playbookId)'). Overall goal: \(plan.goal)

        Perform EXACTLY these steps, in order, and nothing else:
        \(listing)

        Rules:
        - Do not add work beyond what completing these steps strictly requires (screenshots, cursor moves, and short waits are fine).
        - Take a screenshot before any click so coordinates map against a real frame.
        - If a step cannot be completed, STOP and report what happened instead of improvising a different route.\(grounding)
        """

        let result = await HolmesBrain.shared.run(goal: goal, narrateAloud: false) { [weak self] text in
            // Live progress for the MainPanel; the tail is the informative part.
            // narrateAloud:false — this runner already narrates each step aloud.
            self?.statusLine = String(text.suffix(160))
        }
        switch result {
        case .notConfigured:
            return "no Anthropic API key configured"
        case .text(let text):
            statusLine = shorten(text, max: 160)
            // Honest accounting: an API failure or an explicit model-reported
            // inability used to come back as "success" (the run then notified
            // "completed" over work that never happened).
            if text.hasPrefix("Claude API error") || text.hasPrefix("Holmes declined:") {
                return shorten(text, max: 160)
            }
            return nil
        }
    }

    // MARK: - Preflight

    /// The verbs the app lane can actually execute (BackendRouter.runApp).
    private static let appLaneActions: Set<String> = [
        "open_app", "open_url", "reveal_file", "move_file", "trash_file",
        "applescript", "create_folder", "join_meeting", "calendar_create_event",
        "ax_press", "ax_type"
    ]
    private static let appLaneBackends: Set<String> = [
        "app", "nsworkspace", "workspace", "file", "files", "fs",
        "finder", "filesystem", "applescript", "eventkit", "calendar", "ax"
    ]
    private static let composioBackends: Set<String> = ["composio", "mcp", "api"]
    private static let mutatingComputerVerbs: Set<String> = [
        "left_click", "right_click", "middle_click", "double_click",
        "triple_click", "left_mouse_down", "left_mouse_up", "left_click_drag",
        "scroll", "key", "hold_key", "type", "mouse_move"
    ]

    /// One reason this plan cannot succeed, or nil when it may run. Every check
    /// mirrors a failure the run would otherwise hit MID-EXECUTION.
    private func preflightFailure(plan: ActionPlan) async -> String? {
        let segments = Self.segmentize(plan.steps)
        let hasModelSegment = segments.contains { if case .model = $0 { return true }; return false }
        var needsComputerControl = hasModelSegment
        var needsAccessibility = hasModelSegment

        for step in plan.steps {
            let backend = step.backend.lowercased()
            if Self.appLaneBackends.contains(backend) {
                if !Self.appLaneActions.contains(step.action) {
                    return "the plan uses an action ('\(step.action)') Holmes has no executor for"
                }
                if step.action == "ax_press" || step.action == "ax_type" {
                    needsAccessibility = true
                }
                // File preconditions, hoisted: fail at step 0, not step 3.
                if step.action == "move_file" || step.action == "trash_file" {
                    let source = (step.input["from"] as? String) ?? (step.input["path"] as? String) ?? ""
                    if !source.isEmpty {
                        let expanded = (source as NSString).expandingTildeInPath
                        if !FileManager.default.fileExists(atPath: expanded) {
                            return "file not found at \(source)"
                        }
                    }
                }
            } else if !Self.composioBackends.contains(backend) {
                // Computer lane (including unknown backends, which route there).
                needsComputerControl = true
                if Self.mutatingComputerVerbs.contains(step.action) { needsAccessibility = true }
                // A planner-supplied coordinate is text-derived fiction mapped
                // against a nil capture — it fails twice and gets skipped.
                if Self.pointingVerbs.contains(step.action), step.input["coordinate"] != nil {
                    return "the plan contains a click at an invented coordinate — replanning is needed"
                }
            }
        }

        if needsComputerControl, !ComputerUseEngine.shared.isEnabled {
            return "Computer control is off — enable it in Settings ▸ Privacy ▸ Computer control"
        }
        if needsAccessibility, !PermissionManager.checkAccessibilityPermission() {
            return PermissionManager.needsRelaunchForAccessibility()
                ? "Accessibility was granted but macOS applies it only after a relaunch — click Relaunch Holmes in Settings ▸ Privacy"
                : "Accessibility permission is missing — System Settings ▸ Privacy & Security ▸ Accessibility"
        }
        if hasModelSegment {
            guard AnthropicConfig.isConfigured else { return "no Anthropic API key is configured" }
            if await WindowCapture.captureForModel() == nil {
                return "screen capture isn't working — Screen Recording permission is missing or stale (relaunch Holmes after granting)"
            }
        }
        return nil
    }

    // MARK: - Approval cards (the draft flow's ConfirmationBus surface)

    /// .confirm level: the whole plan on ONE card. ConfirmationBus.decide
    /// suspends until the user clicks Approve (actionType .agentToolCall) or
    /// dismisses — the same awaitable card HolmesBrain uses for tool calls.
    /// Steps the .auto gate would flag are marked [confirm] so the dangerous
    /// ones are visible at a glance. Edits to the preview text are ignored —
    /// the card shows a RENDERING of the steps, it is not the steps.
    private func approveWholePlan(_ plan: ActionPlan, playbookId: String,
                                  composioApps: [String]) async -> Bool {
        let listing = plan.steps.enumerated()
            .map { index, step in
                let mark = BackendRouter.requiresConfirmation(step, composioApps: composioApps)
                    ? "[confirm]" : "[auto]"
                return "\(index + 1). \(mark) \(step.summary)"
            }
            .joined(separator: "\n")
        let rationale = plan.rationale.isEmpty ? "" : "\n\nWHY THIS ROUTE\n\(shorten(plan.rationale, max: 300))"
        let preview = """
        GOAL
        \(plan.goal)

        STEPS
        \(listing)\(rationale)

        Approve runs the whole plan. Steps that press Send/Delete still re-confirm at the moment they execute.
        """
        // Speak the ask alongside the card.
        narrate("Here's my plan for \(shorten(plan.goal, max: 70)) — want me to run it?")
        let action = PendingAction(
            title: "Run plan: \(shorten(plan.goal, max: 60))",
            preview: preview,
            appName: "your Mac",
            actionType: .agentToolCall)
        switch await ConfirmationBus.shared.decide(action) {
        case .approved: return true
        case .dismissed: return false
        }
    }

    /// .auto level: ONE card for the single gate-flagged step. Approve runs
    /// just this step; Dismiss stops the whole run (later steps almost always
    /// depend on the declined one).
    private func approveStep(_ step: PlannedStep) async -> Bool {
        let preview = """
        \(step.summary)

        This step is irreversible or outward-facing, so Holmes pauses for your OK. Approve runs just this step; Dismiss stops the run.
        """
        // Speak the confirm prompt alongside the card ("this one sends… go ahead?").
        narrateConfirm(step)
        let frontApp = ScreenEngine.shared.latestActiveApp
        let action = PendingAction(
            title: "Holmes wants to: \(shorten(step.summary, max: 60))",
            preview: preview,
            appName: frontApp.isEmpty ? "your Mac" : frontApp,
            actionType: .agentToolCall)
        switch await ConfirmationBus.shared.decide(action) {
        case .approved: return true
        case .dismissed: return false
        }
    }

    // MARK: - Memory + notifications + bookkeeping

    /// Every EXECUTED step becomes a durable "action" row: what (summary/verb),
    /// when (the row's own timestamp + ISO in detail), and whether it was
    /// reversible/confirmed — the audit trail Recall reads back later.
    /// (BackendRouter also writes a terse "Auto:" row for mutating successes;
    /// this one carries the playbook/level/reversibility provenance.)
    private func logExecutedStep(_ step: PlannedStep, playbookId: String,
                                 level: AutonomyLevel, via: String,
                                 ok: Bool, confirmed: Bool, note: String?) async {
        let when = ISO8601DateFormatter().string(from: Date())
        await MemoryStore.shared.record(
            kind: "action",
            app: ScreenEngine.shared.latestActiveApp,
            activity: "autonomy",
            summary: "\(ok ? "Did" : "Failed"): \(shorten(step.summary, max: 200))",
            detail: "playbook=\(playbookId) level=\(level.rawValue) backend=\(step.backend) "
                + "action=\(step.action) reversible=\(step.reversible) confirmed=\(confirmed) "
                + "via=\(via) when=\(when)\(note.map { "\nnote: \(String($0.prefix(300)))" } ?? "")")
    }

    /// A run-level note (refusals, blocks) that never executed anything.
    private func recordRunNote(playbookId: String, plan: ActionPlan,
                               summary: String, detail: String = "") async {
        await MemoryStore.shared.record(
            kind: "action",
            app: ScreenEngine.shared.latestActiveApp,
            activity: "autonomy",
            summary: summary,
            detail: "playbook=\(playbookId) goal=\(shorten(plan.goal, max: 200))"
                + (detail.isEmpty ? "" : "\n\(detail)"))
    }

    /// Shared epilogue: records the outcome, fires the completion notification,
    /// publishes the CompletedRun for the panel, settles the glow.
    private func finishRun(plan: ActionPlan, playbookId: String, executed: Int,
                           succeeded: Bool, note: String, notifyBody: String?) async {
        lastRun = CompletedRun(
            goal: plan.goal,
            playbookId: playbookId,
            finishedAt: Date(),
            stepsExecuted: executed,
            stepsPlanned: plan.steps.count,
            succeeded: succeeded,
            note: note)
        statusLine = succeeded
            ? "Done: \(shorten(plan.goal, max: 80))"
            : "Stopped (\(note)): \(shorten(plan.goal, max: 60))"
        await MemoryStore.shared.record(
            kind: "action",
            app: ScreenEngine.shared.latestActiveApp,
            activity: "autonomy",
            summary: "\(succeeded ? "Completed" : "Stopped") autonomous run: \(shorten(plan.goal, max: 160))",
            detail: "playbook=\(playbookId) outcome=\(note) executed=\(executed)/\(plan.steps.count)")
        if let notifyBody {
            postNotification(
                title: succeeded
                    ? "Holmes finished: \(shorten(plan.goal, max: 50))"
                    : "Holmes stopped: \(shorten(plan.goal, max: 50))",
                body: notifyBody)
        }
        ScreenGlowController.shared.set(state: succeeded ? .ready : .off)
        // Close out the notch HUD with a result banner (auto-returns to idle).
        NotchWindowController.shared.endTask(success: succeeded, summary: shorten(plan.goal, max: 70))
        // Speak the closing result. Quiet on a user decline (they just said no).
        if succeeded {
            narrate("Done — \(shorten(plan.goal, max: 70)).")
        } else if note.hasPrefix("cancelled") {
            narrate("Stopped.")
        } else if note != "declined", note != "step declined" {
            narrate("I had to stop. \(shorten(note, max: 60)).")
        }
        print("[Holmes] Autonomy: '\(playbookId)' \(succeeded ? "completed" : "stopped (\(note))") — \(executed)/\(plan.steps.count) steps")
    }

    // Same UNUserNotificationCenter idiom as PlaybookEngine / MeetingJoinEngine:
    // one authorization request per session, nil trigger = fire immediately.
    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("[Holmes] Autonomy notifications: \(granted ? "granted" : "denied")")
        }
    }

    private func postNotification(title: String, body: String) {
        requestNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "Autonomous action"
        content.body = String(body.prefix(140))
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "holmes-autonomy-\(UUID().uuidString)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[Holmes] Autonomy notification error: \(error)") }
        }
    }

    private func shorten(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }

    // MARK: - Narration (Clicky speaks what it's doing)

    /// Speaks a short, HIGH-LEVEL line of what Clicky is about to do — one line
    /// per step ("Opening Finder", "Moving the images into a new folder"), plus
    /// the run's opening/closing and any confirm prompt. Gated by the "Clicky
    /// narrates actions" pref (default ON). Fire-and-forget so speaking never
    /// delays the action; `SpeechSynthesizer.speak` supersedes (ducks) any prior
    /// line so two narrations never overlap.
    private func narrate(_ line: String) {
        guard ClickyController.shared.narrateActionsEnabled else { return }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // .status: run narration coalesces (only the latest queued line
        // matters) and never cuts audio mid-word — fast step sequences used to
        // truncate every line at the mouth of the last-wins synthesizer.
        SpeechSynthesizer.shared.enqueue(text, priority: .status)
    }

    /// The one-line narration for a step about to run. Uses the step's own summary
    /// (already human-readable, written for the confirm card).
    private func narrateStep(_ step: PlannedStep) {
        narrate(shorten(step.summary, max: 120))
    }

    /// Spoken alongside a confirmation card, matching the "this one sends/deletes —
    /// want me to go ahead?" product feel. The verb is inferred from the summary.
    private func narrateConfirm(_ step: PlannedStep) {
        let s = step.summary.lowercased()
        let phrase: String
        if s.contains("send") || s.contains("email") || s.contains("message") || s.contains("reply") || s.contains("post") {
            phrase = "This one sends something"
        } else if s.contains("delete") || s.contains("trash") || s.contains("remove") || s.contains("archive") {
            phrase = "This one deletes something"
        } else {
            phrase = "This one can't be undone"
        }
        narrate("\(phrase) — want me to go ahead?")
    }
}
