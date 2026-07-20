import Foundation
import SwiftUI
import Observation

// MARK: - HolmesAgent
// The brain of Holmes. Orchestrates: ScreenEngine → OCREngine → ContextEngine → LocalModelEngine
// Publishes live state consumed by MainPanelView, ContextCard, ActionSuggestions.

@Observable
@MainActor
final class HolmesAgent {
    static let shared = HolmesAgent()

    // ── Published state ─────────────────────────────
    var currentContext: DetectedContext = .unknown
    /// Deep understanding of EXACTLY what the user is working on (the specific
    /// problem/code/email), extracted by the local model and logged to memory.
    var deepContext: ContextEngine.DeepContext? = nil
    /// Past points of interest that match the CURRENT task — reactivated
    /// memory the agent can draw on when a similar task recurs. Empty unless
    /// the current screen is a point of interest with prior matches.
    var relatedMemories: [MemoryEvent] = []
    var suggestedActions: [ActionSuggestion] = []
    var recentActivities: [ActivityItem] = []
    var isAnalyzing: Bool = false
    var hasNewContext: Bool = false
    var modelBackend: String = "Starting..."
    var lastUpdated: Date? = nil

    // Last raw OCR — used by CommandViewModel for real action prompts
    private(set) var lastOCRText: String = ""
    private(set) var lastSnapshot: ContextSnapshot? = nil

    private init() {}

    // MARK: - Start

    func start() async {
        // Probe local model
        await LocalModelEngine.shared.probe()
        modelBackend = LocalModelEngine.shared.backendLabel

        // Browser extension bridge — primary context source
        BrowserBridge.shared.onContext = { [weak self] ctx in
            guard let self else { return }
            Task { @MainActor in
                await self.processBrowserContext(ctx)
            }
        }
        BrowserBridge.shared.start()

        // Screen engine as fallback for non-browser apps
        ScreenEngine.shared.onNewSnapshot = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                await self.processSnapshot(result)
            }
        }

        await ScreenEngine.shared.start()

        // Calendar engine — monitors upcoming meetings, fires MeetingJoinEngine
        await CalendarEngine.shared.start()

        // Agentic action brain — connects MCP servers in the background. Only used
        // when an Anthropic API key is configured (Hybrid mode).
        HolmesBrain.shared.start()

        // Proactive playbooks — draft-only automations evaluated on every context tick.
        PlaybookEngine.shared.start()

        // Autopilot — time-based scheduler (morning brief, email triage, meeting prep).
        Autopilot.shared.start()

        // MCP *server* — exposes Holmes's live screen context to other agents
        // (Claude Desktop, Cursor, voice agents) on http://127.0.0.1:5767/mcp.
        // OPT-IN (default off): the endpoint has no auth and would relay
        // TCC-gated screen content to any local process, so it only starts when
        // the user enabled it in Settings > Privacy.
        if MCPServer.isEnabledByUser {
            MCPServer.shared.start()
        }

        print("[Holmes] Agent started — backend: \(modelBackend)")
    }

    func stop() {
        ScreenEngine.shared.stop()
    }

    // MARK: - Browser extension context (fast path — no OCR needed)

    private func processBrowserContext(_ ctx: BrowserContext) async {
        let snapshot = ContextSnapshot(
            appName: "Comet",
            windowTitle: ctx.subject.isEmpty ? ctx.title : ctx.subject,
            ocrText: ctx.ocrText,
            timestamp: Date()
        )
        lastOCRText = ctx.ocrText
        lastSnapshot = snapshot
        lastBrowserContextAt = Date()

        // Immediate context from browser data — 100% accurate
        currentContext = DetectedContext(
            icon: "envelope",
            description: ctx.appDescription,
            appName: "Comet"
        )
        lastUpdated = Date()
        hasNewContext = true

        // LLM suggestions
        if LocalModelEngine.shared.isAvailable {
            suggestedActions = browserSuggestions(for: ctx)
        }

        // Proactive playbooks — evaluate against the fresh browser context
        evaluatePlaybooks(snapshot: snapshot)

        // Deep context + memory from the extension's clean (non-OCR) text too.
        // Proactive drafting (email/chat replies) is owned entirely by the
        // playbook system now — the local model's autonomous job here is
        // purely understanding context, not generating drafts. No screenshot on
        // this path (the extension gives clean DOM text), so it stays text-only.
        enrichDeepContext(snapshot: snapshot, heuristicIcon: "envelope", image: nil, focused: nil)

        logActivity(context: currentContext)
        print("[Holmes] Browser ctx: \(ctx.appDescription)")
    }

    private func browserSuggestions(for ctx: BrowserContext) -> [ActionSuggestion] {
        switch ctx.type {
        case "gmail_compose":
            return [
                ActionSuggestion(title: "/run  Draft email body", action: "/run draft email"),
                ActionSuggestion(title: "/ask  Improve my draft", action: "/ask improve draft"),
                ActionSuggestion(title: "/run  Make it shorter", action: "/run shorten email"),
            ]
        case "gmail_read":
            return [
                ActionSuggestion(title: "/run  Draft a reply", action: "/run draft reply"),
                ActionSuggestion(title: "/ask  Summarize this email", action: "/ask summarize email"),
                ActionSuggestion(title: "/run  Forward with note", action: "/run forward email"),
            ]
        default:
            return [
                ActionSuggestion(title: "/ask  What am I looking at?", action: "/ask describe screen"),
                ActionSuggestion(title: "/run  Automate current task", action: "/run automate"),
                ActionSuggestion(title: "/watch  Monitor screen for changes", action: "/watch screen"),
            ]
        }
    }

    // MARK: - Process snapshot

    private var isRunningOCR = false
    // When the browser extension last delivered context (see processSnapshot's
    // playbook-evaluation gate).
    private var lastBrowserContextAt: Date = .distantPast
    // The real screenshot tied to the latest OCR/AX snapshot — fed to the
    // vision model during enrichment (nil = no real pixels, e.g. the browser
    // extension path or a failed capture).
    private var lastCapturedImage: CGImage? = nil

    private func processSnapshot(_ result: CaptureResult) async {
        let appName = result.appName
        let windowTitle = result.windowTitle
        // Skip Holmes itself — only analyze other apps
        guard !appName.lowercased().contains("holmes") else { return }
        guard !isRunningOCR else { return }
        isRunningOCR = true
        defer { isRunningOCR = false }

        isAnalyzing = true
        print("[Holmes] Analyzing — app: \(appName)")

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

        // 1. Use AX text if available, otherwise OCR the captured image. Both the
        //    text and the image come from THIS capture (the CaptureResult), never
        //    re-read from shared state after a suspension — so app/text/image/focus
        //    can't belong to different screens during an app switch.
        let rawText: String
        if let axText = result.axOverride, !axText.isEmpty {
            rawText = axText
            print("[Holmes] AX text (\(axText.count) chars): \(String(axText.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        } else if let image = result.image {
            let ocr = await OCREngine.shared.recognize(image: image)
            rawText = ocr.fullText
            print("[Holmes] OCR (\(ocr.fullText.count) chars): \(String(ocr.fullText.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        } else {
            rawText = ""
        }

        let snapshot = ContextSnapshot(
            appName: appName,
            windowTitle: windowTitle,
            ocrText: rawText,
            timestamp: Date()
        )
        lastOCRText = rawText
        lastSnapshot = snapshot
        // Keep the real screenshot for vision only when it's usable (non-blank).
        lastCapturedImage = result.visionUsable ? result.image : nil

        // 2. Immediate heuristic context (pass meetings so ContextEngine stays actor-free)
        let focused = result.focused
        let meetings = CalendarEngine.shared.upcomingMeetings
        let heuristicContext = ContextEngine.shared.buildContext(from: snapshot, meetings: meetings)
        // Stale-while-revalidate: the deep context stays on the card as long
        // as it describes THIS screen (fingerprint match) — the enrichment TTL
        // only decides when to refresh it in the background, so the card never
        // flickers back to the generic heuristic line on a static screen.
        let fingerprint = snapshotFingerprint(snapshot)
        let deepIsCurrent = deepContext != nil && lastEnrichFingerprint == fingerprint
        if deepIsCurrent, let deep = deepContext {
            currentContext = DetectedContext(icon: heuristicContext.icon,
                                             description: deep.summary,
                                             appName: appName)
        } else if let focused,
                  let line = ContextEngine.shared.focusedDescription(app: appName, focused: focused) {
            // Instant structured layer: the focused control + selection give a
            // precise "what am I doing" line the moment the capture lands —
            // before the (slower) vision model runs — so the card is specific
            // immediately instead of showing a generic app/keyword guess.
            currentContext = DetectedContext(icon: heuristicContext.icon,
                                             description: line, appName: appName)
        } else {
            currentContext = heuristicContext
        }
        lastUpdated = Date()
        isAnalyzing = false

        // Always evaluate proactive playbooks against the freshest OCR context.
        // (The old "browser extension owns evaluation" skip suppressed EVERY auto
        // playbook on Comet whenever the extension had posted recently — email /
        // GitHub / Claude auto-actions silently never fired. The debounce now keys
        // on the stable window title, so two context sources can't break it, and
        // per-context cooldowns stop any double-draft.)
        evaluatePlaybooks(snapshot: snapshot)

        // 3. Suggestions: the current screen's deep actions when we have them
        //    (also restores them when the user RETURNS to a recently-enriched
        //    screen), otherwise instant heuristics.
        if deepIsCurrent, let deep = deepContext, !deep.actions.isEmpty {
            suggestedActions = deep.actions.prefix(3).map { ActionSuggestion(title: $0, action: $0) }
        } else {
            suggestedActions = heuristicSuggestions(for: snapshot)
        }
        hasNewContext = true

        // 3b. Deep-context enrichment — single-flight and gated on the screen
        //     actually changing, so Ollama isn't re-asked about an unchanged
        //     screen every 3s and the perception loop never blocks on the model.
        //     This is the local model's ONE autonomous job: understand exactly
        //     what the user is doing. Proactive drafting is the playbook
        //     system's responsibility, not a second local-model path here.
        enrichDeepContext(snapshot: snapshot, heuristicIcon: heuristicContext.icon,
                          image: lastCapturedImage, focused: focused)

        logActivity(context: currentContext)
        print("[Holmes] Done — \(currentContext.description)")
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

    // MARK: - Deep-context enrichment (what EXACTLY the user is working on)

    private var isRunningEnrichment = false
    private var lastEnrichFingerprint = ""
    private var lastEnrichedAt: Date = .distantPast
    private var lastEnrichStartedAt: Date = .distantPast
    private var lastEnrichFailure: (fingerprint: String, at: Date)? = nil
    /// IDs of the last reactivated memory set we announced — dedupes the
    /// "Recalled N…" activity note across re-enrichments of the same screen.
    private var lastReactivationSignature = ""
    /// How long before an unchanged screen's deep context is REFRESHED in the
    /// background (the old one keeps displaying meanwhile — see deepIsCurrent).
    private static let deepContextTTL: TimeInterval = 90
    /// Backoff after a failed/unparseable extraction for the same screen.
    private static let enrichFailureBackoff: TimeInterval = 25
    /// Floor between enrichments of the SAME app/window — OCR jitter minting
    /// fresh fingerprints for one screen must never hammer Ollama per-tick.
    private static let sameScreenEnrichFloor: TimeInterval = 10
    /// When vision was last used — a churning visual screen must not run the
    /// expensive (~16s) vision pass back-to-back.
    private var lastVisionAt: Date = .distantPast
    private static let visionMinInterval: TimeInterval = 40

    /// Encodes a screenshot for the vision model OFF the main actor — the
    /// downscale + JPEG encode is tens of milliseconds and must not jank the UI.
    private func encodeForVisionOffMain(_ image: CGImage) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: LocalModelEngine.encodeForVision(image))
            }
        }
    }

    /// Deep context only when it describes the screen the user is on RIGHT
    /// NOW. Prompt-building consumers (HolmesBrain) must use this, never raw
    /// deepContext — a stale "working on X" from a previous screen would
    /// misground every run until the next successful enrichment.
    var currentDeepContext: ContextEngine.DeepContext? {
        guard let deep = deepContext, let snap = lastSnapshot,
              snapshotFingerprint(snap) == lastEnrichFingerprint else { return nil }
        return deep
    }

    /// Stable identity of "the screen the user is on": app + window + head and
    /// middle of the extracted text plus a bucketed length. Normalized so OCR
    /// whitespace jitter doesn't mint fresh fingerprints; the middle slice and
    /// length catch content changes under stable window chrome (scrolling a
    /// doc, switching messages in a list pane).
    private func snapshotFingerprint(_ snapshot: ContextSnapshot) -> String {
        let norm = snapshot.ocrText.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        let head = norm.prefix(160)
        let mid = norm.dropFirst(max(0, (norm.count - 160) / 2)).prefix(160)
        return "\(snapshot.appName)|\(snapshot.windowTitle)|\(head)|\(mid)|\(norm.count / 80)"
    }

    /// Runs the local model ONCE per changed screen to produce the DeepContext:
    /// activity kind, one-line summary, a detailed quote-the-specifics overview,
    /// entities, and screen-specific suggestions. Non-blocking (the perception
    /// loop never waits on it), single-flight, and applied only if the user is
    /// still on the same screen when the model answers. Every meaningful change
    /// is persisted to MemoryStore.
    private func enrichDeepContext(snapshot: ContextSnapshot, heuristicIcon: String,
                                   image: CGImage?, focused: FocusedContext?) {
        guard LocalModelEngine.shared.isAvailable else { return }
        guard !isRunningEnrichment else { return }
        let fingerprint = snapshotFingerprint(snapshot)
        if fingerprint == lastEnrichFingerprint,
           Date().timeIntervalSince(lastEnrichedAt) < Self.deepContextTTL { return }
        // Backoff: a screen whose extraction just failed isn't retried per-tick.
        if let failure = lastEnrichFailure, failure.fingerprint == fingerprint,
           Date().timeIntervalSince(failure.at) < Self.enrichFailureBackoff { return }
        // Same-screen floor: text churn on one app/window (live typing, OCR
        // jitter) re-enriches at most every few seconds; a NEW screen is
        // enriched immediately.
        let screenPart = snapshot.appName + "|" + snapshot.windowTitle
        let lastScreenPart = lastEnrichFingerprint
            .components(separatedBy: "|").prefix(2).joined(separator: "|")
        if screenPart == lastScreenPart,
           Date().timeIntervalSince(lastEnrichStartedAt) < Self.sameScreenEnrichFloor { return }
        lastEnrichStartedAt = Date()
        isRunningEnrichment = true

        // Adaptive vision: escalate to the screenshot exactly where text falls
        // short — a sparse OCR/AX read (Electron, canvas, an image-only screen)
        // or an inherently visual app (design/video tools). On text-rich screens
        // (code, email, docs) the text+AX+focus pass is both FASTER (~5s vs ~16s)
        // and more accurate, so vision there would only slow things down. This
        // is "full access" applied where it helps, not blindly.
        let textIsSparse = snapshot.ocrText.count < 220
        let visualApp = ["figma", "sketch", "photoshop", "illustrator", "preview",
                         "quicktime", "photos", "canva", "blender", "final cut",
                         "davinci", "affinity", "pixelmator"]
            .contains { snapshot.appName.lowercased().contains($0) }
        // Rate-limit the expensive (~16s) vision pass: on a churning visual screen
        // fall back to the fast text pass rather than running vision back-to-back.
        let visionCooledDown = Date().timeIntervalSince(lastVisionAt) > Self.visionMinInterval
        let wantVision = LocalModelEngine.shared.visionAvailable
            && (textIsSparse || visualApp) && visionCooledDown

        Task { @MainActor in
            defer { isRunningEnrichment = false }
            // FULL access: hand the vision model the actual screenshot so it
            // reads layout, UI state, images, and charts — not just OCR text. On
            // the fast native path captureNow() skips the screenshot, so grab one
            // on demand here (only when vision is actually wanted).
            var images: [String] = []
            if wantVision {
                let visionImage: CGImage?
                if let image {
                    visionImage = image
                } else {
                    visionImage = await ScreenEngine.shared.grabScreenshotForVision()
                }
                if let visionImage, let b64 = await self.encodeForVisionOffMain(visionImage) {
                    images = [b64]
                    lastVisionAt = Date()
                }
            }
            let prompt = ContextEngine.shared.buildDeepContextPrompt(
                from: snapshot, meetings: CalendarEngine.shared.upcomingMeetings,
                focused: focused, hasImage: !images.isEmpty)
            var raw = await LocalModelEngine.shared.generate(
                prompt: prompt, maxTokens: 600, asJSON: true, images: images)
            if !images.isEmpty {
                print("[Holmes] Deep context: used VISION (\(snapshot.appName), OCR \(snapshot.ocrText.count) chars)")
                // Defensive: if a vision call comes back empty (e.g. the model was
                // mis-detected as vision-capable), retry once text-only so a
                // screen never silently loses its deep context.
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let textPrompt = ContextEngine.shared.buildDeepContextPrompt(
                        from: snapshot, meetings: CalendarEngine.shared.upcomingMeetings,
                        focused: focused, hasImage: false)
                    raw = await LocalModelEngine.shared.generate(
                        prompt: textPrompt, maxTokens: 600, asJSON: true)
                }
            }
            guard let deep = ContextEngine.shared.parseDeepContext(raw, snapshot: snapshot) else {
                print("[Holmes] Deep context: unparseable model reply — backing off \(Int(Self.enrichFailureBackoff))s")
                lastEnrichFailure = (fingerprint, Date())
                return
            }
            lastEnrichFailure = nil
            lastEnrichFingerprint = fingerprint
            lastEnrichedAt = Date()
            deepContext = deep
            // Clear reactivations synchronously the moment a new deep context
            // is current, so a run/playbook that builds its prompt in the gap
            // before findSimilar returns never pairs THIS task with the PREVIOUS
            // task's related memories. The POI branch repopulates it below.
            relatedMemories = []
            print("[Holmes] Deep context [\(deep.activity)] \(deep.summary) — \(String(deep.details.prefix(120)))")

            // Point-of-interest memory + reactivation. Idle screens (plain
            // browsing, video) aren't worth remembering; only real work is. For
            // a point of interest, FIRST pull up similar past work — so when a
            // task the user has done before comes back around, that memory is
            // reactivated and made available to the agent — THEN record this one.
            if deep.isPointOfInterest {
                let activity = deep.activity
                let terms = deep.searchTerms
                let summary = deep.summary
                Task { @MainActor in
                    let similar = await MemoryStore.shared.findSimilar(
                        activity: activity, terms: terms, excludingSummary: summary)
                    // Surface reactivations only while the user is still on the
                    // screen that triggered them.
                    if let cur = self.lastSnapshot, self.snapshotFingerprint(cur) == fingerprint {
                        self.relatedMemories = similar
                        // Only announce a reactivation when the matched set
                        // actually changed — re-enrichment of a dwelt screen
                        // finds the same rows every ~90s and must not spam the feed.
                        let signature = similar.map { String($0.id) }.joined(separator: ",")
                        if !similar.isEmpty, signature != self.lastReactivationSignature {
                            self.lastReactivationSignature = signature
                            self.logActivity(note: "Recalled \(similar.count) related note\(similar.count == 1 ? "" : "s") on \(activity)")
                            print("[Holmes] Memory reactivated — \(similar.count) prior \(activity) note(s) for: \(summary)")
                        }
                    }
                    await MemoryStore.shared.recordContext(
                        activity: activity, summary: summary,
                        details: deep.details, app: deep.app, windowTitle: deep.windowTitle)
                }
            } else {
                lastReactivationSignature = ""
            }

            // Apply to the visible card only if the user is still on this
            // screen — they may have moved on while the model was thinking.
            guard let current = lastSnapshot, snapshotFingerprint(current) == fingerprint else { return }
            currentContext = DetectedContext(icon: heuristicIcon,
                                             description: deep.summary,
                                             appName: snapshot.appName)
            lastUpdated = Date()
            if !deep.actions.isEmpty {
                suggestedActions = deep.actions.prefix(3).map {
                    ActionSuggestion(title: $0, action: $0)
                }
            }
            hasNewContext = true
        }
    }

    // MARK: - Heuristic suggestions (no LLM)

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
