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
        modelBackend = LocalModelEngine.shared.activeBackend.rawValue

        // Browser extension bridge — primary context source
        BrowserBridge.shared.onContext = { [weak self] ctx in
            guard let self else { return }
            Task { @MainActor in
                await self.processBrowserContext(ctx)
            }
        }
        BrowserBridge.shared.start()

        // Screen engine as fallback for non-browser apps
        ScreenEngine.shared.onNewSnapshot = { [weak self] image, appName, windowTitle in
            guard let self else { return }
            Task { @MainActor in
                await self.processSnapshot(image: image, appName: appName, windowTitle: windowTitle)
            }
        }

        await ScreenEngine.shared.start()

        // Calendar engine — monitors upcoming meetings, fires MeetingJoinEngine
        await CalendarEngine.shared.start()

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

        // Proactive proposal for compose
        if ctx.type == "gmail_compose", !isRunningProposal {
            Task {
                await proposeAutomaticAction(snapshot: snapshot, context: currentContext)
            }
        }

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
    private var isRunningProposal = false

    private func processSnapshot(image: CGImage, appName: String, windowTitle: String) async {
        // Skip Holmes itself — only analyze other apps
        guard !appName.lowercased().contains("holmes") else { return }
        guard !isRunningOCR else { return }
        isRunningOCR = true
        defer { isRunningOCR = false }

        isAnalyzing = true
        print("[Holmes] Analyzing — app: \(appName)")

        // 1. Use AX text if available, otherwise OCR the captured image
        let rawText: String
        if let axText = ScreenEngine.shared.latestOCROverride, !axText.isEmpty {
            rawText = axText
            print("[Holmes] AX text (\(axText.count) chars): \(String(axText.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        } else {
            let ocr = await OCREngine.shared.recognize(image: image)
            rawText = ocr.fullText
            print("[Holmes] OCR (\(ocr.fullText.count) chars): \(String(ocr.fullText.prefix(200)).replacingOccurrences(of: "\n", with: " | "))")
        }

        let snapshot = ContextSnapshot(
            appName: appName,
            windowTitle: windowTitle,
            ocrText: rawText,
            timestamp: Date()
        )
        lastOCRText = rawText
        lastSnapshot = snapshot

        // 2. Immediate heuristic context (pass meetings so ContextEngine stays actor-free)
        let meetings = CalendarEngine.shared.upcomingMeetings
        let heuristicContext = ContextEngine.shared.buildContext(from: snapshot, meetings: meetings)
        currentContext = heuristicContext
        lastUpdated = Date()
        isAnalyzing = false

        // 3. LLM enrichment for context + suggestions (non-blocking for proposals)
        if LocalModelEngine.shared.isAvailable {
            let prompt = ContextEngine.shared.buildLLMPrompt(from: snapshot, meetings: CalendarEngine.shared.upcomingMeetings)
            let raw = await LocalModelEngine.shared.generate(prompt: prompt)
            if let parsed = ContextEngine.shared.parseLLMResponse(raw), !parsed.summary.isEmpty {
                currentContext = DetectedContext(
                    icon: heuristicContext.icon,
                    description: parsed.summary,
                    appName: appName
                )
                let newSuggestions = parsed.actions.prefix(3).map {
                    ActionSuggestion(title: $0.trimmingCharacters(in: .whitespaces),
                                     action: $0.trimmingCharacters(in: .whitespaces))
                }
                if !newSuggestions.isEmpty { suggestedActions = Array(newSuggestions) }
            } else {
                suggestedActions = heuristicSuggestions(for: snapshot)
            }
        } else {
            suggestedActions = heuristicSuggestions(for: snapshot)
        }
        hasNewContext = true

        // 4. Proactive action — runs independently, won't block next snapshot
        if !isRunningProposal {
            Task {
                await proposeAutomaticAction(snapshot: snapshot, context: currentContext)
            }
        }

        logActivity(context: currentContext)
        print("[Holmes] Done — \(currentContext.description)")
    }

    // MARK: - Proactive action proposals

    // Throttle: don't re-propose same app+ocr fingerprint within 60s
    private var lastProposedFingerprint: String = ""
    private var lastProposedTime: Date = .distantPast

    private func proposeAutomaticAction(snapshot: ContextSnapshot, context: DetectedContext) async {
        // iMessage availability checks run even without Ollama
        let isIMsg = ContextEngine.shared.isIMessagePublic(app: snapshot.appName)
        let hasAvailQ = isIMsg && ContextEngine.shared.isAvailabilityQuestionPublic(text: snapshot.ocrText)
        guard LocalModelEngine.shared.isAvailable || hasAvailQ else { return }
        guard !isRunningProposal else { return }

        let app = snapshot.appName.lowercased()
        let ocr = snapshot.ocrText.lowercased()
        let isMessaging = app.contains("discord") || app.contains("slack") ||
                          app.contains("messages") || app.contains("mail") || app.contains("outlook")
        let isEmailCompose = ContextEngine.shared.isEmailComposePublic(text: ocr)
        let isEmailInbox = ContextEngine.shared.isEmailInboxPublic(text: ocr)
        let isIMessage = ContextEngine.shared.isIMessagePublic(app: snapshot.appName)
        guard isMessaging || isEmailCompose || isEmailInbox || isIMessage else { return }
        guard !snapshot.ocrText.isEmpty else { return }

        // Throttle — only re-run if we haven't proposed for this app in the last 60s
        let fingerprint = app + String(snapshot.ocrText.prefix(80))
        let elapsed = Date().timeIntervalSince(lastProposedTime)
        guard fingerprint != lastProposedFingerprint || elapsed > 60 else { return }

        isRunningProposal = true
        defer { isRunningProposal = false }

        let ocrLower = snapshot.ocrText.lowercased()
        let emailCompose = ContextEngine.shared.isEmailComposePublic(text: ocrLower)
        let emailInbox   = ContextEngine.shared.isEmailInboxPublic(text: ocrLower)

        if emailCompose {
            if let proposal = await detectEmailDraft(snapshot: snapshot) {
                lastProposedFingerprint = fingerprint
                lastProposedTime = Date()
                ConfirmationBus.shared.propose(proposal)
            }
        } else if emailInbox || snapshot.appName.lowercased().contains("mail") {
            if let proposal = await detectEmailReply(snapshot: snapshot) {
                lastProposedFingerprint = fingerprint
                lastProposedTime = Date()
                ConfirmationBus.shared.propose(proposal)
            }
        } else if isIMessage {
            // Fast path: heuristic availability reply (no LLM needed)
            if ContextEngine.shared.isAvailabilityQuestionPublic(text: snapshot.ocrText),
               let proposal = heuristicAvailabilityReply(snapshot: snapshot) {
                lastProposedFingerprint = fingerprint
                lastProposedTime = Date()
                ConfirmationBus.shared.propose(proposal)
            } else if let proposal = await detectIMessageReply(snapshot: snapshot) {
                lastProposedFingerprint = fingerprint
                lastProposedTime = Date()
                ConfirmationBus.shared.propose(proposal)
            }
        } else {
            // Discord/Slack
            if let proposal = await detectUnreadMessage(snapshot: snapshot) {
                lastProposedFingerprint = fingerprint
                lastProposedTime = Date()
                ConfirmationBus.shared.propose(proposal)
            }
        }
    }

    // MARK: - Email draft (compose window open)

    private func detectEmailDraft(snapshot: ContextSnapshot) async -> PendingAction? {
        let ocr = snapshot.ocrText
        guard !ocr.isEmpty else { return nil }

        let prompt = """
You are Holmes. The user has an email compose window open.

Screen content:
\(String(ocr.prefix(1500)))

Extract what you can see and draft a reply or email body.

Output ONLY:
TO: <recipient name or email if visible, else "unknown">
SUBJECT: <subject if visible, else suggest one>
BODY: <draft email body, professional, under 60 words>

If there is no compose window visible, output: NONE
"""
        let raw = await LocalModelEngine.shared.generate(prompt: prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Holmes] Email draft check: \(trimmed.prefix(120))")
        guard !trimmed.uppercased().hasPrefix("NONE") else { return nil }

        var to = ""
        var subject = ""
        var body = ""

        for line in trimmed.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("TO:") { to = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("SUBJECT:") { subject = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("BODY:") { body = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }

        guard !body.isEmpty else { return nil }

        let title = to.isEmpty ? "Draft email — \(subject)" : "Draft email to \(to)"
        return PendingAction(title: title, preview: body, appName: snapshot.appName, actionType: .typeMessage)
    }

    // MARK: - Email reply (inbox, reading an email)

    private func detectEmailReply(snapshot: ContextSnapshot) async -> PendingAction? {
        let ocr = snapshot.ocrText
        guard !ocr.isEmpty else { return nil }

        let prompt = """
You are Holmes. The user is reading an email in \(snapshot.appName).

Email content:
\(String(ocr.prefix(1200)))

If this email needs a reply, output:
SENDER: <sender name>
REPLY: <suggested reply, under 30 words>

If no reply needed: NONE
"""
        let raw = await LocalModelEngine.shared.generate(prompt: prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.uppercased().hasPrefix("NONE") else { return nil }

        var sender = "sender"
        var reply = ""
        for line in trimmed.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("SENDER:") { sender = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("REPLY:") { reply = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        }
        guard !reply.isEmpty else { return nil }
        return PendingAction(title: "Reply to \(sender)", preview: reply, appName: snapshot.appName, actionType: .typeMessage)
    }

    // MARK: - Heuristic availability reply (instant, no LLM needed)

    private func heuristicAvailabilityReply(snapshot: ContextSnapshot) -> PendingAction? {
        let windowSender = snapshot.windowTitle.isEmpty ? "them" : snapshot.windowTitle
        let sender = ContextEngine.shared.extractIMessageSenderPublic(from: snapshot.ocrText) ?? windowSender
        let meetings = CalendarEngine.shared.upcomingMeetings
        let f = DateFormatter(); f.dateFormat = "h:mm a"

        let reply: String
        if let next = meetings.first {
            let time = f.string(from: next.startDate)
            reply = "No sorry, I have \(next.title) at \(time)"
        } else {
            reply = "Yeah I'm free! What's up?"
        }

        let title = "Reply to \(sender) about availability"
        return PendingAction(title: title, preview: reply, appName: "Messages", actionType: .typeMessage)
    }

    // MARK: - iMessage reply (calendar-aware availability detection)

    private func detectIMessageReply(snapshot: ContextSnapshot) async -> PendingAction? {
        let ocr = snapshot.ocrText
        guard !ocr.isEmpty else { return nil }

        let sender = ContextEngine.shared.extractIMessageSenderPublic(from: ocr) ?? "your contact"
        let lastMessage = ContextEngine.shared.extractLastMessagePublic(from: ocr) ?? ""
        let isAvailabilityQ = ContextEngine.shared.isAvailabilityQuestionPublic(text: lastMessage)
            || ContextEngine.shared.isAvailabilityQuestionPublic(text: ocr)

        // Build calendar status for the prompt
        let calendarStatus: String
        let meetings = CalendarEngine.shared.upcomingMeetings
        if meetings.isEmpty {
            calendarStatus = "Your calendar is clear for the next 30 minutes. You are free."
        } else {
            let items = meetings.prefix(2).map { m -> String in
                let f = DateFormatter()
                f.dateFormat = "h:mm a"
                return "\(m.title) at \(f.string(from: m.startDate)) (\(m.timeLabel))"
            }.joined(separator: ", ")
            calendarStatus = "You have upcoming meetings: \(items). You are NOT free right now."
        }

        let prompt: String
        if isAvailabilityQ {
            prompt = """
You are Holmes. \(sender) just sent a message asking about your availability.

Their message: "\(String(lastMessage.prefix(200)))"

\(calendarStatus)

Write a natural, casual reply (under 20 words) that answers whether you're free or busy.
If busy, mention the meeting name and time.
If free, say yes and invite them to continue.

Output ONLY the reply text. No quotes, no labels.
"""
        } else {
            prompt = """
You are Holmes. You have iMessage open with \(sender).

Screen text:
\(String(ocr.prefix(1000)))

\(calendarStatus)

Is there an unanswered message from \(sender) that needs a reply?
If yes, write a casual reply under 20 words.
If no reply is needed, output: NONE

Output ONLY the reply or NONE.
"""
        }

        let raw = await LocalModelEngine.shared.generate(prompt: prompt)
        let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.uppercased().hasPrefix("NONE"), !reply.isEmpty else { return nil }

        let title = isAvailabilityQ
            ? "Reply to \(sender) about availability"
            : "Reply to \(sender) on iMessage"
        return PendingAction(title: title, preview: reply, appName: "Messages", actionType: .typeMessage)
    }

    // MARK: - Message reply (Discord/Slack)

    private func detectUnreadMessage(snapshot: ContextSnapshot) async -> PendingAction? {
        let ocr = snapshot.ocrText
        guard !ocr.isEmpty else { return nil }

        let prompt = """
You are Holmes. The user has \(snapshot.appName) open.

Screen:
\(String(ocr.prefix(1200)))

Is there an unanswered message visible? Output:
SENDER: <name>
REPLY: <casual reply, under 20 words>

Or: NONE
"""
        let raw = await LocalModelEngine.shared.generate(prompt: prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.uppercased().hasPrefix("NONE") else { return nil }

        var sender = snapshot.appName
        var reply = ""
        for line in trimmed.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("SENDER:") { sender = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("REPLY:") { reply = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        }
        guard !reply.isEmpty else { return nil }
        return PendingAction(title: "Reply to \(sender) on \(snapshot.appName)", preview: reply, appName: snapshot.appName, actionType: .typeMessage)
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
        let item = ActivityItem(
            description: context.description,
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
