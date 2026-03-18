import Foundation
import AppKit

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

    func buildContext(from snapshot: ContextSnapshot) -> DetectedContext {
        let app = snapshot.appName
        let title = snapshot.windowTitle
        let text = snapshot.ocrText

        // OCR-first: detect what's actually on screen regardless of app name
        let description = inferDescription(app: app, title: title, text: text)
        let icon = iconForScreen(app: app, text: text)

        return DetectedContext(icon: icon, description: description, appName: app)
    }

    // MARK: - Build prompt for LLM

    func buildLLMPrompt(from snapshot: ContextSnapshot) -> String {
        let truncated = String(snapshot.ocrText.prefix(1500))
        return """
You are Holmes, an AI assistant on macOS. Read this screen content and respond with ONLY a JSON object.

App: \(snapshot.appName)
Window: \(snapshot.windowTitle)
Screen text (OCR):
\(truncated)

Output ONLY this JSON (no markdown, no explanation):
{"summary":"<what user is doing, specific, under 15 words>","actions":["<action1>","<action2>","<action3>"]}

Rules for actions — be SPECIFIC to what's on screen:
- If composing email: suggest filling To/Subject/body, drafting reply
- If reading email: suggest replying, summarizing, archiving
- If on Discord/Slack: suggest drafting reply to the specific person visible
- If coding: suggest explaining, fixing, or improving the visible code
- If browsing: suggest summarizing, saving, or acting on the visible content
Each action must start with /ask, /run, or /plan and be under 8 words.
"""
    }

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

    private func inferDescription(app: String, title: String, text: String) -> String {
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
