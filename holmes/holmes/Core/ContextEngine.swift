import Foundation
import AppKit
import EventKit

// MARK: - Character emoji helper
private extension Character {
    var isEmoji: Bool {
        unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0x238C } ?? false
    }
}

// MARK: - ContextEngine
// Takes OCR text + active app/window and produces a structured DetectedContext.
// Uses heuristics first (fast, no model needed), then enriches via LLM if available.

extension DetectedContext {
    static let unknown = DetectedContext(
        icon: "questionmark.circle",
        description: "Analyzing your screen...",
        appName: ""
    )
}

struct ContextSnapshot {
    let appName: String
    let windowTitle: String
    let ocrText: String
    let timestamp: Date
}

final class ContextEngine {
    static let shared = ContextEngine()
    private init() {}

    // MARK: - Build context from snapshot + OCR

    func buildContext(from snapshot: ContextSnapshot, meetings: [UpcomingMeeting] = []) -> DetectedContext {
        let app = snapshot.appName
        let title = snapshot.windowTitle
        let text = snapshot.ocrText

        let description = inferDescription(app: app, title: title, text: text, meetings: meetings)
        let icon = iconForScreen(app: app, text: text)

        return DetectedContext(icon: icon, description: description, appName: app)
    }

    // MARK: - Build prompt for LLM (calendar-aware)
    // Callers on @MainActor pass CalendarEngine.shared.upcomingMeetings directly
    // so ContextEngine never touches @MainActor state itself.

    func buildLLMPrompt(from snapshot: ContextSnapshot, meetings: [UpcomingMeeting] = []) -> String {
        let truncated = String(snapshot.ocrText.prefix(1500))
        let calendarContext = buildCalendarContext(meetings: meetings)
        return """
You are Holmes, an AI assistant on macOS. Read this screen content and respond with ONLY a JSON object.

App: \(snapshot.appName)
Window: \(snapshot.windowTitle)
Screen text (OCR):
\(truncated)
\(calendarContext)
Output ONLY this JSON (no markdown, no explanation):
{"summary":"<what user is doing, specific, under 15 words>","actions":["<action1>","<action2>","<action3>"]}

Rules for actions — be SPECIFIC to what's on screen:
- If composing email: suggest filling To/Subject/body, drafting reply
- If reading email: suggest replying, summarizing, archiving
- If on iMessage/Discord/Slack: suggest drafting reply to the specific person visible
- If someone asked about availability: check the calendar context above and suggest a reply
- If coding: suggest explaining, fixing, or improving the visible code
- If browsing: suggest summarizing, saving, or acting on the visible content
Each action must start with /ask, /run, or /plan and be under 8 words.
"""
    }

    /// Builds a calendar status string to inject into LLM prompts.
    /// Takes meetings as a value so this can be called from any actor context.
    func buildCalendarContext(meetings: [UpcomingMeeting]) -> String {
        guard !meetings.isEmpty else {
            return "\nCalendar: Free — no meetings in the next 30 minutes.\n"
        }
        let lines = meetings.prefix(3).map { m -> String in
            let time = Self.timeFormatter.string(from: m.startDate)
            return "  · \(m.title) at \(time) (\(m.timeLabel))"
        }.joined(separator: "\n")
        return "\nCalendar (upcoming meetings):\n\(lines)\n"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - Parse LLM response

    struct LLMContextResponse {
        let summary: String
        let actions: [String]
    }

    func parseLLMResponse(_ raw: String) -> LLMContextResponse? {
        var json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences if model wraps response
        if let start = json.range(of: "{"), let end = json.range(of: "}", options: .backwards) {
            json = String(json[start.lowerBound...end.lowerBound]) + "}"
        }

        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let summary = obj["summary"] as? String ?? ""
        let actions = obj["actions"] as? [String] ?? []
        return LLMContextResponse(summary: summary, actions: actions)
    }

    // MARK: - OCR-first heuristics

    private func inferDescription(app: String, title: String, text: String, meetings: [UpcomingMeeting] = []) -> String {
        let t = text.lowercased()
        let appL = app.lowercased()
        print("[Context] app='\(app)' title='\(title)' emailCompose=\(isEmailCompose(text: t)) emailInbox=\(isEmailInbox(text: t))")

        // ── Email (Gmail, Outlook web, Apple Mail) ──────────────────────────
        if isEmailCompose(text: t) {
            let to = extractField("to", from: text) ?? extractEmailRecipient(from: text)
            let subject = extractField("subject", from: text)
            if let to, let subject {
                return "Composing email to \(to) — \"\(subject)\""
            } else if let to {
                return "Composing email to \(to)"
            } else if let subject {
                return "Composing email — \"\(subject)\""
            }
            return "Composing a new email"
        }

        if isEmailInbox(text: t) {
            if let sender = extractEmailSender(from: text) {
                return "Reading email from \(sender) in \(webServiceName(t) ?? app)"
            }
            return "Reading emails in \(webServiceName(t) ?? app)"
        }

        // ── iMessage ─────────────────────────────────────────────────────────
        if isIMessage(app: app) {
            // Window title for Messages IS the contact name (e.g. "nandan.pericherla@gm...")
            let sender = extractIMessageSender(from: text)
                ?? (title.isEmpty || title.lowercased() == "messages" ? nil : title)
            let lastMsg = extractLastMessage(from: text)
            let availability = lastMsg.map { isAvailabilityQuestion(text: $0) } ?? isAvailabilityQuestion(text: t)
            if let sender {
                if availability {
                    let calCtx = meetings.isEmpty ? "— you're free" : "— you have a meeting soon"
                    return "iMessage with \(sender) — asking about availability \(calCtx)"
                }
                return "iMessage with \(sender)"
            }
            if availability {
                let calCtx = meetings.isEmpty ? "you're free" : "you have a meeting soon"
                return "iMessage — availability question (\(calCtx))"
            }
            return "iMessage conversation"
        }

        // ── Messaging (Discord, Slack, iMessage in browser or app) ──────────
        if isDiscordOrSlack(text: t, app: appL) {
            if let channel = extractChannelOrDM(from: text) {
                return "Chatting in \(channel)"
            }
            return "Using \(webServiceName(t) ?? app)"
        }

        // ── Social / Twitter / Reddit ────────────────────────────────────────
        if t.contains("twitter") || t.contains("x.com") || t.contains("tweet") {
            return "Browsing Twitter/X"
        }
        if t.contains("reddit") || t.contains("r/") {
            let sub = extractRedditSub(from: text)
            return sub != nil ? "Browsing Reddit — \(sub!)" : "Browsing Reddit"
        }

        // ── YouTube ──────────────────────────────────────────────────────────
        if t.contains("youtube") || t.contains("youtu.be") {
            let vidTitle = extractYouTubeTitle(from: text)
            return vidTitle != nil ? "Watching YouTube: \(vidTitle!)" : "Watching YouTube"
        }

        // ── GitHub ───────────────────────────────────────────────────────────
        if t.contains("github.com") || t.contains("pull request") || t.contains("commit") {
            return "Working on GitHub"
        }

        // ── Google Docs / Sheets / Slides ────────────────────────────────────
        if t.contains("docs.google.com") || (t.contains("google") && t.contains("document")) {
            return "Editing Google Doc"
        }
        if t.contains("sheets.google.com") || (t.contains("google") && t.contains("spreadsheet")) {
            return "Working in Google Sheets"
        }

        // ── Notion ───────────────────────────────────────────────────────────
        if t.contains("notion.so") || t.contains("notion.site") || appL.contains("notion") {
            return "Working in Notion\(!title.isEmpty ? " — \(title)" : "")"
        }

        // ── Figma ────────────────────────────────────────────────────────────
        if t.contains("figma.com") || appL.contains("figma") {
            return "Designing in Figma"
        }

        // ── Code editors ─────────────────────────────────────────────────────
        if appL.contains("xcode") {
            let file = title.contains(".swift") ? title : nil
            return file != nil ? "Writing Swift — \(file!)" : "Working in Xcode"
        }
        if appL.contains("cursor") || appL.contains("code") || appL.contains("vscode") {
            return "Coding in \(app)\(!title.isEmpty ? " — \(title)" : "")"
        }

        // ── Terminal ─────────────────────────────────────────────────────────
        if appL.contains("terminal") || appL.contains("iterm") || appL.contains("warp") {
            return "Working in terminal"
        }

        // ── Native Mail / Outlook ────────────────────────────────────────────
        if appL.contains("mail") || appL.contains("outlook") {
            return "Managing email"
        }

        // ── Any browser with a meaningful title ──────────────────────────────
        let isBrowser = appL.contains("safari") || appL.contains("chrome") ||
                        appL.contains("firefox") || appL.contains("arc") ||
                        appL.contains("comet") || appL.contains("opera") ||
                        appL.contains("brave") || appL.contains("edge")
        if isBrowser && !title.isEmpty && title.lowercased() != appL {
            return "Browsing: \(title)"
        }

        // ── Fallback ─────────────────────────────────────────────────────────
        if !title.isEmpty { return "Working on \"\(title)\"" }
        return "Using \(app)"
    }

    // MARK: - Public wrappers for HolmesAgent

    func isEmailComposePublic(text: String) -> Bool { isEmailCompose(text: text) }
    func isEmailInboxPublic(text: String) -> Bool { isEmailInbox(text: text) }
    func isIMessagePublic(app: String) -> Bool { isIMessage(app: app) }
    func isAvailabilityQuestionPublic(text: String) -> Bool { isAvailabilityQuestion(text: text) }
    func extractIMessageSenderPublic(from text: String) -> String? { extractIMessageSender(from: text) }
    func extractLastMessagePublic(from text: String) -> String? { extractLastMessage(from: text) }

    // MARK: - OCR signal detectors

    private func isEmailCompose(text: String) -> Bool {
        // Strong single signals — any one is enough
        let strong = ["new message", "compose email", "new email", "reply to", "forward:"]
        if strong.contains(where: { text.contains($0) }) { return true }
        // Weak signals — need 2
        let weak = ["subject", "to:", "cc:", "bcc:", "send", "press / for", "help me write", "discard draft"]
        return weak.filter { text.contains($0) }.count >= 2
    }

    private func isEmailInbox(text: String) -> Bool {
        let signals = ["inbox", "sent", "drafts", "starred", "unread", "gmail", "outlook", "promotions", "primary", "social"]
        return signals.filter { text.contains($0) }.count >= 2
    }

    private func isDiscordOrSlack(text: String, app: String) -> Bool {
        return app.contains("discord") || app.contains("slack") ||
               text.contains("discord") || text.contains("slack") ||
               text.contains("direct message") || text.contains("# general")
    }

    func isIMessage(app: String) -> Bool {
        let a = app.lowercased()
        return a == "messages" || a.contains("messages")
    }

    /// Detects questions about availability / scheduling in any messaging app.
    func isAvailabilityQuestion(text: String) -> Bool {
        let t = text.lowercased()
        let patterns = [
            "are you free", "you free", "are you busy", "you busy",
            "available", "free tonight", "free tomorrow", "free today",
            "free this week", "free later", "free now",
            "wanna hang", "want to hang", "wanna meet", "want to meet",
            "can we meet", "can you meet", "let's meet", "lets meet",
            "can you talk", "wanna talk", "wanna call", "wanna jump on",
            "you around", "you there", "hop on a call", "jump on a call",
            "do you have time", "have time", "got time", "any time",
            "free for a call", "free to chat", "quick call", "quick chat",
            "catch up", "sync up", "grab coffee", "get lunch", "get dinner"
        ]
        return patterns.contains { t.contains($0) }
    }

    /// Extracts the conversation partner's name from iMessage OCR.
    func extractIMessageSender(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // iMessage layout: conversation name appears near the top, before messages.
        // Also filter out Holmes UI words that leak into OCR when the panel is visible.
        let noise = ["today", "yesterday", "now", "delivered", "read", "send", "imessage",
                     "message", "new message", "sms", "mms", "facetime", "audio", "video",
                     "details", "cancel", "edit", "back", "search", "reactions",
                     // Holmes UI noise — status labels, button text, log headers
                     "holmes", "debug", "ocr", "context", "detected", "suggested",
                     "approve", "customize", "upcoming", "heuristics", "actions",
                     "run", "ask", "plan", "watch", "done", "error", "via", "chars",
                     "complete", "new", "failed", "running", "sending", "drafting",
                     "preview", "dismiss", "join", "skip", "typing", "idle", "ready",
                     "analyzing", "starting", "success", "activity", "recent",
                     "meeting", "executing", "output", "wanted", "act", "send it",
                     "join now", "approve all", "suggested actions", "wants to act"]
        for line in lines.prefix(10) {
            let l = line.lowercased()
            if noise.contains(where: { l == $0 || l.hasPrefix($0 + " ") }) { continue }
            // Skip phone numbers
            if line.contains("+") && line.filter({ $0.isNumber }).count > 7 { continue }
            // Skip email addresses
            if line.contains("@") { continue }
            // Skip lines with "/" (command syntax)
            if line.contains("/") { continue }
            // Must look like a name: 2–40 chars, starts with capital or emoji
            if line.count >= 2 && line.count <= 40 {
                if line.first?.isUppercase == true || line.first?.isEmoji == true {
                    return line
                }
            }
        }
        return nil
    }

    /// Extracts the most recent received message text from the OCR blob.
    func extractLastMessage(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 }
        let noise = ["delivered", "read", "today", "yesterday", "imessage", "send", "reactions",
                     "tapback", "details", "edit", "cancel", "back", "search", "new message"]
        // Return the last substantive line that isn't a UI element
        for line in lines.reversed() {
            let l = line.lowercased()
            if noise.contains(where: { l.contains($0) }) { continue }
            if line.count > 6 && line.count < 300 { return line }
        }
        return nil
    }

    // MARK: - Field extractors

    private func extractField(_ field: String, from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let uiLabels = ["cc", "bcc", "send", "more options", "formatting", "subject", "to", "press /", "help me write", "new message"]
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            // "Subject: foo" on same line
            if lower.hasPrefix(field + ":") || lower.hasPrefix(field + " :") {
                let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && value.count < 120 { return value }
            }
            // "Subject" label alone — Gmail puts the typed text BEFORE the placeholder label
            // Check the line immediately before the label
            if lower == field || lower == field + " " {
                // Look backwards first (Gmail: typed text appears before "Subject" label)
                if i > 0 {
                    let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
                    let prevL = prev.lowercased()
                    if !prev.isEmpty && prev.count > 1 && prev.count < 120 &&
                       !uiLabels.contains(where: { prevL.hasPrefix($0) }) {
                        return prev
                    }
                }
                // Fallback: look forward (some clients put value after label)
                for j in (i + 1)..<min(i + 4, lines.count) {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    let nextL = next.lowercased()
                    if next.isEmpty { continue }
                    if uiLabels.contains(where: { nextL.hasPrefix($0) }) { continue }
                    if next.count < 120 { return next }
                }
            }
        }
        return nil
    }

    /// Pulls the first recipient chip from Gmail compose.
    /// In Gmail, recipient names/chips appear after the "Send" button in OCR order.
    private func extractEmailRecipient(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var pastSend = false
        let noise = ["ask gmail", "compose", "to", "send", "cc", "bcc", "×", "—", "-", "formatting", "more options", "press /", "help me write", "subject"]
        for line in lines {
            let l = line.lowercased()
            if l == "send" || l.hasPrefix("send ") { pastSend = true; continue }
            if pastSend && !line.isEmpty && line.count > 2 && line.count < 60 {
                if noise.contains(where: { l.hasPrefix($0) }) { continue }
                // Skip email addresses shown as chips
                if l.contains("@") { return line }
                // Return first reasonable name
                if line.first?.isLetter == true { return line }
            }
        }
        return nil
    }

    private func extractEmailSender(from text: String) -> String? {
        // Look for "From: Name" pattern
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            if line.lowercased().hasPrefix("from:") {
                let v = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && v.count < 60 { return v }
            }
        }
        return nil
    }

    private func extractChannelOrDM(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") && l.count > 1 && l.count < 40 { return l }
            if l.hasPrefix("@") && l.count > 1 && l.count < 40 { return "DM with \(l)" }
        }
        return nil
    }

    private func extractRedditSub(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            if line.contains("r/") {
                if let range = line.range(of: "r/[A-Za-z0-9_]+", options: .regularExpression) {
                    return String(line[range])
                }
            }
        }
        return nil
    }

    private func extractYouTubeTitle(from text: String) -> String? {
        // The video title is usually the longest non-URL line near the top
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 && $0.count < 100 && !$0.lowercased().contains("youtube") && !$0.contains("http") }
        return lines.first
    }

    private func webServiceName(_ text: String) -> String? {
        if text.contains("gmail") { return "Gmail" }
        if text.contains("outlook") { return "Outlook" }
        if text.contains("discord") { return "Discord" }
        if text.contains("slack") { return "Slack" }
        if text.contains("notion") { return "Notion" }
        if text.contains("github") { return "GitHub" }
        if text.contains("figma") { return "Figma" }
        if text.contains("youtube") { return "YouTube" }
        if text.contains("twitter") || text.contains("x.com") { return "Twitter/X" }
        return nil
    }

    // MARK: - Icon (also OCR-based)

    private func iconForScreen(app: String, text: String) -> String {
        let t = text.lowercased()
        let a = app.lowercased()
        if isEmailCompose(text: t) || isEmailInbox(text: t) { return "envelope" }
        if isIMessage(app: app) { return "message.fill" }
        if isDiscordOrSlack(text: t, app: a) { return "bubble.left.and.bubble.right" }
        if t.contains("youtube") { return "play.rectangle" }
        if t.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if t.contains("figma") || a.contains("figma") { return "paintbrush" }
        if t.contains("notion") || a.contains("notion") { return "doc.text" }
        if a.contains("xcode") || a.contains("cursor") || a.contains("code") { return "chevron.left.forwardslash.chevron.right" }
        if a.contains("terminal") || a.contains("iterm") || a.contains("warp") { return "terminal" }
        if a.contains("finder") { return "folder" }
        if a.contains("music") || t.contains("spotify") { return "music.note" }
        return "globe"
    }
}
