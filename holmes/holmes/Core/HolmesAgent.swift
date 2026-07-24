import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import Observation

// MARK: - HolmesAgent
// The perception loop. Everything Holmes claims to see flows through here, in
// three strictly separated tiers:
//
//   TIER 0 — INSTANT, NO MODEL. A LiveContext arrives (browser extension DOM,
//     Accessibility tree, or OCR) and its deterministic headline goes straight
//     onto the card in the same runloop turn. Zero network, zero latency, zero
//     hallucination: the sentence was computed from structured data, never
//     generated. This tier is also what persists to memory.
//
//   TIER 1 — ENRICHMENT, NON-BLOCKING. Once per changed screen (and at most
//     once per 8s per screen), Claude is asked ONE question: what is the user
//     trying to accomplish here. It may add a goal and a gist behind the
//     already-correct headline; it may never make the headline vaguer, and it
//     can never touch a .exact one at all (see acceptedHeadline).
//
//   PRECEDENCE — the browser extension outranks the screenshot. When the
//     frontmost app is a browser and extension data landed within the last few
//     seconds, the OCR path is skipped entirely for that tick: no OCR, no
//     .inferred context, no overwriting an exact headline with a guess.
//     Playbooks still evaluate on every tick regardless — that separation is
//     load-bearing (see processSnapshot).

@Observable
@MainActor
final class HolmesAgent {
    static let shared = HolmesAgent()

    // ── Published state ─────────────────────────────
    /// The single source of truth for "what is the user doing RIGHT NOW".
    /// Everything else on this object is derived from it.
    var live: LiveContext = .unknown
    /// The card's view model — description is always `live.headline`, verbatim.
    var currentContext: DetectedContext = .unknown
    /// Enrichment behind the headline: the user's apparent GOAL, plus the
    /// entities that identify this task. Never the source of the headline.
    var deepContext: ContextEngine.DeepContext? = nil
    /// Past points of interest that match the CURRENT task — reactivated
    /// memory the agent can draw on when a similar task recurs. Empty unless
    /// the current screen is a point of interest with prior matches.
    var relatedMemories: [MemoryEvent] = []
    /// A reply Holmes wrote by itself, waiting for the user. Set the moment
    /// IncomingMessageWatcher notices an inbound question and the draft comes
    /// back — never in response to anything the user did. Read by MainPanelView
    /// (top card) and by the floating review card. See "Pending reply" below
    /// for the invariant it shares with `pendingReplyTo`.
    var pendingReply: ReplyComposer.DraftedReply?
    /// The message `pendingReply` answers. Written and cleared in the same
    /// statement as `pendingReply` — the two are ONE fact, and a card that
    /// quoted one message while showing a draft for another would be worse
    /// than showing no card at all.
    var pendingReplyTo: ReplyComposer.IncomingMessage?
    var suggestedActions: [ActionSuggestion] = []
    var recentActivities: [ActivityItem] = []
    var isAnalyzing: Bool = false
    var hasNewContext: Bool = false
    var modelBackend: String = "Starting..."
    var lastUpdated: Date? = nil

    // Cleanest text we have for the current screen — DOM/AX text where possible,
    // OCR only as a last resort. Consumed by HolmesBrain, MCPServer and the
    // command bar when building prompts.
    private(set) var lastOCRText: String = ""
    /// How the text in `lastOCRText` was obtained. OCR mush is usable for
    /// heuristic matching but must never be presented to a model as literal, so
    /// the tier travels WITH the text instead of being lost at the assignment.
    /// Every consumer prints `lastTextConfidence.textReliabilityNote` above the
    /// block it pastes in; MCPServer publishes the raw value alongside it.
    private(set) var lastTextConfidence: ContextConfidence = .inferred
    private(set) var lastSnapshot: ContextSnapshot? = nil

    private init() {}

    // MARK: - Start

    func start() async {
        modelBackend = AnthropicConfig.isConfigured
            ? "Claude (\(AnthropicConfig.model))"
            : "No API key — add one in Settings to enable Claude"

        // Browser extension bridge — the ONLY source of exact context. The
        // callback is invoked on the main actor, and tier 0 runs synchronously
        // inside it on purpose: the card must update in this same runloop turn,
        // with no Task hop that a slower path could win.
        BrowserBridge.shared.onLiveContext = { [weak self] context in
            self?.applyLiveContext(context)
        }
        BrowserBridge.shared.start()

        // Screen engine — Accessibility first, OCR only when AX gives nothing.
        ScreenEngine.shared.onNewSnapshot = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                await self.processSnapshot(result)
            }
        }

        await ScreenEngine.shared.start()

        // Calendar engine — monitors upcoming meetings, fires MeetingJoinEngine
        await CalendarEngine.shared.start()

        // Agentic action brain — connects MCP servers in the background, then
        // republishes the model label with the tool count.
        HolmesBrain.shared.start()

        // Proactive playbooks — draft-only automations evaluated on every context tick.
        PlaybookEngine.shared.start()

        // Inbound messages — the automatic half of the reply feature. The
        // watcher only DETECTS; the draft is kicked off here, in the same
        // runloop turn it fires, so the answer is already written by the time
        // the user opens Holmes. Nothing in this path sends: see draftReply(to:).
        IncomingMessageWatcher.shared.onIncoming = { [weak self] message in
            self?.draftReply(to: message)
        }
        IncomingMessageWatcher.shared.start()

        // Autopilot (time-based scheduler) is retired: its scheduled playbooks
        // (morning-brief, email-triage, …) were removed in the 154→5 purge, so
        // starting it would only fire "playbook not found" every tick.

        // MCP *server* — exposes Holmes's live screen context to other agents
        // (Claude Desktop, Cursor, voice agents) on http://127.0.0.1:5767/mcp.
        // OPT-IN (default off): the endpoint has no auth and would relay
        // TCC-gated screen content to any local process, so it only starts when
        // the user enabled it in Settings > Privacy.
        if MCPServer.isEnabledByUser {
            MCPServer.shared.start()
        }

        print("[Holmes] Agent started — \(modelBackend)")
    }

    func stop() {
        ScreenEngine.shared.stop()
        BrowserBridge.shared.stop()
        IncomingMessageWatcher.shared.stop()
    }

    // MARK: - TIER 0 — apply a LiveContext (instant, no model)

    /// The whole fast path. Synchronous by design: by the time this returns, the
    /// UI shows a sentence that was computed from structured data. Persistence
    /// and enrichment are kicked off afterwards and never block it.
    func applyLiveContext(_ context: LiveContext) {
        // THE PRECEDENCE INVARIANT, enforced at the single point every reading
        // passes through: a WEAKER reading never replaces a stronger one that
        // still describes the SAME app inside the browser TTL. This is not
        // belt-and-braces for one caller — processSnapshot suspends for hundreds
        // of milliseconds inside `await OCREngine.recognize`, and BrowserBridge
        // delivers on this very actor, so an exact context can land mid-await and
        // be overwritten by the guess that was already in flight. A genuine app
        // switch changes `app`, so only that reentrancy case is blocked here.
        if context.confidence.rank < live.confidence.rank,
           context.app == live.app,
           Date().timeIntervalSince(live.capturedAt) < Self.browserContextTTL {
            // The reading is dropped, but the analysis it belonged to is over —
            // leaving this true would strand the panel on "Analyzing your screen…".
            isAnalyzing = false
            print("[Holmes] Kept \(live.confidence.rawValue) context for \(live.app) — refused a \(context.confidence.rawValue) downgrade")
            return
        }

        live = context
        if context.source == .browserExtension {
            lastBrowserContextAt = Date()
        }

        // The card says exactly what LiveContext determined — never a paraphrase,
        // never a model's version of it.
        currentContext = DetectedContext(icon: Self.icon(for: context),
                                         description: context.headline,
                                         appName: context.app)
        lastUpdated = Date()
        hasNewContext = true
        isAnalyzing = false

        // Prompt-building text. `bodyText` is contractually clean (DOM or AX);
        // an OCR context carries "" here, which is the point — nothing
        // downstream can quote pixels back to the user as fact.
        lastOCRText = context.bodyText
        lastTextConfidence = context.confidence
        let snapshot = ContextSnapshot(appName: context.app,
                                       windowTitle: context.title,
                                       ocrText: context.bodyText,
                                       timestamp: context.capturedAt)
        lastSnapshot = snapshot

        suggestedActions = suggestions(for: context, snapshot: snapshot)

        // Deterministic opportunity detection reads this, not OCR text.
        TriggerBrain.shared.noteLiveContext(context)

        // The inbound-message watcher polls BrowserBridge on its own timer, so
        // web chats reach it either way — but an ACCESSIBILITY reading (Mail.app
        // and every other native client) never goes near the bridge, and this
        // push is the only way it ever sees one. Cheap by contract: a context it
        // has already examined is dropped on its capture time.
        IncomingMessageWatcher.shared.noteLiveContext(context)

        // Is this a different screen, or the same one re-observed? The extension
        // posts on every keystroke, so almost everything below is gated on the
        // fingerprint — it is stable while a draft grows or a video plays.
        let isNewScreen = context.fingerprint != lastAppliedFingerprint
        lastAppliedFingerprint = context.fingerprint

        // Persist immediately. recordLiveContext drops .inferred contexts and
        // dedupes on the fingerprint, so this is safe to call on every tick; the
        // dashboard is only nudged when a new row could plausibly have landed.
        Task { @MainActor in
            await MemoryStore.shared.recordLiveContext(context)
            if isNewScreen { MemoryFeed.shared.markDirty() }
        }

        if isNewScreen {
            logActivity(context: currentContext)
            print("[Holmes] \(context.confidence.rawValue)/\(context.source.rawValue): \(context.headline)")
            // Surface the change in the notch HUD — but only for a SPECIFIC reading,
            // never a fallback ("can't see your screen") that would assert nothing.
            if context.entities["headlineKind"] != "fallback" {
                let activity = context.activity == "other" || context.activity.isEmpty
                    ? context.app
                    : "You're \(context.activity)"
                NotchWindowController.shared.flashContext(
                    context.headline,
                    icon: Self.icon(for: context),
                    activity: activity)
            }
        }

        // TIER 1 — behind the headline, never in front of it.
        enrichLiveContext(context)
    }

    // MARK: - Snapshot path (Accessibility / OCR)

    private var isRunningOCR = false
    /// Fingerprint of the last context we applied — the "is this actually a
    /// different screen?" gate for logging and dashboard refreshes.
    private var lastAppliedFingerprint = ""
    /// When the browser extension last delivered context. The precedence gate.
    private var lastBrowserContextAt: Date = .distantPast
    /// How long extension data keeps outranking the screenshot path for a
    /// browser window. The extension posts on every real change plus a 5s
    /// heartbeat, so six seconds means "the extension is alive right now".
    private static let browserContextTTL: TimeInterval = 6
    /// The real screenshot tied to the latest OCR snapshot — fed to Claude's
    /// vision during enrichment when the text was too thin to describe.
    private var lastCapturedImage: CGImage? = nil

    private func processSnapshot(_ result: CaptureResult) async {
        let appName = result.appName
        let windowTitle = result.windowTitle
        // Skip Holmes itself — only analyze other apps
        guard !appName.lowercased().contains("holmes") else { return }
        guard !isRunningOCR else { return }
        isRunningOCR = true
        defer { isRunningOCR = false }

        // Capture failed entirely (Screen Recording permission stale) — show a clear
        // message instead of freezing on "Analyzing your screen…", and stop early.
        if result.axOverride == "__NO_SCREEN_ACCESS__" {
            currentContext = DetectedContext(
                icon: "eye.slash",
                description: "Can't see your screen — enable Screen Recording for Holmes in System Settings ▸ Privacy & Security, then quit and reopen Holmes.",
                appName: appName
            )
            lastUpdated = Date()
            isAnalyzing = false
            print("[Holmes] No screen access — prompting user to grant Screen Recording")
            return
        }

        // ── PRECEDENCE ──────────────────────────────────────────────────────
        // A browser with a live extension is READ, not guessed at. Skip OCR
        // entirely: don't run it, don't build an .inferred context, don't
        // overwrite the exact headline that's already on the card.
        let isBrowser = Self.isBrowserApp(appName)
        let extensionIsLive = Date().timeIntervalSince(lastBrowserContextAt) < Self.browserContextTTL
        if isBrowser && extensionIsLive {
            // Playbooks STILL evaluate. The old build skipped them together with
            // the OCR, which silently suppressed every auto playbook on Comet
            // whenever the extension had posted recently — email / GitHub / chat
            // actions never fired. Evaluation runs off the extension's own clean
            // text, which is strictly better input than OCR ever was.
            if let snapshot = lastSnapshot {
                evaluatePlaybooks(snapshot: snapshot)
            }
            isAnalyzing = false
            return
        }

        isAnalyzing = true
        print("[Holmes] Analyzing — app: \(appName)")

        // 1. AX text if the app exposes any, otherwise OCR the captured image.
        //    Both text and image come from THIS capture, never re-read from
        //    shared state after a suspension, so app/text/image/focus can't
        //    belong to different screens during an app switch.
        // A structured AX reading (native apps) always wins over OCR — it carries
        // the file/line/symbol or cwd/command Holmes read from targeted attributes,
        // and OCR is never even attempted when one is present.
        let axReading = result.reading
        let axText: String
        var ocrText = ""
        if let axReading {
            axText = axReading.bodyText
            print("[Holmes] AX reading (\(axReading.kind.rawValue), \(axText.count) chars): file=\(axReading.fileName ?? "-") cmd=\(axReading.command ?? "-") cwd=\(axReading.workingDir ?? "-") sym=\(axReading.symbol ?? "-")")
        } else if let text = result.axOverride, !text.isEmpty {
            axText = text
            print("[Holmes] AX text (\(text.count) chars): \(String(text.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        } else if let image = result.image {
            let ocr = await OCREngine.shared.recognize(image: image)
            ocrText = ocr.fullText
            axText = ""
            print("[Holmes] OCR (\(ocr.fullText.count) chars): \(String(ocr.fullText.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        } else {
            axText = ""
        }

        // Keep the real screenshot for vision only when it's usable (non-blank).
        lastCapturedImage = result.visionUsable ? result.image : nil

        // ── PRECEDENCE, RE-EVALUATED ────────────────────────────────────────
        // The OCR above suspended for hundreds of milliseconds (Vision on a
        // Retina display is 200-1000ms), and the bridge delivers on THIS actor —
        // `BrowserBridge.ingest` hops in via `Task { @MainActor in … }`, so it
        // runs *inside* that suspension. That is actor reentrancy, not a race the
        // `isRunningOCR` flag covers (it only guards processSnapshot against
        // itself). The gate at the top of this function was decided before the
        // await; deciding again here, off state read at THIS instant, is what
        // stops a finished OCR pass from replacing a fact with a guess — and stops
        // a mid-Vision cmd-tab from stamping the old app's reading over the new
        // one.
        let frontmostNow = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let extensionLiveNow = Date().timeIntervalSince(lastBrowserContextAt) < Self.browserContextTTL
        // Holmes's own panel in front doesn't change WHICH app this reading is of.
        let stillSameScreen = frontmostNow.isEmpty
            || frontmostNow == appName
            || frontmostNow.lowercased().contains("holmes")
        let browserOwnsScreenNow = extensionLiveNow && (isBrowser || Self.isBrowserApp(frontmostNow))
        guard stillSameScreen, !browserOwnsScreenNow else {
            // Playbooks still evaluate — the same separation the gate above keeps.
            // Their input is the freshest snapshot, which is now the extension's
            // clean text rather than this stale OCR.
            if let snapshot = lastSnapshot { evaluatePlaybooks(snapshot: snapshot) }
            print("[Holmes] Discarded a \(isBrowser ? "browser" : "screenshot") reading of \(appName) — \(browserOwnsScreenNow ? "exact context landed during OCR" : "frontmost app is now \(frontmostNow)")")
            isAnalyzing = false
            return
        }

        // 2. Build the LiveContext for this screen — the ONLY place the source
        //    tier is decided.
        let context: LiveContext
        if isBrowser {
            // Browser, no extension data. Say that, precisely, instead of
            // narrating a page Holmes cannot actually read.
            context = BrowserBridge.shared.unavailableContext(window: windowTitle)
        } else if let axReading {
            // Native app with a real AX reading — .structural, never .inferred.
            context = LiveContextBuilder.fromAccessibility(
                reading: axReading,
                focused: result.focused.map(FocusedField.init))
        } else if !axText.isEmpty {
            context = LiveContextBuilder.fromAccessibility(
                app: appName, window: windowTitle, axText: axText,
                focused: result.focused.map(FocusedField.init))
        } else {
            context = LiveContextBuilder.fromOCR(
                app: appName, window: windowTitle, ocrText: ocrText)
        }

        applyLiveContext(context)

        // 3. Playbooks always get the freshest text we have, even when that text
        //    is too weak to describe the screen out loud. The two decisions are
        //    independent: "can Holmes state a fact about this?" is a much higher
        //    bar than "does a heuristic matcher recognize this?".
        let playbookText = axText.isEmpty ? ocrText : axText
        if !playbookText.isEmpty || !windowTitle.isEmpty {
            evaluatePlaybooks(snapshot: ContextSnapshot(appName: appName,
                                                        windowTitle: windowTitle,
                                                        ocrText: playbookText,
                                                        timestamp: Date()))
        }
        // The OCR text never reaches `live.bodyText` (LiveContextBuilder.fromOCR
        // blanks it on purpose), but the command bar and MCP server still need
        // *something* for an unreadable native app. It is stored WITH its tier:
        // this is the one place pixels enter the prompt-building path, and every
        // consumer labels the block with `lastTextConfidence` so a model is never
        // handed OCR mush that looks the same as a literal DOM read.
        if !ocrText.isEmpty {
            lastOCRText = ocrText
            lastTextConfidence = .inferred
        }
    }

    // MARK: - Pending reply (unprompted, and never sent)
    //
    // The other half of IncomingMessageWatcher. The watcher decides that someone
    // asked the user something; this decides what to say back, starting the
    // instant the message is detected rather than when the user gets around to
    // looking. By the time they open Holmes the draft — and the memory rows it
    // was built from — are already on the card.
    //
    // DRAFT-NEVER-SEND, restated where it matters: nothing in this section, and
    // nothing it calls, presses Send, posts to a service, or synthesizes a
    // keystroke. ReplyComposer produces text; ConfirmationBus shows it; the
    // user's own tap on Insert/Copy is the only thing that moves a word, and
    // even Insert only types into the field and stops.

    /// The user's current wording for `pendingReply`.
    ///
    /// @ObservationIgnored on purpose. Every keystroke in the review card lands
    /// here, and a tracked property would invalidate — and therefore re-sync —
    /// the very editor that produced it. `pendingReplyDraft` folds it back in at
    /// read time, so whichever card opens next starts from what the user typed.
    @ObservationIgnored private var pendingReplyEdit: String = ""

    /// Monotonic id of the newest draft REQUESTED. A model call for an older
    /// message can land after a newer one (they overlap freely), and the user
    /// must never be shown an answer to the message before last.
    @ObservationIgnored private var replyDraftSeq = 0

    /// How many reply drafts are being written right now. Non-zero from the
    /// instant a message is detected until its draft lands or fails — the window
    /// in which the subject recall is already on the dashboard but there is not
    /// yet a draft to point at it.
    @ObservationIgnored private var replyDraftsInFlight = 0

    /// May the ACTIVITY-keyed reactivation (reactivateMemory) publish over the
    /// referenced rows?
    ///
    /// Not while a SUBJECT recall is standing: "everything memory holds about
    /// the thing somebody asked about" is a strictly more specific claim than
    /// "rows that resemble the screen you're on", and it is the one a pending
    /// draft's receipts refer to. The hold lasts as long as the draft does, or —
    /// when no draft could be produced at all, e.g. no API key — for
    /// RecallSpotlight's own grace period, so the answer to "what is holmes?" is
    /// still on the dashboard when the user gets round to looking at it.
    private var mayPublishActivityRecall: Bool {
        guard !RecallSpotlight.shared.topics.isEmpty else { return true }
        guard pendingReply == nil, replyDraftsInFlight == 0 else { return false }
        return !RecallSpotlight.shared.holdsSubjectRecall
    }

    /// What the cards actually render: the pending draft carrying the user's
    /// edits. Everything else on it — the grounding rows, the confidence tier,
    /// the recall receipts — is the drafter's, untouched.
    var pendingReplyDraft: ReplyComposer.DraftedReply? {
        guard let draft = pendingReply else { return nil }
        guard !pendingReplyEdit.isEmpty, pendingReplyEdit != draft.body else { return draft }
        return ReplyComposer.DraftedReply(body: pendingReplyEdit,
                                          groundedIn: draft.groundedIn,
                                          background: draft.background,
                                          confidence: draft.confidence,
                                          recallHits: draft.recallHits,
                                          topics: draft.topics)
    }

    /// Records an edit from a review card. Cheap and silent — see
    /// `pendingReplyEdit`.
    func notePendingReplyEdit(_ body: String) {
        pendingReplyEdit = body
    }

    /// Drops the pending reply and closes the floating card with it. The user
    /// dismissed the answer; leaving half of it on screen would be a ghost.
    func clearPendingReply() {
        pendingReply = nil
        pendingReplyTo = nil
        pendingReplyEdit = ""
        ConfirmationBus.shared.hideReplyCard()
    }

    /// Starts a grounded draft for a message that JUST arrived.
    ///
    /// Synchronous entry, asynchronous body: detection must never block on the
    /// network, so this captures the current screen and returns immediately. The
    /// draft lands on `pendingReply` whenever it is ready.
    ///
    /// The LiveContext is captured HERE rather than read inside the Task,
    /// because "what the user was doing when the message arrived" is the fact
    /// the reply is grounded in — by the time a model answers they may well have
    /// switched apps.
    private func draftReply(to message: ReplyComposer.IncomingMessage) {
        replyDraftSeq += 1
        let sequence = replyDraftSeq
        // `.unknown` is an admission that nothing has been read, not a reading.
        // Passing it would put "Holmes can't see your screen right now" into the
        // prompt as if it described the user; nil says the same thing honestly.
        let context: LiveContext? = (live.source == .none) ? nil : live
        let who = message.sender.trimmingCharacters(in: .whitespaces)

        replyDraftsInFlight += 1
        Task { @MainActor in
            // Balanced on every exit, including the two guards below: the
            // counter is what protects the freshly-published recall from being
            // overwritten before its draft exists (see mayPublishActivityRecall).
            defer { replyDraftsInFlight -= 1 }

            // draftReply runs the topic recall FIRST and publishes it, so the
            // dashboard's REFERENCED NOW section fills in even when this call
            // comes back nil (no API key, unparseable answer).
            guard let draft = await ReplyComposer.shared.draftReply(to: message, context: context) else {
                print("[Holmes] Reply: no draft for \(who.isEmpty ? message.surface : who) — recall was still published")
                return
            }
            // A newer message overtook this one while the model was thinking.
            // Its draft is the current one; this answer is already stale.
            guard sequence == replyDraftSeq else {
                print("[Holmes] Reply: discarded a stale draft for \(who.isEmpty ? message.surface : who)")
                return
            }

            pendingReply = draft
            pendingReplyTo = message
            pendingReplyEdit = draft.body

            let rows = draft.groundedIn.count
            let subject = draft.topics.first.map { " about \"\($0)\"" } ?? ""
            logActivity(note: "Drafted a reply to \(who.isEmpty ? message.surface : who)\(subject)"
                        + " — grounded in \(rows) memor\(rows == 1 ? "y" : "ies")")
            print("[Holmes] Reply ready for \(who.isEmpty ? message.surface : who)\(subject) — \(rows) grounding row(s), \(draft.confidence.rawValue)")

            // The floating review card. Returns false when a live approval is
            // already on screen — the panel card above ContextCard is the
            // surface that is always there, so nothing is lost either way.
            if !ConfirmationBus.shared.showReplyCard() {
                print("[Holmes] Reply card deferred — an approval is on screen; the draft is waiting in the panel")
            }
        }
    }

    // MARK: - Proactive playbooks

    /// Classifies the snapshot, folds in imminent-meeting entities, and hands the
    /// resulting PlaybookContext to the PlaybookEngine for evaluation.
    private func evaluatePlaybooks(snapshot: ContextSnapshot) {
        let classified = ContextEngine.shared.classify(snapshot: snapshot)
        var entities = classified.entities

        // Meeting starting within 15 minutes → let the meeting-prep playbook fire.
        if let meeting = CalendarEngine.shared.upcomingMeetings.first(where: { $0.minutesUntil <= 15 }) {
            entities["eventTitle"] = meeting.title
            entities["eventId"] = meeting.id
        }

        let ctx = PlaybookContext(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            contextType: classified.type.rawValue,
            screenText: snapshot.ocrText,
            entities: entities
        )
        print("[Holmes] Playbook eval — type: \(classified.type.rawValue), app: \(snapshot.appName), entities: [\(entities.keys.sorted().joined(separator: ", "))]")
        PlaybookEngine.shared.evaluate(ctx)
    }

    // MARK: - TIER 1 — enrichment (goal + entities, behind the headline)

    private var isRunningEnrichment = false
    private var lastEnrichFingerprint = ""
    private var lastEnrichAttemptAt: Date = .distantPast
    /// Floor between enrichment CALLS. Each distinct screen is asked about once;
    /// this bounds how fast a user flipping between screens can spend tokens.
    private static let enrichFloor: TimeInterval = 8
    /// IDs of the last reactivated memory set we announced — dedupes the
    /// "Recalled N…" activity note across re-enrichments of the same screen.
    private var lastReactivationSignature = ""
    /// Below this, the extracted text is too thin to describe a screen with, and
    /// the (expensive) vision path earns its place.
    private static let thinTextThreshold = 220
    /// When vision last ran. A churning visual screen must not send a screenshot
    /// on every enrichment.
    private var lastVisionAt: Date = .distantPast
    private static let visionMinInterval: TimeInterval = 40

    /// Downscales + JPEG-encodes OFF the main actor — tens of milliseconds of
    /// work that must never jank the UI.
    private static func encodeForVisionOffMain(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: VisionEncoder.encode(image))
            }
        }
    }

    /// Deep context only when it describes the screen the user is on RIGHT
    /// NOW. Prompt-building consumers (HolmesBrain) must use this, never raw
    /// deepContext — a stale "working on X" from a previous screen would
    /// misground every run until the next successful enrichment.
    var currentDeepContext: ContextEngine.DeepContext? {
        guard let deep = deepContext, live.fingerprint == lastEnrichFingerprint else { return nil }
        return deep
    }

    /// Asks Claude ONE question about an already-described screen: what is the
    /// user trying to get done. Single-flight, fingerprint-gated, and applied
    /// only if the user is still on the same screen when the answer lands.
    private func enrichLiveContext(_ context: LiveContext) {
        guard AnthropicConfig.isConfigured else { return }
        // Never enrich a guess. An .inferred context has no facts to build on,
        // and dressing one up with a plausible "goal" is exactly the failure
        // mode this architecture exists to prevent.
        guard context.confidence != .inferred else { return }
        guard !isRunningEnrichment else { return }

        // Once per SCREEN, not once per tick: a screen already enriched has
        // nothing new to say, and the extension posts on every keystroke.
        let fingerprint = context.fingerprint
        guard fingerprint != lastEnrichFingerprint else { return }
        // …and never faster than the floor, however quickly screens change. A
        // screen skipped here is retried on a later tick, which doubles as the
        // backoff after a failed call (the fingerprint is only recorded on
        // success, so a failure re-queues rather than sticking).
        guard Date().timeIntervalSince(lastEnrichAttemptAt) >= Self.enrichFloor else { return }

        isRunningEnrichment = true
        let requestedAt = Date()
        lastEnrichAttemptAt = requestedAt

        Task { @MainActor in
            defer { isRunningEnrichment = false }

            // Vision escalation, narrowly scoped: a STRUCTURAL context whose text
            // came back too thin to reason about, where a real screenshot exists.
            // Never on an .exact context (the DOM already told us everything),
            // never on .inferred (we bailed above), and never behind a FALLBACK
            // headline — a thin structural read is exactly the shape that produces
            // "Holmes can read the window but can't identify a specific task on
            // it", and pixels may add a goal behind a real reading, never behind
            // an admission of blindness.
            var imageBase64: String? = nil
            if context.confidence == .structural,
               context.entities["headlineKind"] != "fallback",
               context.bodyText.count < Self.thinTextThreshold,
               Date().timeIntervalSince(lastVisionAt) > Self.visionMinInterval,
               let image = lastCapturedImage {
                imageBase64 = await Self.encodeForVisionOffMain(image)
                if imageBase64 != nil { lastVisionAt = Date() }
            }

            let raw: String
            do {
                raw = try await AnthropicClient.shared.complete(
                    system: Self.enrichmentSystemPrompt,
                    user: Self.enrichmentPrompt(for: context),
                    maxTokens: 400,
                    asJSON: true,
                    schema: Self.enrichmentSchema,
                    imageBase64: imageBase64)
            } catch {
                print("[Holmes] Enrichment failed — \(error.localizedDescription)")
                return
            }

            guard let parsed = Self.parseEnrichment(raw) else {
                print("[Holmes] Enrichment: unparseable reply — ignored")
                return
            }

            // The user may have moved on while the model was thinking. Applying
            // an answer about the previous screen is worse than applying none.
            guard live.fingerprint == fingerprint else {
                print("[Holmes] Enrichment discarded — screen changed during the call")
                return
            }

            lastEnrichFingerprint = fingerprint

            let enriched = Self.merge(parsed, into: context)
            live = enriched
            currentContext = DetectedContext(icon: Self.icon(for: enriched),
                                             description: enriched.headline,
                                             appName: enriched.app)
            lastUpdated = Date()

            deepContext = ContextEngine.DeepContext(
                activity: enriched.activity,
                summary: enriched.headline,
                details: enriched.detail,
                entities: enriched.entities,
                actions: [],
                app: enriched.app,
                windowTitle: enriched.title,
                timestamp: Date())

            let elapsed = Int(Date().timeIntervalSince(requestedAt) * 1000)
            print("[Holmes] Enriched in \(elapsed)ms — goal: \(parsed.goal.isEmpty ? "(none)" : parsed.goal)")

            reactivateMemory(for: enriched)
        }
    }

    /// Pulls prior work that matches this screen so a recurring task benefits
    /// from what the user did last time, and tells the dashboard which rows the
    /// agent is actually leaning on.
    private func reactivateMemory(for context: LiveContext) {
        // Search on what IDENTIFIES this task: the enriched goal plus the
        // entities that name a specific thing. Generic keys (surface, activity)
        // are excluded — they match everything, which matches nothing useful.
        var parts: [String] = []
        if let goal = context.entities["goal"], !goal.isEmpty { parts.append(goal) }
        for key in Self.identifyingEntityKeys.sorted() {
            if let value = context.entities[key], !value.isEmpty { parts.append(value) }
        }
        let terms = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else {
            relatedMemories = []
            // Clears the referenced rows AND the "recalled for:" subject
            // together — they are one state, and a subject left standing over a
            // cleared row set would be a claim about nothing. Skipped entirely
            // when a subject recall outranks this path (see below): wiping the
            // strip is a write like any other.
            if mayPublishActivityRecall { RecallSpotlight.shared.clear() }
            return
        }

        let activity = context.activity
        let summary = context.headline
        let site = context.site ?? context.url ?? ""
        let fingerprint = context.fingerprint

        Task { @MainActor in
            let similar = await MemoryStore.shared.findSimilar(
                activity: activity, terms: terms, site: site, excludingSummary: summary)
            // Surface reactivations only while the user is still on the screen
            // that triggered them.
            guard live.fingerprint == fingerprint else { return }
            relatedMemories = similar
            // Published through the spotlight rather than straight to the feed:
            // these rows matched the user's CURRENT ACTIVITY, not a subject
            // somebody named, so the subject list is explicitly emptied. Writing
            // the rows without it would leave a stale "recalled for: holmes"
            // sitting over a completely different set of rows.
            //
            // …and only when nothing more specific is already there. Enrichment
            // of the Messages window finishes a second or two AFTER an inbound
            // question triggered a subject recall, so without this guard the
            // dashboard would answer "what is holmes?" and then quietly replace
            // the evidence with rows that merely look like chatting.
            if mayPublishActivityRecall {
                RecallSpotlight.shared.spotlight(topics: [], events: similar)
            }

            // Only announce a reactivation when the matched set actually changed —
            // re-enrichment of a dwelt screen finds the same rows and must not
            // spam the feed.
            let signature = similar.map { String($0.id) }.joined(separator: ",")
            if !similar.isEmpty, signature != lastReactivationSignature {
                lastReactivationSignature = signature
                logActivity(note: "Recalled \(similar.count) related note\(similar.count == 1 ? "" : "s") on \(activity)")
                print("[Holmes] Memory reactivated — \(similar.count) prior \(activity) note(s) for: \(summary)")
            } else if similar.isEmpty {
                lastReactivationSignature = ""
            }
        }
    }

    /// Entity keys specific enough to search memory with. Deliberately excludes
    /// generic ones (surface, activity) that would match everything.
    private static let identifyingEntityKeys: Set<String> = [
        "sender", "recipient", "subject", "contact", "channel", "repo", "file",
        "prTitle", "issueTitle", "docTitle", "articleTitle", "query", "prompt",
        "topic", "product", "command"
    ]

    // MARK: Enrichment prompt + schema

    private static let enrichmentSystemPrompt = """
    You add ONE layer of interpretation on top of a description that is already \
    correct. Holmes read the user's screen from structured data (browser DOM or \
    macOS Accessibility) and produced the headline below deterministically — it \
    is a fact, not a guess, and it is not up for revision.

    Your job is to name the user's likely GOAL: what they are trying to get done \
    on this screen, in one short clause. Use only what the context gives you. \
    Never invent names, numbers, dates, or claims. If the context does not \
    support a goal, return an empty string — an empty answer is correct and \
    expected; a plausible-sounding invention is not.
    """

    /// Only the sanctioned enrichment slots. `entities` is a fixed shape on
    /// purpose: structured outputs reject undeclared keys, so the model cannot
    /// smuggle a new fact into a field the formatter might read.
    private static let enrichmentSchema: [String: Any] = AnthropicClient.objectSchema([
        "goal": [
            "type": "string",
            "description": "What the user is trying to accomplish, one short clause. Empty string when unsupported by the context."
        ],
        "lastMessageGist": [
            "type": "string",
            "description": "For a conversation only: a 6-word paraphrase of the most recent incoming message. Empty string otherwise."
        ],
        "headline": [
            "type": "string",
            "description": "Optional MORE specific version of the headline. It MUST begin with the exact headline text given to you and only add detail after it. Empty string to leave the headline alone."
        ]
    ])

    private static func enrichmentPrompt(for context: LiveContext) -> String {
        var lines = [
            "Headline (established fact, verbatim): \(context.headline)",
            "App: \(context.app)",
            "Reading quality: \(context.confidence.rawValue) via \(context.source.label)"
        ]
        if let site = context.site { lines.append("Site: \(site)") }
        if !context.activity.isEmpty { lines.append("Activity: \(context.activity)") }
        if !context.detail.isEmpty {
            lines.append("Structured detail:\n\(context.detail)")
        }
        if !context.bodyText.isEmpty {
            lines.append("Page text (verbatim, may be truncated):\n\"\"\"\n\(String(context.bodyText.prefix(2500)))\n\"\"\"")
        }
        return lines.joined(separator: "\n")
    }

    private struct Enrichment {
        let goal: String
        let lastMessageGist: String
        let headline: String
    }

    private static func parseEnrichment(_ raw: String) -> Enrichment? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func string(_ key: String) -> String {
            (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Enrichment(goal: String(string("goal").prefix(200)),
                          lastMessageGist: String(string("lastMessageGist").prefix(200)),
                          headline: String(string("headline").prefix(200)))
    }

    /// Folds the enrichment into a new LiveContext. Only two entity keys and the
    /// detail block can change; the source, confidence and fingerprint inputs are
    /// untouched, so an enriched context still dedupes and gates identically.
    private static func merge(_ enrichment: Enrichment, into base: LiveContext) -> LiveContext {
        var entities = base.entities
        if !enrichment.goal.isEmpty { entities["goal"] = enrichment.goal }
        if !enrichment.lastMessageGist.isEmpty {
            entities["lastMessageGist"] = enrichment.lastMessageGist
        }
        let detail = enrichment.goal.isEmpty
            ? base.detail
            : base.detail + "\nLikely goal: \(enrichment.goal)"

        return LiveContext(
            source: base.source,
            confidence: base.confidence,
            app: base.app,
            site: base.site,
            url: base.url,
            title: base.title,
            activity: base.activity,
            headline: acceptedHeadline(base: base, candidate: enrichment.headline),
            detail: detail,
            entities: entities,
            selection: base.selection,
            focusedField: base.focusedField,
            media: base.media,
            bodyText: base.bodyText,
            capturedAt: base.capturedAt)
    }

    /// THE GUARD. A model may only ever ADD to what Holmes already established.
    ///
    ///   • An .exact headline was read literally off the page — nothing a model
    ///     says about it can be more accurate, so it is never replaced.
    ///   • A FALLBACK headline established nothing. It is the sentence Holmes
    ///     emits when it could NOT read the screen, so there is no reading to
    ///     append to and monotonicity alone doesn't help: "In Notes — Holmes can
    ///     read the window but can't identify a specific task on it. Drafting the
    ///     Q3 board update for Sarah." satisfies prefix-and-longer while being
    ///     entirely invented. Rule 3 defeated by concatenation — so refuse.
    ///   • Any other refinement must contain the deterministic sentence verbatim
    ///     as its prefix and be strictly longer. That makes "refine" mean
    ///     "append specifics", and makes it structurally impossible to swap in a
    ///     vaguer sentence ("Browsing the web") or a different claim.
    static func acceptedHeadline(base: LiveContext, candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return base.headline }
        guard !base.isTrustworthy else { return base.headline }
        guard base.entities["headlineKind"] != "fallback" else { return base.headline }
        let original = base.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, trimmed.hasPrefix(original), trimmed.count > original.count else {
            return base.headline
        }
        return trimmed
    }

    // MARK: - Presentation helpers

    private static func isBrowserApp(_ name: String) -> Bool {
        let known = ["comet", "safari", "chrome", "firefox", "arc", "brave", "edge",
                     "opera", "vivaldi", "orion", "dia", "zen"]
        let lower = name.lowercased()
        return known.contains { lower.contains($0) }
    }

    /// SF Symbol for the card. Driven by the surface Holmes actually detected,
    /// so the glyph can never contradict the sentence next to it.
    private static func icon(for context: LiveContext) -> String {
        if context.source == .none { return "exclamationmark.triangle" }
        switch ContextSurface(rawValue: context.entities["surface"] ?? "") ?? .unknown {
        case .emailRead, .emailInbox:   return "envelope"
        case .emailCompose:             return "square.and.pencil"
        case .socialPost, .socialFeed:  return "bubble.left.and.bubble.right"
        case .video:                    return "play.rectangle"
        case .githubPR:                 return "arrow.triangle.pull"
        case .githubIssue:              return "exclamationmark.bubble"
        case .githubFile, .githubRepo:  return "arrow.triangle.branch"
        case .directMessage:            return "message"
        case .teamChannel:              return "number"
        case .aiChat:                   return "sparkles"
        case .document:                 return "doc.text"
        case .article:                  return "text.book.closed"
        case .search:                   return "magnifyingglass"
        case .shopping:                 return "cart"
        case .code:                     return "chevron.left.forwardslash.chevron.right"
        case .terminal:                 return "terminal"
        case .unknown:                  return context.confidence == .inferred ? "eye.trianglebadge.exclamationmark" : "rectangle.on.rectangle"
        }
    }

    /// Suggestions follow the detected surface; when the surface is unknown we
    /// fall back to app-name heuristics rather than inventing a specific action.
    private func suggestions(for context: LiveContext, snapshot: ContextSnapshot) -> [ActionSuggestion] {
        switch ContextSurface(rawValue: context.entities["surface"] ?? "") ?? .unknown {
        case .emailRead, .emailInbox:
            return [
                ActionSuggestion(title: "/run  Draft a reply", action: "/run draft reply"),
                ActionSuggestion(title: "/ask  Summarize this email", action: "/ask summarize email"),
                ActionSuggestion(title: "/plan  Plan follow-up tasks", action: "/plan follow up"),
            ]
        case .emailCompose:
            return [
                ActionSuggestion(title: "/ask  Improve my draft", action: "/ask improve draft"),
                ActionSuggestion(title: "/run  Make it shorter", action: "/run shorten email"),
                ActionSuggestion(title: "/ask  Did I miss anything?", action: "/ask review draft"),
            ]
        case .directMessage, .teamChannel:
            return [
                ActionSuggestion(title: "/run  Reply to this message", action: "/run reply imessage"),
                ActionSuggestion(title: "/ask  What should I reply?", action: "/ask suggest imessage reply"),
                ActionSuggestion(title: "/run  Say I'm busy", action: "/run reply busy"),
            ]
        case .githubPR, .githubIssue, .githubFile, .githubRepo:
            return [
                ActionSuggestion(title: "/ask  Brief me on this repo", action: "/ask brief repo"),
                ActionSuggestion(title: "/ask  Explain this change", action: "/ask explain diff"),
                ActionSuggestion(title: "/plan  Plan the review", action: "/plan code review"),
            ]
        case .code, .terminal:
            return [
                ActionSuggestion(title: "/ask  Explain the selected code", action: "/ask explain code"),
                ActionSuggestion(title: "/run  Fix visible errors", action: "/run fix errors"),
                ActionSuggestion(title: "/plan  Plan next feature", action: "/plan feature"),
            ]
        case .article, .document:
            return [
                ActionSuggestion(title: "/ask  Summarize this page", action: "/ask summarize page"),
                ActionSuggestion(title: "/run  Save key info to notes", action: "/run save to notes"),
                ActionSuggestion(title: "/watch  Monitor this page for changes", action: "/watch page"),
            ]
        case .socialPost, .socialFeed, .video, .aiChat, .search, .shopping, .unknown:
            return heuristicSuggestions(for: snapshot)
        }
    }

    // MARK: - Heuristic suggestions (no model, app-name only)

    private func heuristicSuggestions(for snapshot: ContextSnapshot) -> [ActionSuggestion] {
        let app = snapshot.appName.lowercased()

        var actions: [ActionSuggestion] = []

        if app.contains("xcode") || app.contains("cursor") || app.contains("code") {
            actions = [
                ActionSuggestion(title: "/ask  Explain the selected code", action: "/ask explain code"),
                ActionSuggestion(title: "/run  Fix visible errors", action: "/run fix errors"),
                ActionSuggestion(title: "/plan  Plan next feature", action: "/plan feature"),
            ]
        } else if app.contains("safari") || app.contains("chrome") || app.contains("firefox") || app.contains("arc") {
            actions = [
                ActionSuggestion(title: "/ask  Summarize this page", action: "/ask summarize page"),
                ActionSuggestion(title: "/run  Save key info to notes", action: "/run save to notes"),
                ActionSuggestion(title: "/watch  Monitor this page for changes", action: "/watch page"),
            ]
        } else if app.contains("figma") || app.contains("sketch") {
            actions = [
                ActionSuggestion(title: "/run  Export selected assets", action: "/run export assets"),
                ActionSuggestion(title: "/ask  Describe this design", action: "/ask describe design"),
                ActionSuggestion(title: "/plan  Plan design review", action: "/plan design review"),
            ]
        } else if app.contains("finder") {
            actions = [
                ActionSuggestion(title: "/run  Organize files by type", action: "/run organize files"),
                ActionSuggestion(title: "/run  Rename files with date", action: "/run rename files"),
                ActionSuggestion(title: "/watch  Watch for new files", action: "/watch folder"),
            ]
        } else if app == "messages" || app.contains("messages") {
            let hasMeeting = !CalendarEngine.shared.upcomingMeetings.isEmpty
            if hasMeeting {
                actions = [
                    ActionSuggestion(title: "/run  Say I'm busy (meeting soon)", action: "/run reply busy"),
                    ActionSuggestion(title: "/run  Reply to this message", action: "/run reply imessage"),
                    ActionSuggestion(title: "/ask  What should I reply?", action: "/ask suggest imessage reply"),
                ]
            } else {
                actions = [
                    ActionSuggestion(title: "/run  Say I'm free", action: "/run reply free"),
                    ActionSuggestion(title: "/run  Reply to this message", action: "/run reply imessage"),
                    ActionSuggestion(title: "/ask  What should I reply?", action: "/ask suggest imessage reply"),
                ]
            }
        } else if app.contains("mail") || app.contains("outlook") {
            actions = [
                ActionSuggestion(title: "/ask  Summarize this email", action: "/ask summarize email"),
                ActionSuggestion(title: "/run  Draft a reply", action: "/run draft reply"),
                ActionSuggestion(title: "/plan  Plan follow-up tasks", action: "/plan follow up"),
            ]
        } else {
            actions = [
                ActionSuggestion(title: "/ask  What am I looking at?", action: "/ask describe screen"),
                ActionSuggestion(title: "/run  Automate current task", action: "/run automate"),
                ActionSuggestion(title: "/watch  Monitor screen for changes", action: "/watch screen"),
            ]
        }

        return actions
    }

    // MARK: - Activity log

    private func logActivity(context: DetectedContext) {
        logActivity(note: context.description)
    }

    private func logActivity(note: String) {
        // A repeated observation is not a new activity — the perception loop
        // sees one screen many times a minute.
        if recentActivities.first?.description == note { return }

        let item = ActivityItem(
            description: note,
            timeAgo: "just now",
            status: .completed
        )
        recentActivities.insert(item, at: 0)
        if recentActivities.count > 20 {
            recentActivities = Array(recentActivities.prefix(20))
        }

        // Update relative time stamps for older items
        updateTimeAgo()
    }

    private func updateTimeAgo() {
        // Simple: first item is "just now", rest show index-based time
        for (i, _) in recentActivities.enumerated() {
            if i == 0 { continue }
            let mins = i * 1  // approximate
            recentActivities[i] = ActivityItem(
                description: recentActivities[i].description,
                timeAgo: "\(mins)m ago",
                status: recentActivities[i].status
            )
        }
    }

    // MARK: - Meeting context (called by MeetingJoinEngine)

    func showMeetingContext(_ meeting: UpcomingMeeting) {
        let type = meeting.meetingType?.rawValue ?? "Meeting"
        currentContext = DetectedContext(
            icon: meeting.meetingType?.icon ?? "video",
            description: "\(type) \(meeting.timeLabel) — \(meeting.title)",
            appName: meeting.calendarName
        )
        suggestedActions = [
            ActionSuggestion(title: "/run  Join \(type)", action: "/run join meeting"),
            ActionSuggestion(title: "/run  Prepare notes", action: "/run meeting notes for \(meeting.title)"),
            ActionSuggestion(title: "/ask  What's this meeting about?", action: "/ask summarize \(meeting.title)"),
        ]
        hasNewContext = true
        lastUpdated = Date()
        logActivity(context: currentContext)
    }

    // MARK: - Manual trigger (for /watch command etc.)

    func captureNow() {
        ScreenEngine.shared.captureNow()
    }

    func clearBadge() {
        hasNewContext = false
    }
}
