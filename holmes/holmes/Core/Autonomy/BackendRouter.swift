import AppKit
import Foundation
import OSLog

// MARK: - BackendRouter
// Executes ONE PlannedStep via the right actuator. This is pure dispatch + a
// fail-closed safety floor — it plans nothing and loops nothing. The step type is
// the SHARED `PlannedStep` (declared in AutonomyGate.swift: action, input
// [String: Any], backend, reversible, summary); this file deliberately declares no
// step type of its own so the whole Autonomy pipeline speaks one shape.
//
// Routing (COMPUTER-CONTROL PRIMARY — the locked product decision):
//   "app" lane      → NSWorkspace launch/open + structured file ops (move/trash
//                     WITH a real undo closure) + a small AppleScript lane for
//                     reversible app ops. Used only where a structured API is
//                     clearly better/safer than pixels.
//   "composio" lane → an MCP/Composio tool call for API actions, dispatched
//                     through the exact host path HolmesBrain's tool loop uses
//                     (MCPClient.shared.call) and re-validated at dispatch time
//                     through ComposioCatalog (validateMetaExecute /
//                     isPlaybookSafe / readOnlyHint).
//   everything else → ComputerUseEngine.shared.perform(action:input:) — Clicky,
//                     the universal actuator and the DEFAULT for any backend
//                     string the router doesn't recognize (the Finder example has
//                     no API; pixels always exist).
//
// Safety floor, enforced even when a caller forgets to pre-check:
//   1. GLOBAL MASTER RE-CHECK — AutonomyGate.mayAct gates the run before planning,
//      but the user can flip "Autonomous actions" OFF mid-plan; every MUTATING
//      step re-checks AutonomyPolicy.shared.masterEnabled at dispatch. Read-only
//      (screenshot / cursor_position / wait, read-only Composio calls) run
//      regardless — the same line draft mode draws today. Computer mutations are
//      additionally gated by ComputerUseEngine's own master switch inside
//      `perform`, so an autonomous pixel mutation needs BOTH switches on.
//   2. IRREVERSIBLE-CONFIRM BACKSTOP — the evolved draft-never-send invariant.
//      Before dispatch, a step that `requiresConfirmation` (AutonomyGate's .auto
//      ground truth: ComputerUseEngine.isIrreversible, the SEND_RE verb lines,
//      the file-move policy — plus this file's Composio inner-slug and
//      AppleScript-source checks) is REFUSED unless the caller passes
//      `userConfirmed: true` (i.e. the user approved it on a ConfirmationBus
//      card). The refusal text is prefixed with `confirmMarker` so the
//      orchestrator can branch "raise a card and retry" vs "report failure"
//      without parsing prose.
//
// @MainActor because every actuator it drives is main-actor bound
// (ComputerUseEngine, MCPClient, AutonomyGate) and it reads ScreenEngine state.
@MainActor
enum BackendRouter {

    // MARK: - StepResult

    /// The outcome of one executed step. `undo`, when present, best-effort reverts
    /// the step (today: moves a moved/trashed file back). The orchestrator can
    /// surface it as an "Undo" affordance; it is optional — most reversible steps
    /// are undone by the user directly in the app.
    struct StepResult {
        let ok: Bool
        let text: String
        let undo: (() async -> Void)?

        init(ok: Bool, text: String, undo: (() async -> Void)? = nil) {
            self.ok = ok
            self.text = text
            self.undo = undo
        }
    }

    // MARK: - Diagnostics

    private static let log = Logger(subsystem: "com.grain.holmes", category: "BackendRouter")

    private static func diag(_ message: String) {
        log.log("\(message, privacy: .public)")
        print("[BackendRouter] \(message)")
    }

    // MARK: - Confirm marker

    /// Prefix on `StepResult.text` when a step was refused ONLY because it needs a
    /// user confirmation (not because it failed). The orchestrator matches this,
    /// raises one ConfirmationBus card with `step.summary`, and on approval
    /// re-dispatches with `userConfirmed: true`.
    static let confirmMarker = "CONFIRM_REQUIRED: "

    private static func needsConfirm(_ step: PlannedStep, _ why: String) -> StepResult {
        diag("step '\(step.summary)' held for confirmation — \(why)")
        return StepResult(ok: false, text: confirmMarker + why)
    }

    private static func refusedByMasterSwitch(_ step: PlannedStep) -> StepResult {
        diag("step '\(step.summary)' REFUSED — Autonomous actions master switch OFF")
        return StepResult(
            ok: false,
            text: "Autonomous actions are off. Enable them in Settings ▸ Automations before Holmes can act on its own."
        )
    }

    // MARK: - Lanes

    /// The three actuator lanes. Backend strings normalize here — the planner emits
    /// "computer" / "nsworkspace" / "file" / "eventkit" / "composio", but the
    /// router also tolerates AutonomyGate's wider synonym sets so a step can never
    /// dodge a lane by spelling ("clicky", "app", "finder", "mcp").
    private enum Lane { case computer, app, composio }

    private static func lane(for backend: String) -> Lane {
        switch backend.lowercased() {
        // Structured native lane: NSWorkspace / FileManager / AppleScript /
        // EventKit / AX element actions. ("eventkit" was TAUGHT to the planner
        // but had no lane — every calendar step fell to pixels and failed with
        // "Unknown computer action". It routes here now.)
        case "app", "nsworkspace", "workspace", "file", "files", "fs",
             "finder", "filesystem", "applescript", "eventkit", "calendar", "ax":
            return .app
        // API lane: hosted Composio / any configured MCP server.
        case "composio", "mcp", "api":
            return .composio
        // COMPUTER-CONTROL PRIMARY: everything else — including "clicky",
        // "pixels", "screen" and any unknown backend string — is pixels. An
        // unroutable ACTION then fails with ComputerUseEngine's clear "unknown
        // action" error instead of silently doing nothing.
        default:
            return .computer
        }
    }

    // MARK: - Pre-flight classifier

    /// True when the step will be held for one explicit user confirm. The
    /// orchestrator calls this BEFORE run(_:) so it can raise the card up front
    /// (better UX than dispatch → refusal → card → re-dispatch); run(_:)
    /// re-checks regardless, so a caller that skips this stays safe.
    ///
    /// Composition: AutonomyGate.requiresConfirmation(step, level: .auto) is the
    /// shared ground truth (planner's negative claim, ComputerUseEngine's AX/chord
    /// classifier, the API verb tokens, the file-move policy). On top of it, two
    /// checks only this file can make because they need dispatch-level knowledge:
    ///   • Composio steps — the meta executor's INNER tool_slugs (the outer name
    ///     "COMPOSIO_MULTI_EXECUTE_TOOL" carries no verb) and direct tools'
    ///     read-only classification against the connected server's catalog;
    ///   • AppleScript steps — the SCRIPT SOURCE can name an outward verb the
    ///     action name ("applescript") never shows.
    static func requiresConfirmation(_ step: PlannedStep, composioApps: [String] = []) -> Bool {
        if AutonomyGate.requiresConfirmation(step, level: .auto) { return true }
        switch lane(for: step.backend) {
        case .composio:
            return composioNeedsConfirmation(step, composioApps: composioApps)
        case .app:
            if step.action == "applescript" {
                return matchesSendVerb(scriptSource(step.input))
            }
            if step.action == "ax_press" {
                // Pressing a send/submit-class button is the commit itself. The
                // executor matches button titles by SUBSTRING, so a fragment like
                // "Sen" or "end" would press Send while dodging a whole-word
                // check: any label that is a fragment of a commit verb, or too
                // short to be a real title, confirms as well.
                let label = (step.input["label"] as? String) ?? (step.input["button"] as? String) ?? ""
                return matchesSendVerb(label) || couldMatchCommitControl(label)
            }
            return false
        case .computer:
            return false // AutonomyGate already ran ComputerUseEngine.isIrreversible
        }
    }

    // MARK: - Dispatch

    /// Executes one step via the right actuator and returns the outcome. Never
    /// throws — every failure mode folds into StepResult so the orchestrator's
    /// loop stays simple.
    /// - composioApps: app scope for Composio validation (e.g. ["GMAIL"]), the
    ///   same list the step's playbook declares; [] = unscoped.
    /// - userConfirmed: true ONLY after the user approved THIS step (or the whole
    ///   plan, at the .confirm level) on a confirmation card. Unlocks the
    ///   irreversible/outward lane the router otherwise refuses.
    static func run(
        _ step: PlannedStep,
        composioApps: [String] = [],
        userConfirmed: Bool = false
    ) async -> StepResult {
        let lane = lane(for: step.backend)
        diag("run backend=\(step.backend) lane=\(lane) action=\(step.action) confirmed=\(userConfirmed) master=\(AutonomyPolicy.shared.masterEnabled)")

        // 1. Global master re-check for anything that changes state (mid-run OFF
        //    must stop the plan). Reads keep working, like draft mode today. The
        //    switch is AutonomyPolicy.shared.masterEnabled — the same source
        //    AutonomyGate.mayAct reads, so the entry gate and this per-step
        //    re-check can never disagree.
        if isMutating(step, lane: lane), !AutonomyPolicy.shared.masterEnabled {
            return refusedByMasterSwitch(step)
        }

        // 2. Irreversible-confirm backstop (fail closed). The orchestrator should
        //    have pre-checked and confirmed; if it didn't, the step is held here.
        if !userConfirmed, requiresConfirmation(step, composioApps: composioApps) {
            return needsConfirm(step, step.summary)
        }

        let result: StepResult
        switch lane {
        case .app:      result = await runApp(step, userConfirmed: userConfirmed)
        case .composio: result = await runComposio(step, composioApps: composioApps, userConfirmed: userConfirmed)
        case .computer: result = await runComputer(step)
        }

        // Memory: successful mutating steps join the durable record (kind
        // "action"), the same shape HolmesBrain writes for user-initiated runs —
        // so Recall can answer "what did Holmes do while I was away".
        if result.ok, isMutating(step, lane: lane) {
            let summary = String(step.summary.prefix(120))
            let detail = String(result.text.prefix(600))
            Task {
                await MemoryStore.shared.record(
                    kind: "action",
                    app: ScreenEngine.shared.latestActiveApp,
                    summary: "Auto: \(summary)",
                    detail: detail
                )
            }
        }
        return result
    }

    /// Whether a step changes anything — drives the master-switch re-check and the
    /// memory "action" log. Read-only computer primitives and read-only Composio
    /// calls are exempt; every app-lane op launches/opens/moves something.
    private static func isMutating(_ step: PlannedStep, lane: Lane) -> Bool {
        switch lane {
        case .app:
            return true
        case .composio:
            return !composioIsReadOnly(step)
        case .computer:
            return !["screenshot", "cursor_position", "wait"].contains(step.action)
        }
    }

    // MARK: - computer lane (the universal actuator)

    /// Passes the step straight through to ComputerUseEngine — master switch,
    /// permissions, kill switch, and coordinate mapping all live there. Two
    /// contracts a planner must respect:
    ///   • coordinate verbs map against the engine's `lastCapture`, so a plan must
    ///     interleave a "screenshot" step before its first pointing verb (the
    ///     engine errors clearly if it doesn't);
    ///   • StepResult carries no image — a plan that must SEE the screenshot to
    ///     choose the next step belongs in HolmesBrain's model loop (which feeds
    ///     frames back as image tool_results), not in this pre-planned lane.
    private static func runComputer(_ step: PlannedStep) async -> StepResult {
        let outcome = await ComputerUseEngine.shared.perform(action: step.action, input: step.input)
        return StepResult(ok: !outcome.isError, text: outcome.text)
    }

    // MARK: - app lane (structured API where strictly better than pixels)

    private static func runApp(_ step: PlannedStep, userConfirmed: Bool) async -> StepResult {
        switch step.action {
        case "open_app":
            // Reuse ComputerUseEngine's open_app wholesale: same NSWorkspace
            // launch, same name→bundle resolver, same Finder wrinkle, same
            // diagnostics. It is master-switch gated but NOT Accessibility-gated
            // (posts no CGEvents), so it works even while an AX grant is stale.
            let outcome = await ComputerUseEngine.shared.perform(action: "open_app", input: step.input)
            return StepResult(ok: !outcome.isError, text: outcome.text)

        case "open_url":
            return doOpenURL(step.input)

        case "reveal_file":
            return doRevealFile(step.input)

        case "move_file":
            // Confirm-by-default is enforced by the backstop in run() (via
            // AutonomyGate's file-move policy); by the time we're here the step
            // is either confirmed or explicitly marked trivially undoable.
            return doMoveFile(step.input)

        case "trash_file":
            return doTrashFile(step.input)

        case "applescript":
            return await doAppleScript(step, userConfirmed: userConfirmed)

        case "create_folder":
            return doCreateFolder(step.input)

        case "join_meeting":
            return doJoinMeeting(step.input)

        case "calendar_create_event":
            return await doCalendarCreateEvent(step.input)

        case "ax_press":
            return await doAXPress(step, userConfirmed: userConfirmed)

        case "ax_type":
            return await doAXType(step.input)

        default:
            return StepResult(ok: false, text: "Unknown app action '\(step.action)'. Supported: open_app, open_url, reveal_file, move_file, trash_file, create_folder, join_meeting, calendar_create_event, ax_press, ax_type, applescript.")
        }
    }

    /// FileManager.createDirectory — deterministic, idempotent, undoable while
    /// the folder stays empty.
    private static func doCreateFolder(_ input: [String: Any]) -> StepResult {
        guard let url = fileURL(from: input, keys: ["path", "to", "folder"]) else {
            return StepResult(ok: false, text: "Missing 'path' for create_folder.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return StepResult(ok: true, text: "Folder already exists at \(url.path).")
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            diag("create_folder \(url.path) ok")
            return StepResult(ok: true, text: "Created folder \(url.path).", undo: {
                // Undo only removes the folder while it is still empty —
                // never anything the user has since put inside it.
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if contents.isEmpty { try? FileManager.default.removeItem(at: url) }
            })
        } catch {
            return StepResult(ok: false, text: "Failed to create folder: \(error.localizedDescription)")
        }
    }

    /// Deterministic meeting join: open the meeting URL (any scheme —
    /// zoommtg://, msteams://, https://zoom.us/j/…) and let macOS route it.
    private static func doJoinMeeting(_ input: [String: Any]) -> StepResult {
        let raw = ((input["url"] as? String) ?? (input["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme != nil else {
            return StepResult(ok: false, text: "Missing or malformed meeting 'url'.")
        }
        let opened = NSWorkspace.shared.open(url)
        diag("join_meeting \(url.absoluteString) ok=\(opened)")
        return StepResult(
            ok: opened,
            text: opened
                ? "Opened the meeting link — joining is reversible, the user can leave."
                : "Failed to open \(url.absoluteString).")
    }

    /// The real EventKit executor for calendar_create_event, with a real undo
    /// (delete the created event).
    private static func doCalendarCreateEvent(_ input: [String: Any]) async -> StepResult {
        let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return StepResult(ok: false, text: "Missing 'title' for calendar_create_event.")
        }
        guard let start = parseEventDate(input["start"] ?? input["start_time"] ?? input["startDate"]) else {
            return StepResult(ok: false, text: "Missing or unparseable 'start' — use ISO-8601, e.g. 2026-07-25T15:00:00.")
        }
        let end: Date
        if let explicitEnd = parseEventDate(input["end"] ?? input["end_time"]) {
            end = explicitEnd
        } else {
            let minutes = (input["duration_minutes"] as? Int)
                ?? Int((input["duration_minutes"] as? Double) ?? 30)
            end = start.addingTimeInterval(TimeInterval(max(5, minutes)) * 60)
        }
        let notes = input["notes"] as? String
        let location = input["location"] as? String
        let outcome = await MainActor.run {
            CalendarEngine.shared.createEvent(title: title, start: start, end: end, notes: notes, location: location)
        }
        if let id = outcome.id {
            diag("calendar_create_event '\(title)' ok id=\(id)")
            return StepResult(ok: true, text: "Created calendar event “\(title)”.", undo: {
                await MainActor.run { _ = CalendarEngine.shared.deleteEvent(id: id) }
            })
        }
        return StepResult(ok: false, text: "Calendar event failed: \(outcome.error ?? "unknown error")")
    }

    /// ISO-8601 (with/without fractional seconds) or "yyyy-MM-dd HH:mm".
    private static func parseEventDate(_ raw: Any?) -> Date? {
        guard let string = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        // Local-time forms the model commonly emits without a zone.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// AX press: the deterministic "click the button named X" — no pixels, no
    /// coordinates, works regardless of window position. Send-class labels
    /// hold for one confirm.
    private static func doAXPress(_ step: PlannedStep, userConfirmed: Bool) async -> StepResult {
        let input = step.input
        let label = ((input["label"] as? String) ?? (input["button"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = ((input["app"] as? String) ?? (input["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !appName.isEmpty else {
            return StepResult(ok: false, text: "ax_press needs {\"app\":\"AppName\",\"label\":\"Button title\"}.")
        }
        if matchesSendVerb(label), !userConfirmed {
            return needsConfirm(step, "pressing “\(label)” looks like a send/submit-class action")
        }
        return await MainActor.run {
            guard let app = runningApp(named: appName) else {
                return StepResult(ok: false, text: "App '\(appName)' is not running.")
            }
            let ok = ActionExecutor.shared.clickButton(label: label, in: app)
            diag("ax_press '\(label)' in \(appName) ok=\(ok)")
            return StepResult(
                ok: ok,
                text: ok ? "Pressed “\(label)” in \(appName)."
                         : "No accessible button labeled “\(label)” in \(appName) — a visible click may be needed instead.")
        }
    }

    /// AX type: set the field's value through Accessibility — atomic and
    /// un-droppable, unlike blind CGEvent typing into whatever has focus.
    private static func doAXType(_ input: [String: Any]) async -> StepResult {
        let text = (input["text"] as? String) ?? ""
        let appName = ((input["app"] as? String) ?? (input["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !appName.isEmpty else {
            return StepResult(ok: false, text: "ax_type needs {\"app\":\"AppName\",\"text\":\"…\"} (optional \"fieldHint\").")
        }
        let fieldHint = (input["fieldHint"] as? String) ?? (input["field"] as? String)
        return await MainActor.run {
            guard let app = runningApp(named: appName) else {
                return StepResult(ok: false, text: "App '\(appName)' is not running.")
            }
            let ok = ActionExecutor.shared.focusAndType(in: app, fieldHint: fieldHint, text: text)
            diag("ax_type into \(appName) ok=\(ok)")
            return StepResult(
                ok: ok,
                text: ok ? "Typed into \(appName) via Accessibility."
                         : "Couldn't find a writable field in \(appName)\(fieldHint.map { " matching “\($0)”" } ?? "").")
        }
    }

    /// Frontmost-name match, exact first then contains.
    @MainActor
    private static func runningApp(named name: String) -> NSRunningApplication? {
        let lowered = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { ($0.localizedName ?? "").lowercased() == lowered }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(lowered) }
    }

    private static func doOpenURL(_ input: [String: Any]) -> StepResult {
        let raw = (input["url"] as? String) ?? (input["text"] as? String) ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            return StepResult(ok: false, text: "Missing or malformed 'url'.")
        }
        // Web/mail schemes plus the meeting-app deep links (zoom://, msteams://…)
        // that a join legitimately needs; file: goes through reveal_file so a
        // plan can't smuggle an arbitrary local open through the URL lane.
        let allowedSchemes = ["http", "https", "mailto",
                              "zoommtg", "zoomus", "msteams", "slack", "webex", "facetime"]
        guard allowedSchemes.contains(url.scheme?.lowercased() ?? "") else {
            return StepResult(ok: false, text: "URL scheme '\(url.scheme ?? "")' isn't allowed here. Use reveal_file for local paths.")
        }
        let opened = NSWorkspace.shared.open(url)
        diag("open_url \(url.absoluteString) ok=\(opened)")
        return StepResult(ok: opened, text: opened ? "Opened \(url.absoluteString)." : "Failed to open \(url.absoluteString).")
    }

    private static func doRevealFile(_ input: [String: Any]) -> StepResult {
        guard let url = fileURL(from: input, keys: ["path", "file", "source"]) else {
            return StepResult(ok: false, text: "Missing 'path' for reveal_file.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StepResult(ok: false, text: "No file at \(url.path).")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return StepResult(ok: true, text: "Revealed \(url.lastPathComponent) in Finder.")
    }

    /// Structured file move with a REAL undo (move back) — the reason this op has
    /// an "app" lane at all: a pixel drag through Finder cannot be reverted
    /// programmatically, `FileManager.moveItem` can.
    private static func doMoveFile(_ input: [String: Any]) -> StepResult {
        guard let source = fileURL(from: input, keys: ["from", "source", "path"]) else {
            return StepResult(ok: false, text: "Missing 'from' path for move_file.")
        }
        guard var destination = fileURL(from: input, keys: ["to", "destination"]) else {
            return StepResult(ok: false, text: "Missing 'to' path for move_file.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            return StepResult(ok: false, text: "No file at \(source.path).")
        }
        // "Move into folder" semantics: a destination that is an existing
        // directory receives the file under its own name.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            destination = destination.appendingPathComponent(source.lastPathComponent)
        }
        // Never overwrite — a clobbered file is NOT undoable by moving back.
        guard !fm.fileExists(atPath: destination.path) else {
            return StepResult(ok: false, text: "Refusing to overwrite existing file at \(destination.path).")
        }
        do {
            // Create the destination's parent chain so "move to a new folder" works.
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
        } catch {
            return StepResult(ok: false, text: "Move failed: \(error.localizedDescription)")
        }
        diag("move_file \(source.path) → \(destination.path)")
        // Undo = move back, guarded so it can't clobber a file that reappeared at
        // the original path in the meantime.
        let from = destination, backTo = source
        let undo: () async -> Void = {
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: backTo.path) else { return }
            try? fm.moveItem(at: from, to: backTo)
        }
        return StepResult(ok: true,
                          text: "Moved \(source.lastPathComponent) to \(destination.deletingLastPathComponent().path).",
                          undo: undo)
    }

    /// Trash with undo (restore from the exact Trash URL the system reports).
    private static func doTrashFile(_ input: [String: Any]) -> StepResult {
        guard let source = fileURL(from: input, keys: ["path", "file", "source"]) else {
            return StepResult(ok: false, text: "Missing 'path' for trash_file.")
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return StepResult(ok: false, text: "No file at \(source.path).")
        }
        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: &trashedURL)
        } catch {
            return StepResult(ok: false, text: "Trash failed: \(error.localizedDescription)")
        }
        diag("trash_file \(source.path) → \(trashedURL?.path ?? "?")")
        let restoreFrom = trashedURL as URL?
        let backTo = source
        let undo: (() async -> Void)? = restoreFrom.map { from in
            {
                let fm = FileManager.default
                guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: backTo.path) else { return }
                try? fm.moveItem(at: from, to: backTo)
            }
        }
        return StepResult(ok: true, text: "Moved \(source.lastPathComponent) to the Trash.", undo: undo)
    }

    /// Small AppleScript lane for reversible app ops a pixel sequence would make
    /// fragile (e.g. `tell app "Music" to pause`). A script whose SOURCE names an
    /// outward verb (send/delete/pay/…) is held for a confirm — the same SEND_RE
    /// line the extension, the AX-label gate, and AutonomyGate draw — because the
    /// action name ("applescript") carries no verb for the token classifiers.
    private static func doAppleScript(_ step: PlannedStep, userConfirmed: Bool) async -> StepResult {
        let source = scriptSource(step.input)
        guard !source.isEmpty else {
            return StepResult(ok: false, text: "Missing 'source' for applescript.")
        }
        if matchesSendVerb(source), !userConfirmed {
            // Belt-and-suspenders: the run() backstop already checks this; keep
            // the local guard so the lane stays safe if called directly.
            return needsConfirm(step, "This script contains an outward-facing verb (send/delete/pay-class): \(step.summary)")
        }
        // NSAppleScript is main-thread-only; scripts here are expected to be tiny
        // one-liners, so a synchronous main-actor execution is acceptable.
        guard let script = NSAppleScript(source: source) else {
            return StepResult(ok: false, text: "Could not parse the AppleScript.")
        }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            diag("applescript FAILED — \(message)")
            return StepResult(ok: false, text: "AppleScript failed: \(message)")
        }
        let text = output.stringValue.flatMap { $0.isEmpty ? nil : "Result: \($0)" } ?? "Script ran."
        return StepResult(ok: true, text: text)
    }

    private static func scriptSource(_ input: [String: Any]) -> String {
        ((input["source"] as? String) ?? (input["script"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - composio lane (API actions through the existing MCP host path)

    /// Dispatches through the exact symbols HolmesBrain's tool loop already uses:
    /// `MCPClient.shared.startAll()` → `MCPClient.shared.call(namespacedName:
    /// arguments:)`, with the ComposioCatalog policy re-applied AT DISPATCH TIME
    /// (`validateMetaExecute` for COMPOSIO_MULTI_EXECUTE_TOOL — the outer name
    /// carries no verb, only the inner tool_slugs do — and `isPlaybookSafe` /
    /// `readOnlyHint` for direct tools). Reads run freely (the status quo of
    /// draft mode); writes reach here only confirmed (run()'s backstop), and the
    /// one sanctioned inert write (GMAIL_CREATE_EMAIL_DRAFT via the exact-match
    /// meta allowlist) clears validateMetaExecute itself once confirmed.
    private static func runComposio(
        _ step: PlannedStep,
        composioApps: [String],
        userConfirmed: Bool
    ) async -> StepResult {
        await MCPClient.shared.startAll() // no-op if already started
        guard let tool = resolveMCPTool(step.action) else {
            return StepResult(ok: false, text: "No connected MCP tool matches '\(step.action)'.")
        }
        let bare = tool.name.uppercased()
        let isComposioServer = tool.serverName.lowercased() == ComposioCatalog.composioServerName

        if bare == ComposioCatalog.metaExecuteTool {
            // The guarded executor is honored ONLY from the configured Composio
            // server, so another server cannot impersonate it (same rule as
            // HolmesBrain's playbook tool filter).
            guard isComposioServer else {
                return StepResult(ok: false, text: "'\(ComposioCatalog.metaExecuteTool)' is only honored from the '\(ComposioCatalog.composioServerName)' MCP server.")
            }
            // Read-only slugs — plus the sanctioned Gmail draft once confirmed —
            // clear the shipping validator unchanged.
            let verdict = ComposioCatalog.validateMetaExecute(
                arguments: step.input,
                composioApps: composioApps,
                allowDraftWrite: userConfirmed
            )
            if !verdict.allowed {
                // Send/mutate-class inner slugs are what the ONE explicit confirm
                // unlocks — but even confirmed, the structural floor holds: no
                // meta-in-meta, and never outside the step's declared app scope.
                guard userConfirmed else { return needsConfirm(step, verdict.reason) }
                if let structural = confirmedMetaStructuralFailure(step, composioApps: composioApps) {
                    return StepResult(ok: false, text: structural)
                }
                diag("meta-execute WRITE allowed by user confirmation — \(step.summary)")
            }
            let result = await MCPClient.shared.call(namespacedName: tool.namespacedName, arguments: step.input)
            return StepResult(ok: !result.isError, text: result.text)
        }

        // Read-only meta tools (search/schemas) from the Composio server run freely.
        if ComposioCatalog.metaReadTools.contains(bare) {
            guard isComposioServer else {
                return StepResult(ok: false, text: "Meta tool '\(bare)' is only honored from the '\(ComposioCatalog.composioServerName)' MCP server.")
            }
            let result = await MCPClient.shared.call(namespacedName: tool.namespacedName, arguments: step.input)
            return StepResult(ok: !result.isError, text: result.text)
        }

        // Direct tools: reads run freely; anything the default-deny policy calls a
        // write needs the confirm (draft-create tools count as writes here — a
        // server-side draft is a server-side write, and the confirm card IS the
        // disclosure that playbook draft mode provides via allowDraftWrite).
        if !directToolIsReadOnly(tool), !userConfirmed {
            return needsConfirm(step, "'\(tool.name)' is a write-class API action: \(step.summary)")
        }
        let result = await MCPClient.shared.call(namespacedName: tool.namespacedName, arguments: step.input)
        return StepResult(ok: !result.isError, text: result.text)
    }

    /// Composio steps that will be held for a confirm — mirrors runComposio's
    /// gates without dispatching. An unresolvable tool classifies as needing a
    /// confirm (fail closed) so the orchestrator surfaces the problem to the user
    /// instead of silently attempting it.
    private static func composioNeedsConfirmation(_ step: PlannedStep, composioApps: [String]) -> Bool {
        guard let tool = resolveMCPTool(step.action) else { return true }
        let bare = tool.name.uppercased()
        if bare == ComposioCatalog.metaExecuteTool {
            return !ComposioCatalog.validateMetaExecute(
                arguments: step.input, composioApps: composioApps, allowDraftWrite: false
            ).allowed
        }
        if ComposioCatalog.metaReadTools.contains(bare) { return false }
        return !directToolIsReadOnly(tool)
    }

    /// A direct (non-meta) MCP tool is read-only when the server self-declares
    /// readOnlyHint OR its name passes the default-deny token policy — with the
    /// draft-create carve-out EXCLUDED (rule 1's CREATE exception exists for the
    /// disclosed draft-only playbooks; on the autonomy path that write goes
    /// through the confirm card instead).
    private static func directToolIsReadOnly(_ tool: MCPTool) -> Bool {
        tool.readOnly
            || (ComposioCatalog.isPlaybookSafe(toolName: tool.name)
                && !ComposioCatalog.isDraftCreateTool(tool.name))
    }

    /// The structural floor a CONFIRMED meta-execute call must still clear: a
    /// well-formed items array, no meta tool nested inside the executor, and every
    /// slug inside the step's declared app scope (a confirmed GITHUB step still
    /// can't touch Gmail). Returns the refusal text, or nil when it may proceed.
    private static func confirmedMetaStructuralFailure(_ step: PlannedStep, composioApps: [String]) -> String? {
        guard let items = step.input["tools"] as? [[String: Any]], !items.isEmpty else {
            return "The meta-execute call has no 'tools' array of objects."
        }
        let apps = composioApps.map { $0.uppercased() }
        for item in items {
            guard let rawSlug = item["tool_slug"] as? String, !rawSlug.isEmpty else {
                return "A meta-execute item has no String 'tool_slug'."
            }
            let slug = rawSlug.uppercased()
            if ComposioCatalog.metaToolNames.contains(slug) {
                return "Meta tool '\(slug)' cannot be nested inside an execute call."
            }
            if !apps.isEmpty, !apps.contains(where: { slug.contains($0) }) {
                return "tool_slug '\(slug)' is outside this step's apps (\(apps.joined(separator: ", ")))."
            }
        }
        return nil
    }

    /// True when the step is a pure read on the Composio lane (no master-switch
    /// re-check, no memory "action" entry). Note this classification takes no
    /// composioApps — scope narrows what may run, not whether it's a read.
    private static func composioIsReadOnly(_ step: PlannedStep) -> Bool {
        guard let tool = resolveMCPTool(step.action) else { return false }
        let bare = tool.name.uppercased()
        if ComposioCatalog.metaReadTools.contains(bare) { return true }
        if bare == ComposioCatalog.metaExecuteTool {
            // Read-only exactly when the strict validator clears it WITHOUT the
            // draft allowlist (unscoped — scope is enforced at dispatch).
            return ComposioCatalog.validateMetaExecute(
                arguments: step.input, composioApps: [], allowDraftWrite: false
            ).allowed
        }
        return directToolIsReadOnly(tool)
    }

    /// Resolves a step's tool name against the connected MCP servers: exact
    /// namespaced match first ("composio__COMPOSIO_MULTI_EXECUTE_TOOL"), then
    /// bare-name match ("GMAIL_FETCH_EMAILS"), preferring the Composio server
    /// when several servers expose the same name.
    private static func resolveMCPTool(_ name: String) -> MCPTool? {
        if let exact = MCPClient.shared.tool(forNamespacedName: name) { return exact }
        let wanted = name.uppercased()
        let candidates = MCPClient.shared.tools.filter { $0.name.uppercased() == wanted }
        if let composio = candidates.first(where: { $0.serverName.lowercased() == ComposioCatalog.composioServerName }) {
            return composio
        }
        return candidates.first
    }

    // MARK: - Shared helpers

    /// The extension's SEND_RE verb list (holmes-extension/automation.js), the
    /// same line ComputerUseEngine's AX-label gate draws — applied here to
    /// AppleScript SOURCE text, which no token classifier upstream can see.
    private static let sendVerbRegex = try! NSRegularExpression(
        pattern: #"\b(send|submit|post|publish|tweet|reply|confirm|pay|buy|order|delete|archive|trash|purchase|accept|share|discard|remove|keystroke|key code|do shell script)\b"#,
        options: [.caseInsensitive]
    )

    private static func matchesSendVerb(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return sendVerbRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static let commitControlWords: [String] = [
        "send", "submit", "post", "publish", "tweet", "reply", "confirm", "pay", "buy", "order",
        "delete", "archive", "trash", "purchase", "accept", "share", "discard", "remove", "move to trash",
        "empty trash", "don't save", "dont save"
    ]

    /// True when `label` (as the executor's substring match would apply it)
    /// could land on a commit control: it is empty/very short, or a substring of
    /// a known commit word, or contains one.
    private static func couldMatchCommitControl(_ label: String) -> Bool {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        if l.count < 4 { return true }
        return commitControlWords.contains { $0.contains(l) || l.contains($0) }
    }

    /// First non-empty string under any of `keys`, tilde-expanded, as a file URL.
    private static func fileURL(from input: [String: Any], keys: [String]) -> URL? {
        for key in keys {
            if let raw = input[key] as? String, !raw.isEmpty {
                let expanded = (raw as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }
}
