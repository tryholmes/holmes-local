import Foundation
import Observation
import UserNotifications

// MARK: - PlaybookEngine
// Evaluates proactive playbooks against the live screen context and produces
// ProactiveDrafts. Draft-only by construction: generation goes through
// HolmesBrain.runPlaybook (the local model, tool list pre-filtered by
// ComposioCatalog.isPlaybookSafe). Nothing here can send, post, or publish —
// approved drafts are staged/copied by the review card, never dispatched.
//
// Trigger discipline:
//   • debounce — the same match key must be seen on two consecutive evaluate()
//     calls before firing (ignores transient screens mid-navigation)
//   • cooldown — per playbook + context key, so the same email/repo/chat doesn't
//     re-fire for cooldownSeconds
//   • one playbook run at a time (isExecuting)

@Observable
@MainActor
final class PlaybookEngine {
    static let shared = PlaybookEngine()

    // ── Published state ─────────────────────────────
    private(set) var drafts: [ProactiveDraft] = []   // newest first, cap 20
    var isExecuting: Bool = false

    // ── Private state ───────────────────────────────
    @ObservationIgnored private var started = false
    @ObservationIgnored private var fireTask: Task<Void, Never>?
    @ObservationIgnored private var fireID: UUID?
    @ObservationIgnored private var failureSummary: String?
    // "playbookId|contextKey" -> last successful fire
    @ObservationIgnored private var cooldowns: [String: Date] = [:]
    // playbookId -> the screen (app|window) it last matched, with when that
    // screen was first and most recently seen. Debounce is TIME-based: a fire
    // needs the same screen re-observed ≥minDwellSeconds after first sighting,
    // so two captures landing milliseconds apart (the 3s timer racing the
    // app-switch capture) can't collapse the dwell requirement and fire on a
    // screen the user merely passed through. Entries for playbooks unmatched
    // on a tick survive briefly (staleSeenTTL) so an interleaved tick from the
    // OTHER context source (browser bridge vs OCR — different presence keys
    // for one physical screen) can't wipe the debounce state every 3s.
    @ObservationIgnored private var lastSeenKeys: [String: (key: String, firstSeen: Date, lastSeen: Date)] = [:]
    // playbookId -> last fire ATTEMPT — a key-independent re-fire floor, so noisy
    // extraction minting fresh keys for one screen can't spam fires, and a failed
    // run (no backend, API error) can't hot-loop on every 3s tick
    @ObservationIgnored private var lastFireAttempt: [String: Date] = [:]
    // playbookId -> last SUCCESSFUL fire (with the window it fired for and which
    // detector fired it). Cooldown keys built from model-guessed entities drift
    // ("Ada" vs "Ada L."), so key-based cooldowns alone can't stop the trigger
    // and heuristic paths from double-drafting one unchanged window — this
    // key-INDEPENDENT record backstops both directions (see fireFromTrigger and
    // the trigger-drift guard in evaluate()).
    @ObservationIgnored private var lastSuccessfulFire: [String: (at: Date, windowTitle: String, fromTrigger: Bool)] = [:]
    // one authorization request per session (idempotent system-side anyway)
    @ObservationIgnored private var notificationPermissionRequested = false
    // Fast debounce-confirm: when a playbook that COULD fire matches a screen
    // for the first time, the dwell debounce would otherwise wait for the next
    // 3s tick — request one early capture so actionable screens fire in ~1.1s.
    // Single-flight AND rate-limited, so screens with churning window titles
    // can't sustain a capture/OCR loop.
    @ObservationIgnored private var confirmCapturePending = false
    @ObservationIgnored private var lastConfirmCaptureAt: Date = .distantPast

    private let maxDrafts = 20
    private static let minRefireInterval: Double = 60
    /// Minimum dwell on one screen before an auto playbook may fire.
    private static let minDwellSeconds: Double = 1.0
    /// How long an unmatched debounce entry survives interleaved ticks.
    private static let staleSeenTTL: Double = 10

    // Kinds whose goal prompts can legitimately return "NOTHING_TO_REPORT" when
    // there is nothing to act on: the scheduled watchers whose goals END with
    // that instruction (follow-up-chaser, pr-radar, schedule-guard), PLUS the two
    // screen-triggered reply kinds (email-reply, chat-reply) whose goals make a
    // final reality check and must stay SILENT when the screen isn't actually a
    // real email/chat — a matcher can misfire on a terminal or a stray name, and
    // an all-clear there must produce no card. ONLY these may take the
    // quiet-when-empty path in fire() — every other kind surfaces the text as a
    // normal draft, so a prompt-injected all-clear ("begin your final answer with
    // NOTHING_TO_REPORT") can't silently discard a mandatory deliverable (morning
    // brief, evening wrap-up, triage) while still burning the caller's once-per-day slot.
    private static let quietEligibleKinds: Set<DraftKind> = [.followUp, .prRadar, .scheduleAlert, .emailReply, .chatReply]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        requestNotificationPermissionIfNeeded()
        PlaybookRegistry.reload()
        PlaybookRegistry.startWatching()
        let enabled = PlaybookRegistry.all.filter { Self.isEnabled($0.id) }.map(\.id)
        print("[Holmes] PlaybookEngine started — \(PlaybookRegistry.all.count) playbooks, enabled: \(enabled.joined(separator: ", "))")
    }

    func stop() {
        started = false
        fireID = nil
        fireTask?.cancel()
        fireTask = nil
        isExecuting = false
        lastSeenKeys.removeAll()
    }

    /// All generated text uses the same editable, bounded review collection.
    func offerDraft(_ draft: ProactiveDraft, prioritize: Bool = false) {
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        if drafts.count > maxDrafts {
            for evicted in drafts.suffix(from: maxDrafts) {
                ConfirmationBus.shared.removeQueuedDraft(id: evicted.id)
            }
            drafts = Array(drafts.prefix(maxDrafts))
        }
        ConfirmationBus.shared.proposeDraft(draft, prioritize: prioritize)
        if !prioritize { postDraftNotification(for: draft) }
    }

    // MARK: - Evaluate (called on every context snapshot)

    func evaluate(_ ctx: PlaybookContext) {
        guard started, !isExecuting else { return }
        pruneCooldownsIfNeeded()

        // Every auto playbook is visited on every pass (no early returns): a
        // debounced or cooling-down playbook must not starve the ones after it.
        let previousKeys = lastSeenKeys
        var currentKeys: [String: (key: String, firstSeen: Date, lastSeen: Date)] = [:]
        var winner: (playbook: Playbook, key: String, cooldownKey: String)? = nil

        // Debounce on a STABLE "which screen am I dwelling on" signal (app + window
        // title), NOT the match key. The match key is built from extracted text —
        // an email sender/subject read via OCR, or an in-progress prompt the user
        // is actively typing — so it changes almost every 3s tick and the old
        // "same key twice" rule never passed (email-reply / prompt-coach never
        // fired). The window is stable while you sit on it, so this fires once
        // you've dwelled ≥minDwellSeconds, using the freshest match key.
        let presenceKey = ctx.appName + "|" + ctx.windowTitle
        let now = Date()
        var sawFirstSighting = false
        var matchedThisTick = false

        for playbook in PlaybookRegistry.all where playbook.autoTriggers && Self.isEnabled(playbook.id) {
            guard let key = playbook.matches(ctx) else { continue }
            matchedThisTick = true
            let firstSeen = previousKeys[playbook.id]?.key == presenceKey
                ? previousKeys[playbook.id]!.firstSeen : now
            currentKeys[playbook.id] = (presenceKey, firstSeen, now)

            // One fire per tick — but keep recording keys for the rest.
            guard winner == nil else { continue }

            // The brakes come BEFORE the debounce, so a playbook that cannot
            // fire anyway (floor/cooldown/drift) never requests a confirm
            // capture — otherwise a screen on cooldown sustains a pointless
            // capture/OCR loop for the whole cooldown window.

            // Key-independent floor: one fire attempt per playbook per interval.
            if let attempt = lastFireAttempt[playbook.id],
               now.timeIntervalSince(attempt) < Self.minRefireInterval {
                continue
            }

            // Cooldown: don't re-fire for the same context within cooldownSeconds.
            // (Only written on a SUCCESSFUL run — see fire() — so a transient
            // failure doesn't block the context for the whole window.)
            let cooldownKey = playbook.id + "|" + key
            if let lastFired = cooldowns[cooldownKey],
               now.timeIntervalSince(lastFired) < playbook.cooldownSeconds {
                continue
            }

            // Trigger-drift guard: if the TRIGGER path recently drafted for this
            // same window, its cooldown key was built from model-guessed entities
            // and may not equal ours — don't double-draft the same unchanged
            // window just because the two detectors keyed it differently.
            if let last = lastSuccessfulFire[playbook.id],
               last.fromTrigger,
               last.windowTitle == ctx.windowTitle,
               Date().timeIntervalSince(last.at) < playbook.cooldownSeconds {
                continue
            }

            // Debounce: the same SCREEN re-observed after a real dwell. Time-
            // based, not tick-based: the app-switch capture and the 3s timer can
            // land near-simultaneously, and two sightings 50ms apart must not
            // count as "dwelling".
            guard previousKeys[playbook.id]?.key == presenceKey,
                  now.timeIntervalSince(firstSeen) >= Self.minDwellSeconds else {
                sawFirstSighting = true
                continue
            }

            winner = (playbook, key, cooldownKey)
        }

        // Retain recently-seen entries for playbooks this tick didn't match:
        // the browser bridge and the OCR path describe the same physical screen
        // with different presence keys, and an interleaved tick from one source
        // must not reset the other's dwell clock.
        for (id, entry) in previousKeys
        where currentKeys[id] == nil && now.timeIntervalSince(entry.lastSeen) < Self.staleSeenTTL {
            currentKeys[id] = entry
        }
        lastSeenKeys = currentKeys

        if let winner {
            print("[Holmes] Playbook '\(winner.playbook.id)' triggered — key: \(winner.key.prefix(60))")
            fire(winner.playbook, ctx: ctx, cooldownKeys: [winner.cooldownKey])
        } else if sawFirstSighting, !confirmCapturePending,
                  now.timeIntervalSince(lastConfirmCaptureAt) > Self.staleSeenTTL {
            // A fireable playbook matched this screen but hasn't dwelled long
            // enough — pull the confirming sighting forward instead of waiting
            // a full tick, so actions land ~1.1s after you reach an actionable
            // screen. Rate-limited: churning window titles can't loop this.
            confirmCapturePending = true
            lastConfirmCaptureAt = now
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                confirmCapturePending = false
                ScreenEngine.shared.captureNow()
            }
        } else if !matchedThisTick {
            // No heuristic matcher recognized this tick at all — let the local
            // model look for opportunities the extractors missed. TriggerBrain
            // rate-limits itself and fires back through fireFromTrigger, which
            // holds the same cooldowns as this path.
            TriggerBrain.shared.consider(ctx)
        }
    }

    /// Drops expired cooldown entries so the dictionary can't grow without bound
    /// in an always-on agent (per-email/per-repo keys accumulate over a session).
    private func pruneCooldownsIfNeeded() {
        guard cooldowns.count > 64 else { return }
        let now = Date()
        cooldowns = cooldowns.filter { entry in
            let playbookId = String(entry.key.prefix(while: { $0 != "|" }))
            let ttl = PlaybookRegistry.all.first(where: { $0.id == playbookId })?.cooldownSeconds ?? 3600
            return now.timeIntervalSince(entry.value) < ttl
        }
    }

    // MARK: - Manual run (skips autoTriggers/debounce; SHARES per-context cooldown)

    /// Manual/Autopilot fire path. Skips the two-tick debounce and the
    /// autoTriggers gate, but when the context yields a stable match key it
    /// checks AND consumes the same per-context cooldown as the auto path —
    /// otherwise Autopilot's meeting-prep and the screen path double-fire the
    /// same event (each within ~a minute of the other, in either order).
    /// Contexts with no match key (morning-brief, email-triage, pr-radar,
    /// ai-research all return nil) get a key-INDEPENDENT floor instead: the
    /// playbook's declared cooldownSeconds measured from its last successful
    /// fire — otherwise a keyless playbook's cooldown is dead code and a
    /// "Run now" click right after a scheduled fire runs a full duplicate
    /// model+MCP pass (ai-research declares 0 and stays uncapped).
    /// - onCompletion: reports whether the run SUCCEEDED — it produced a draft,
    ///   or came back all-clear (NOTHING_TO_REPORT) — so schedulers (Autopilot's
    ///   once-per-day slot) can burn state on success only.

    /// True while a run the USER started (Automations pane, command bar) is
    /// executing; context-triggered fires leave it false so their glow/ding
    /// are suppressed unless the user opted in (ScreenGlowController.contextGlowEnabled).
    private(set) var currentRunIsManual = false
    var glowOrigin: ScreenGlowController.Origin { currentRunIsManual ? .user : .context }
    private func glow(_ state: ScreenGlowController.GlowState) {
        ScreenGlowController.shared.set(state: state, origin: glowOrigin)
    }

    func runManually(playbookId: String, context: PlaybookContext, onCompletion: ((Bool) -> Void)? = nil) {
        if playbookId == "email-compose" {
            Task { @MainActor in
                let result = await EmailDraftCoordinator.shared.request(instruction: "Draft this email for me.")
                if case .ready = result { onCompletion?(true) } else { onCompletion?(false) }
            }
            return
        }
        guard let playbook = PlaybookRegistry.all.first(where: { $0.id == playbookId }) else {
            print("[Holmes] Playbook '\(playbookId)' not found")
            onCompletion?(false)
            return
        }
        guard !isExecuting else {
            print("[Holmes] Playbook '\(playbookId)' skipped — another playbook is running")
            onCompletion?(false)
            return
        }
        var cooldownKeys: [String] = []
        if let key = playbook.matches(context) {
            let cooldownKey = playbook.id + "|" + key
            if let lastFired = cooldowns[cooldownKey],
               Date().timeIntervalSince(lastFired) < playbook.cooldownSeconds {
                print("[Holmes] Playbook '\(playbookId)' manual run skipped — context on cooldown (\(key.prefix(60)))")
                onCompletion?(false)
                return
            }
            cooldownKeys = [cooldownKey]
        } else if playbook.cooldownSeconds > 0,
                  let last = lastSuccessfulFire[playbook.id],
                  Date().timeIntervalSince(last.at) < playbook.cooldownSeconds {
            // Keyless playbooks never enter the per-context branch above, so
            // without this key-independent floor their declared cooldownSeconds
            // never engages (pr-radar's 2400 was pure dead code). Measured from
            // lastSuccessfulFire, which quiet (NOTHING_TO_REPORT) runs also
            // record — an all-clear holds the floor like any other success.
            let ago = Int(Date().timeIntervalSince(last.at))
            print("[Holmes] Playbook '\(playbookId)' manual run skipped — ran \(ago)s ago (cooldown \(Int(playbook.cooldownSeconds))s)")
            onCompletion?(false)
            return
        }
        print("[Holmes] Playbook '\(playbookId)' run manually")
        fire(playbook, ctx: context, cooldownKeys: cooldownKeys, manual: true, onCompletion: onCompletion)
    }

    // MARK: - Trigger-brain fire (debounce-exempt, cooldown-checked, single-flight)

    /// Fire path for TriggerBrain (deterministic opportunity detection off
    /// LiveContext). Exempt from the two-tick debounce — TriggerBrain already
    /// rate-limits and signature-gates itself — but holds every other brake:
    /// autoTriggers + enabled checks, the key-independent 60s attempt floor,
    /// single-flight, and cooldowns. A matches()-derived key can still be
    /// UNSTABLE when the entities came from a coarse read ("Ada" vs "Ada L."
    /// mints fresh keys), so this path also always checks/records the stable key
    /// ("trigger|appName|windowTitle") AND refuses to fire when ANY successful
    /// fire of this playbook happened within cooldownSeconds for the same
    /// window title — key drift can no longer re-draft one unchanged screen.
    /// Cooldowns are still consumed on success only.
    func fireFromTrigger(playbookId: String, context: PlaybookContext) {
        // Email compose requires exact, stable DOM/AX headers, not a model trigger.
        guard playbookId != "email-compose" else { return }
        guard started, !isExecuting else { return }
        guard let playbook = PlaybookRegistry.all.first(where: { $0.id == playbookId }) else {
            print("[Holmes] TriggerBrain fire skipped — playbook '\(playbookId)' not found")
            return
        }
        guard playbook.autoTriggers, Self.isEnabled(playbook.id) else { return }

        // Key-independent floor, shared with the heuristic path.
        if let attempt = lastFireAttempt[playbook.id],
           Date().timeIntervalSince(attempt) < Self.minRefireInterval {
            return
        }

        // Window-level re-fire guard (key-independent): one successful draft per
        // playbook per unchanged window per cooldown window, no matter which
        // detector fired it or how its cooldown key was spelled.
        if let last = lastSuccessfulFire[playbook.id],
           last.windowTitle == context.windowTitle,
           Date().timeIntervalSince(last.at) < playbook.cooldownSeconds {
            return
        }

        // Check + (on success) consume BOTH key spaces: the stable trigger key
        // (model-independent) and, when the enriched entities parse, the exact
        // key the heuristic path would use once real extraction catches up.
        let stableKey = playbook.id + "|trigger|" + context.appName + "|" + context.windowTitle
        var cooldownKeys = [stableKey]
        if let matchKey = playbook.matches(context) {
            cooldownKeys.append(playbook.id + "|" + matchKey)
        }
        for cooldownKey in cooldownKeys {
            if let lastFired = cooldowns[cooldownKey],
               Date().timeIntervalSince(lastFired) < playbook.cooldownSeconds {
                return
            }
        }

        print("[Holmes] Playbook '\(playbook.id)' triggered by TriggerBrain — key: \(cooldownKeys.last!.prefix(60))")
        fire(playbook, ctx: context, cooldownKeys: cooldownKeys, fromTrigger: true)
    }

    // MARK: - Fire (shared path)

    private func fire(
        _ playbook: Playbook,
        ctx: PlaybookContext,
        cooldownKeys: [String] = [],
        fromTrigger: Bool = false,
        manual: Bool = false,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        isExecuting = true
        lastFireAttempt[playbook.id] = Date()
        currentRunIsManual = manual
        glow(.thinking)

        let runID = UUID()
        fireID = runID
        failureSummary = nil
        let inherited = WorkActivityScope.id
        let activity = inherited ?? WorkActivityCenter.shared.begin(
            title: playbook.name, detail: "Preparing", origin: manual ? .user : .background)
        let work = Task { @MainActor in
            var succeeded = false
            let report: (Bool) -> Void = { succeeded = $0 }
            // A background fire has nobody watching: its approval cards time
            // out instead of holding the single playbook slot forever. A manual
            // run was started by the user, who may take their time.
            let approvalDeadline: TimeInterval? = manual ? nil : ApprovalScope.defaultUnattendedTimeout
            await ApprovalScope.$unattendedTimeout.withValue(approvalDeadline) {
            await WorkActivityScope.$id.withValue(activity) {
                guard !Task.isCancelled else { return }
                // === AUTONOMY ROUTING ===
                // effectiveLevel applies the global "Autonomous actions" master switch
                // (default OFF → every playbook clamps to ≤ .draft), so with autonomy
                // off this seam behaves EXACTLY like the historical draft-only Holmes.
                // All fire-time brakes (cooldown, debounce, 60s floor, single-flight)
                // already ran before we got here and are unchanged.
                // SDK (manifest) playbooks are confined to the draft-only path no
                // matter how the dial is set: their goal text is third-party prompt
                // and must never reach ActionPlanner / AutonomousActionRunner.
                let level = playbook.source == nil
                    ? AutonomyPolicy.shared.effectiveLevel(for: playbook.id)
                    : min(AutonomyPolicy.shared.effectiveLevel(for: playbook.id), .draft)
                switch level {
                case .observe:
                    // Watch only: record what WOULD have run; act on nothing.
                    await MemoryStore.shared.record(
                        kind: "action", app: ctx.appName, windowTitle: ctx.windowTitle,
                        activity: "autonomy-observed",
                        summary: "Observed (not run): \(playbook.name)",
                        detail: "playbook=\(playbook.id) level=observe context=\(ctx.appName) — \(ctx.windowTitle)")
                    guard !Task.isCancelled, self.fireID == runID else { return }
                    glow(.off)
                    report(false)

                case .draft:
                    await runDraftPath(playbook, ctx: ctx, cooldownKeys: cooldownKeys,
                                       fromTrigger: fromTrigger, onCompletion: report)

                case .confirm, .auto:
                    // Autonomy may act. If the gate refuses (rate budget spent, the
                    // playbook's own enable, or a master-switch race), fall back to
                    // the draft path so the playbook still helps rather than going dark.
                    guard AutonomyGate.mayAct(playbookId: playbook.id) else {
                        await runDraftPath(playbook, ctx: ctx, cooldownKeys: cooldownKeys,
                                           fromTrigger: fromTrigger, onCompletion: report)
                        return
                    }
                    if playbook.isTeachScenario {
                        await runTeachPath(playbook, ctx: ctx, cooldownKeys: cooldownKeys,
                                           fromTrigger: fromTrigger, onCompletion: report)
                    } else {
                        await runActionPath(playbook, ctx: ctx, level: level, cooldownKeys: cooldownKeys,
                                            fromTrigger: fromTrigger, onCompletion: report)
                    }
                }
            }
            }
            let cancelled = Task.isCancelled || self.fireID != runID
            if inherited == nil {
                if cancelled { WorkActivityCenter.shared.cancel(activity) }
                else {
                    WorkActivityCenter.shared.finish(activity, outcome: succeeded ? .success : .failure,
                        summary: succeeded ? "\(playbook.name) is ready" : (self.failureSummary ?? "Couldn't complete \(playbook.name). Try again."))
                }
            }
            if self.fireID == runID {
                self.isExecuting = false
                self.fireTask = nil
                self.fireID = nil
            }
            onCompletion?(succeeded && !cancelled)
        }
        fireTask = work
        if inherited == nil { WorkActivityCenter.shared.setCancellationHandler(activity) { work.cancel() } }
    }

    // MARK: - Draft path (the historical draft-only pipeline, UNCHANGED)

    /// The draft-only generation path: HolmesBrain.runPlaybook (the local model, tool list
    /// pre-filtered by ComposioCatalog.isPlaybookSafe) produces a ProactiveDraft
    /// the user stages/copies via the review card. Nothing here can send. This is
    /// the code the fire() Task used to run inline — moved verbatim so the .draft
    /// level, and every level's gate-refused fallback, keeps today's behavior.
    private func runDraftPath(
        _ playbook: Playbook,
        ctx: PlaybookContext,
        cooldownKeys: [String],
        fromTrigger: Bool,
        onCompletion: ((Bool) -> Void)?
    ) async {
            let goal = playbook.makeGoal(ctx)
            var text: String? = nil
            var gmailDraftsCreated = 0
            var stagedDraftNotes: [String] = []

            if OllamaConfig.isConfigured {
                // The sanctioned Gmail-draft write clears the meta-execute guard
                // only for the kinds whose prompts and UI disclose it —
                // read-only personas (morning-brief, meeting-prep) stay read-only
                // even though their composioApps include GMAIL.
                let allowDraftWrite = playbook.kind == .emailReply
                    || playbook.kind == .triage
                    || playbook.kind == .followUp
                // The GitHub brief must be FAST: one fetch of repo + open PRs/issues,
                // then write. Cap its tool budget and outer loop hard so it can't
                // sprawl into a long agentic session like the general playbooks.
                let isRepoBrief = playbook.kind == .repoBrief
                if let outcome = await HolmesBrain.shared.runPlaybook(
                    goal: goal,
                    systemHint: playbook.persona.map { Self.communityPersona($0, kind: playbook.kind) }
                        ?? Self.systemHint(for: playbook.kind),
                    composioApps: playbook.composioApps,
                    mcpServers: playbook.mcpServers,
                    allowDraftWrite: allowDraftWrite,
                    maxToolCalls: isRepoBrief ? 4 : 6,
                    maxIterations: isRepoBrief ? 6 : nil,
                    log: { line in print("[Holmes] Playbook '\(playbook.id)': \(line)") }
                ) {
                    text = outcome.text
                    gmailDraftsCreated = outcome.gmailDraftsCreated
                    stagedDraftNotes = outcome.stagedDraftNotes
                }
            } else {
                // No local model, no draft. There is no second-tier model to fall
                // back to, and a playbook that quietly produced a worse draft would
                // be indistinguishable from one that worked.
                failureSummary = OllamaConfig.notReadyMessage
                print("[Holmes] Playbook '\(playbook.id)' skipped — \(OllamaConfig.notReadyMessage)")
            }

            guard !Task.isCancelled else { onCompletion?(false); return }
            var body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The model is TOLD to append this line only on a successful create,
            // but a lying/failed run must not surface the claim: keep the body
            // consistent with the ground truth from the tool loop.
            let savedClaim = "saved to your gmail drafts"
            if gmailDraftsCreated == 0, body.lowercased().hasSuffix(savedClaim) {
                body = String(body.dropLast(savedClaim.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !body.isEmpty else {
                // No cooldown burned on failure — lastFireAttempt's floor is the
                // only brake, so the context can retry once a backend is up.
                print("[Holmes] Playbook '\(playbook.id)' produced no draft")
                glow(.off)
                onCompletion?(false)
                return
            }

            // Quiet-when-empty: playbooks whose goals end with "reply EXACTLY
            // NOTHING_TO_REPORT when nothing needs attention" stay silent on an
            // all-clear. This IS a successful run — cooldowns and the caller's
            // day slot are consumed so the schedule doesn't hot-retry — but it
            // produces no draft, no glow-ready, and no notification.
            // Three hard gates on the quiet path:
            //   • normalization — "Nothing to report." must also match, or the
            //     exact noise this mechanism suppresses leaks through as a
            //     draft card + notification on every paraphrasing all-clear run;
            //   • kind eligibility — only quietEligibleKinds, whose goals CARRY
            //     the instruction, may go quiet (see the set's doc above);
            //   • ground truth — a run that actually performed the sanctioned
            //     Gmail-draft write can NEVER go quiet, no matter what its prose
            //     claims ("create the draft, then reply NOTHING_TO_REPORT" is
            //     the textbook injection): every staged draft must be disclosed
            //     via the review card + stagedNote notification.
            let claimsAllClear = body.uppercased()
                .replacingOccurrences(of: " ", with: "_")
                .hasPrefix("NOTHING_TO_REPORT")
            let stagedWrites = gmailDraftsCreated > 0 || !stagedDraftNotes.isEmpty
            if claimsAllClear, Self.quietEligibleKinds.contains(playbook.kind), !stagedWrites {
                for cooldownKey in cooldownKeys {
                    cooldowns[cooldownKey] = Date()
                }
                lastSuccessfulFire[playbook.id] = (at: Date(), windowTitle: ctx.windowTitle, fromTrigger: fromTrigger)
                print("[Holmes] Playbook '\(playbook.id)' — nothing to report, staying quiet")
                Task {
                    await MemoryStore.shared.record(
                        kind: "playbook", app: ctx.appName, windowTitle: ctx.windowTitle,
                        summary: "\(playbook.id) ran — nothing to report")
                }
                glow(.off)
                onCompletion?(true)
                return
            }
            if claimsAllClear, stagedWrites {
                // The model went quiet AFTER real server-side draft writes.
                // Replace the all-clear claim with the write facts (built from
                // the tool-call INPUT, never from prose) and fall through to
                // the normal surfacing path, so the card and notification show
                // where the staged drafts are actually addressed.
                body = stagedDraftNotes.isEmpty
                    ? "A Gmail draft was staged during this run — review it in your Gmail Drafts folder."
                    : "Gmail draft staged: " + stagedDraftNotes.joined(separator: " · ")
            }

            // Success: now consume the cooldown(s) for this context, and record
            // the key-independent fire fact for the drift guards.
            for cooldownKey in cooldownKeys {
                cooldowns[cooldownKey] = Date()
            }
            lastSuccessfulFire[playbook.id] = (at: Date(), windowTitle: ctx.windowTitle, fromTrigger: fromTrigger)

            let contextSummary = ctx.windowTitle.isEmpty
                ? ctx.appName
                : "\(ctx.appName) — \(ctx.windowTitle)"

            // Truth-in-UI: only show the "Saved in Gmail Drafts" affordance when
            // a GMAIL_CREATE_EMAIL_DRAFT call actually succeeded this run. The
            // local fallback has no tools at all, and a model run may skip or
            // fail the create — those drafts land on the clipboard instead.
            var target = playbook.makeTarget(ctx)
            if case .remoteDraft = target, gmailDraftsCreated == 0 {
                target = .clipboard
            }
            let stagedNote = stagedDraftNotes.isEmpty
                ? nil
                : "Gmail draft staged: " + stagedDraftNotes.joined(separator: " · ")

            let draft = ProactiveDraft(
                playbookId: playbook.id,
                kind: playbook.kind,
                title: playbook.makeTitle(ctx),
                body: body,
                contextSummary: contextSummary,
                target: target,
                stagedNote: stagedNote
            )

            // Memory: every prepared draft is a durable, recallable fact.
            Task {
                await MemoryStore.shared.record(
                    kind: "draft", app: ctx.appName, windowTitle: ctx.windowTitle,
                    activity: playbook.kind.rawValue,
                    summary: draft.title,
                    detail: String(body.prefix(600)) + (stagedNote.map { "\n\($0)" } ?? ""))
            }

            offerDraft(draft)
            glow(.ready)
            if playbook.usesDing {
                ScreenGlowController.shared.ding(origin: glowOrigin)
            }
            print("[Holmes] Playbook '\(playbook.id)' drafted — \(draft.title)\(stagedNote.map { " (\($0))" } ?? "")")
            onCompletion?(true)
    }

    // MARK: - Action path (autonomy: plan → AutonomousActionRunner)

    /// The autonomy ACTION path. ActionPlanner turns the goal + context into a
    /// concrete plan; AutonomousActionRunner runs it under the level (.confirm =
    /// whole plan on one card; .auto = free reversible steps, one card per
    /// gate-flagged step) and OWNS the confirm cards, ⌘⌥Esc kill switch, undo
    /// affordance, the durable "action" memory trail, the rate-budget consumption
    /// (AutonomyGate.recordAct), the completion notification, and its own glow.
    private func runActionPath(
        _ playbook: Playbook,
        ctx: PlaybookContext,
        level: AutonomyLevel,
        cooldownKeys: [String],
        fromTrigger: Bool,
        onCompletion: ((Bool) -> Void)?
    ) async {
        guard OllamaConfig.isConfigured else {
            print("[Holmes] Playbook '\(playbook.id)' autonomy skipped — \(OllamaConfig.notReadyMessage)")
            glow(.off)
            onCompletion?(false)
            return
        }
        let goal = playbook.makeGoal(ctx)
        guard let plan = await ActionPlanner.plan(playbookId: playbook.id, goal: goal, context: ctx) else {
            print("[Holmes] Playbook '\(playbook.id)' autonomy — no plan produced")
            glow(.off)
            onCompletion?(false)
            return
        }
        // The runner settles the glow / posts the notification / logs memory.
        guard !Task.isCancelled else { onCompletion?(false); return }
        let outcome = await AutonomousActionRunner.shared.run(plan, playbookId: playbook.id, level: level)
        guard outcome.succeeded, !Task.isCancelled else {
            failureSummary = outcome.summary
            onCompletion?(false)
            return
        }
        // Consume the per-context cooldown(s) so the same window doesn't re-fire,
        // and record the key-independent fire fact for the drift guards — the same
        // bookkeeping the draft path does on success.
        for cooldownKey in cooldownKeys { cooldowns[cooldownKey] = Date() }
        lastSuccessfulFire[playbook.id] = (at: Date(), windowTitle: ctx.windowTitle, fromTrigger: fromTrigger)
        onCompletion?(true)
    }

    // MARK: - Teach path (autonomy: explain + draw on screen, no mutation)

    /// The autonomy TEACH path. VisualGuidance answers a question about what's on
    /// screen; the answer is spoken (SpeechSynthesizer) and drawn on screen
    /// (VisualGuidanceOverlay). It never mutates anything, so there is no confirm
    /// card and no undo — but it still consumes the autonomy rate budget and the
    /// cooldowns so it can't get naggy.
    private func runTeachPath(
        _ playbook: Playbook,
        ctx: PlaybookContext,
        cooldownKeys: [String],
        fromTrigger: Bool,
        onCompletion: ((Bool) -> Void)?
    ) async {
        guard OllamaConfig.isConfigured else {
            print("[Holmes] Playbook '\(playbook.id)' teach skipped — \(OllamaConfig.notReadyMessage)")
            glow(.off)
            onCompletion?(false)
            return
        }
        // (No isSpeaking pre-check: the speech queue serializes utterances
        // atomically, so a new explanation waits its turn instead of cutting
        // off — and the old checked-then-awaited-model guard was a TOCTOU
        // hole that also starved teach fires during any narration.)
        // Consume the hourly autonomy budget for this fire (mayAct already cleared
        // it); the action path's budget is consumed inside the runner instead.
        AutonomyGate.recordAct(playbookId: playbook.id)

        // Pin the answer to the CURRENT screen so a mismatched teach question can't
        // drag it off-topic (the "Ghostty error → meeting notes" drift).
        let grounding = HolmesAgent.shared.currentContext.description
        guard let result = await VisualGuidance.answer(question: playbook.makeGoal(ctx), context: grounding) else {
            print("[Holmes] Playbook '\(playbook.id)' teach — no guidance produced")
            glow(.off)
            onCompletion?(false)
            return
        }

        guard !Task.isCancelled else { onCompletion?(false); return }
        // Draw the annotations on the display they were produced against
        // (auto-hides; the next key/click dismisses).
        if !result.annotations.isEmpty {
            VisualGuidanceOverlay.shared.show(result.annotations, mappedFrom: result.capture)
        }
        // Speak WITHOUT holding the fire lock — fire-and-forget so isExecuting
        // releases immediately and other playbooks aren't starved by a long TTS.
        if !result.spokenAnswer.isEmpty {
            SpeechSynthesizer.shared.enqueue(result.spokenAnswer, priority: .utterance)
        }

        await MemoryStore.shared.record(
            kind: "action", app: ctx.appName, windowTitle: ctx.windowTitle,
            activity: "autonomy-teach",
            summary: "Explained: \(playbook.makeTitle(ctx))",
            detail: "playbook=\(playbook.id)\n\(String(result.spokenAnswer.prefix(600)))")

        guard !Task.isCancelled else { onCompletion?(false); return }
        for cooldownKey in cooldownKeys { cooldowns[cooldownKey] = Date() }
        lastSuccessfulFire[playbook.id] = (at: Date(), windowTitle: ctx.windowTitle, fromTrigger: fromTrigger)
        glow(.ready)
        onCompletion?(true)
    }

    // MARK: - Notifications ("Holmes prepared something")
    // Same UNUserNotificationCenter idiom as MeetingJoinEngine: request
    // authorization once up front, fire the notification immediately (nil
    // trigger) so a backgrounded Holmes still surfaces new drafts.

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("[Holmes] PlaybookEngine notifications: \(granted ? "granted" : "denied")")
        }
    }

    private func postDraftNotification(for draft: ProactiveDraft) {
        requestNotificationPermissionIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.subtitle = "Holmes prepared something"
        // A staged Gmail draft's TRUE recipient/subject (from the tool-call
        // input) outranks the generic context line — the user must see where
        // an unattended draft is addressed without opening Gmail.
        content.body = draft.stagedNote.map { String($0.prefix(140)) }
            ?? String(draft.contextSummary.prefix(80))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "holmes-draft-\(draft.id)",
            content: content,
            trigger: nil   // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[Holmes] Draft notification error: \(error)") }
        }
    }

    // MARK: - Draft management

    func dismiss(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    func clearDrafts() {
        drafts = []
        // Also purge the ConfirmationBus so "Clear all drafts" can't leave queued
        // ghost cards (or a showing card for a draft that no longer exists).
        ConfirmationBus.shared.clearAllDrafts()
    }

    // MARK: - Enable/disable (backed by UserDefaults)

    // Blind / scheduled playbooks that run with NO screen context (morning-brief,
    // email-triage, follow-up-chaser, pr-radar, schedule-guard, evening-wrapup).
    // Running these unattended is exactly what invented "Inbox triage" and
    // "Reply to Ada" cards out of thin air, so they are DEFAULT OFF — opt-in only
    // via Settings. Every screen-triggered playbook (and manual-only ai-research)
    // stays default ON. Once the user toggles one in Settings the stored value wins.
    static let defaultDisabledPlaybooks: Set<String> = []
    // (The blind/scheduled playbooks this set guarded were removed in the
    // 154→5 purge; kept as an empty set because AutonomyPolicy reads it.)

    static func isEnabled(_ playbookId: String) -> Bool {
        let key = "holmes.playbook." + playbookId + ".enabled"
        // No stored preference yet: blind/scheduled playbooks default OFF (they
        // must never run without screen context); everything else defaults ON.
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return !defaultDisabledPlaybooks.contains(playbookId)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, playbookId: String) {
        UserDefaults.standard.set(enabled, forKey: "holmes.playbook." + playbookId + ".enabled")
        if playbookId == "email-compose", !enabled { EmailDraftCoordinator.shared.cancelAutomaticDraft() }
    }

    // MARK: - Draft-only personas

    /// A manifest author's persona, wrapped so it can only NARROW the built-in
    /// contract. The preamble states the draft-only rule and the epilogue pins
    /// the output shape; the author's text sits between them and cannot undo
    /// either — and the tool filter is code regardless of what the prompt says.
    static func communityPersona(_ persona: String, kind: DraftKind) -> String {
        let trimmed = String(persona.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "You are Holmes, a local assistant on the user's Mac, preparing something for the user to review. "
            + "You work in draft-only mode: you may read the screen and use the read-only tools offered to gather context, "
            + "but you can never send, post, publish, submit, delete, or modify anything — the user reviews and acts. "
            + "Never claim to have taken an action. "
            + "Author's guidance for this playbook: " + trimmed + " "
            + "Your final message must be ONLY the deliverable itself — no preamble, no commentary, no labels."
    }

    private static func systemHint(for kind: DraftKind) -> String {
        switch kind {
        case .emailCompose:
            return EmailDraftInput.systemPrompt
        case .emailReply:
            return "You are Holmes drafting an email reply on the user's behalf. You work in draft-only mode: you may read emails, threads, and screen context to ground the reply, and you may save the reply into the user's own Gmail Drafts folder via GMAIL_CREATE_EMAIL_DRAFT (a draft cannot send itself — the user reviews it in Gmail), but you can never send, forward, or reply directly. Match the sender's formality and the user's likely voice: warm, concise, no filler, no corporate boilerplate. Your final message must be ONLY the reply body text, ready to paste — no subject line, no signature placeholders like [Your Name], no commentary."
        case .promptSuggestion:
            return "You are Holmes, a prompt engineer improving a prompt the user is mid-typing into an AI assistant. You work in draft-only mode: you never submit anything, you only produce an improved prompt for the user to paste. Preserve the user's intent and every concrete fact they wrote; add specificity, context, structure, and a clear description of the desired output. Do not invent requirements the user didn't imply. Your final message must be ONLY the improved prompt text — no preamble, no explanation of what you changed."
        case .repoBrief:
            return "You are Holmes preparing an engineering brief about a GitHub repository. You work in read-only mode: you may fetch repo metadata, open pull requests, and issues to ground the brief, but you can never create, comment, merge, or modify anything. Be crisp and factual — a busy engineer should absorb the whole brief in under a minute. Prefer concrete PR/issue titles and numbers over vague summaries. Your final message must be ONLY the brief itself."
        case .linkedInPost:
            return "You are Holmes ghost-writing a LinkedIn post. You work in draft-only mode: you never post, publish, or share anything — you only produce text for the user to review. Write like a real person: specific, grounded in what the user was actually looking at, first-person, no hashtag spam, no 'I'm humbled to announce', no engagement-bait hooks, no emoji walls. One clear idea, tight paragraphs. Your final message must be ONLY the post text."
        case .meetingPrep:
            return "You are Holmes preparing the user for an imminent meeting. You work in read-only mode: you may read calendar events and email threads to gather context, but you can never send, accept, decline, or modify anything. Produce a scannable prep sheet the user can absorb in 60 seconds: who's attending and their context, the likely agenda, 3-5 talking points, and any open items or unanswered threads with those attendees. Your final message must be ONLY the prep sheet."
        case .chatReply:
            return "You are Holmes drafting a chat reply (iMessage, Discord, or Slack) on the user's behalf. You work in draft-only mode: you never send anything — the user reviews and sends. Mirror the conversation's existing tone and length: casual chats get short, natural, lowercase-friendly replies; work threads get slightly tighter ones. Never sound like an assistant. Your final message must be ONLY the reply text — no quotes around it, no labels."
        case .aiAnswer:
            return "You are Holmes researching a question for the user. You work in read-only mode: you may use any available search, fetch, and AI tools to gather information, but you can never post, publish, or send anything. Synthesize what you find into a direct, well-organized answer and name your sources (titles/URLs) so the user can verify. If sources disagree or evidence is thin, say so plainly. Your final message must be ONLY the answer."
        case .briefing:
            return "You are Holmes preparing the user's daily briefing. You work in read-only mode: you may fetch emails, calendar events, and GitHub notifications to ground the digest, but you can never send, post, modify, or delete anything. Be crisp and concrete — real senders, real event times, real PR/issue titles; never invent items a tool didn't return, and say plainly when a source is empty or unreachable. Your final message must be ONLY the digest."
        case .triage:
            return "You are Holmes triaging the user's inbox. You work in draft-only mode: you may fetch and classify emails, and you may stage replies in the user's own Gmail Drafts folder via GMAIL_CREATE_EMAIL_DRAFT (a draft cannot send itself — the user reviews it in Gmail), but you can never send, archive, delete, or otherwise modify anything. Ground every bucket and every draft in the fetched messages, not guesses. Your final message must be ONLY the triage summary."
        case .followUp:
            return "You are Holmes chasing replies the user is still waiting on. You work in draft-only mode: you may fetch the user's sent mail and threads to find conversations that went quiet, and you may stage short follow-up nudges in the user's own Gmail Drafts folder via GMAIL_CREATE_EMAIL_DRAFT (a draft cannot send itself — the user reviews it in Gmail), but you can never send, forward, archive, delete, or otherwise modify anything. Every nudge must be grounded in a fetched thread — address it only to people who appear in that thread, and never invent a conversation a tool didn't return. Keep nudges polite, warm, and short: two or three sentences, no guilt-tripping. Your final message must be ONLY the follow-up summary."
        case .prRadar:
            return "You are Holmes watching the user's GitHub pull-request radar. You work in read-only mode: you may fetch the authenticated user, pull requests, review requests, comments, and check runs to ground the report, but you can never create, comment, approve, request changes, merge, or modify anything — and you must not create drafts of any kind. Be terse and actionable — real repo names, PR numbers, and titles; never invent items a tool didn't return. Your final message must be ONLY the action list."
        case .scheduleAlert:
            return "You are Holmes auditing the user's upcoming calendar for trouble. You work in read-only mode: you may list and inspect calendar events to ground the warnings, but you can never create, accept, decline, move, or modify anything — and you must not create drafts of any kind. Flag only real problems backed by the fetched events — overlapping meetings, meetings with no video link, punishing back-to-back stretches — each with a concrete, actionable suggestion. Your final message must be ONLY the warnings and suggestions."
        case .wrapup:
            return "You are Holmes closing out the user's day. You work in read-only mode: you may fetch today's emails, tomorrow's calendar, and today's GitHub activity to ground the recap, but you can never send, post, modify, or delete anything — and you must not create drafts of any kind. Be honest and concrete — real senders, real event times, real PR/issue titles; say plainly when a source is empty or unreachable. Keep it tight enough to read in 30 seconds. Your final message must be ONLY the wrap-up."
        }
    }
}
