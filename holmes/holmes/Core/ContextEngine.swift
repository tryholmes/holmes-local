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
        let icon = iconForScreen(app: app, text: text, title: title)

        return DetectedContext(icon: icon, description: description, appName: app)
    }

    // MARK: - Instant structured description (focus/selection, no model)

    /// An immediate, precise description built purely from the focused control
    /// and selection — available the instant a capture lands, before the model
    /// runs. Returns nil when focus gives no clearer signal than the heuristic
    /// (so the caller keeps its app/OCR-based line).
    func focusedDescription(app: String, focused: FocusedContext) -> String? {
        let short: (String, Int) -> String = { s, n in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }
        // An active selection is the strongest "what am I focused on" signal.
        let sel = focused.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if sel.count >= 2 {
            return "Selected “\(short(sel, 60))” in \(app)"
        }
        // Editing a labelled field — name the field and show what's in it.
        guard focused.isEditable else { return nil }
        let roleName = focused.roleDescription.isEmpty ? "field" : focused.roleDescription
        let where_ = focused.label.isEmpty ? roleName : "the “\(focused.label)” \(roleName)"
        let val = focused.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if val.isEmpty {
            return "Editing \(where_) in \(app)"
        }
        return "Editing \(where_) in \(app) — “\(short(val, 50))”"
    }

    // MARK: - Deep context (what EXACTLY is the user working on)
    // The heuristic DetectedContext answers "which surface is this" ("Reading
    // email", "Working in Xcode"). LiveContext answers the real question —
    // deterministically, from the DOM or the AX tree — and DeepContext is what
    // survives of the old model-extracted layer: the enrichment HolmesAgent
    // builds behind an already-correct headline (activity + goal + entities),
    // which HolmesBrain uses to ground a run. Nothing here parses model output
    // any more; HolmesAgent constructs it directly from the LiveContext.

    struct DeepContext {
        let activity: String            // coding | math | writing | email | ...
        let summary: String             // one line, under 15 words
        let details: String             // the specifics, quoting screen content
        let entities: [String: String]  // problem, file, error, sender, topic, ...
        let actions: [String]           // /ask //run //plan suggestions
        let app: String
        let windowTitle: String
        let timestamp: Date

        /// Activities that represent real, resumable WORK — the kind worth
        /// remembering and reactivating when a similar task recurs. Idle
        /// surfaces (plain browsing, watching video, an unreadable screen)
        /// are deliberately excluded so memory stays signal, not a screen log.
        private static let workActivities: Set<String> = [
            "coding", "math", "writing", "email", "research", "design",
            "terminal", "meeting", "ai-prompting", "chat"
        ]

        /// Entity keys that IDENTIFY a specific task (vs incidental ones). A
        /// point of interest needs at least one of these, so memory captures
        /// "the nil-crash in LoginView.swift" — not "someone was coding".
        private static let identifyingEntityKeys: Set<String> = [
            "file", "error", "problem", "subject", "sender", "recipient",
            "repo", "topic", "function", "goal", "contact", "url"
        ]

        /// A "point of interest": real work with a concrete, identifying anchor.
        /// The substance bar is deliberately high — the deep-context prompt
        /// always returns 2-4 detail sentences, so a length check alone would
        /// mark essentially every screen as memorable and turn memory into a
        /// per-screen log. Require an identifying entity, or (for entity-light
        /// activities like writing) a genuinely substantial note.
        var isPointOfInterest: Bool {
            guard Self.workActivities.contains(activity) else { return false }
            if entities.keys.contains(where: { Self.identifyingEntityKeys.contains($0) }) {
                return true
            }
            let proseActivities: Set<String> = ["writing", "research", "coding", "email", "design", "math"]
            return proseActivities.contains(activity) && details.count >= 120
        }

        /// The most identifying facts about this task, for memory search /
        /// similarity matching: the entity values plus the summary.
        var searchTerms: String {
            (entities.values + [summary]).joined(separator: " ")
        }
    }


    // MARK: - Context classification (playbooks)
    // Structured counterpart to inferDescription: same heuristics, but returns a
    // typed context + canonical entities so callers can build a PlaybookContext.
    // Canonical entity keys: "sender", "subject", "recipient", "contact",
    // "promptText", "repoOwner", "repoName", "platform", "eventTitle", "eventId".

    enum ContextType: String {
        case emailCompose
        case emailInbox
        case iMessage
        case chat
        case aiPrompting
        case githubRepo
        case linkedIn
        case coding
        case browsing
        case unknown
    }

    struct ClassifiedContext {
        let type: ContextType
        let entities: [String: String]
    }

    /// Classifies a snapshot into a ContextType with canonical entities.
    /// App/title-based signals (AI chat, LinkedIn, GitHub) run first because
    /// they are more specific than OCR keyword counting.
    func classify(snapshot: ContextSnapshot) -> ClassifiedContext {
        let app = snapshot.appName
        let title = snapshot.windowTitle
        let text = snapshot.ocrText
        let t = text.lowercased()
        let appL = app.lowercased()
        let titleL = title.lowercased()
        let onBrowser = isBrowserApp(appL)
        var entities: [String: String] = [:]

        // ── AI prompting (Claude / ChatGPT / Gemini) ─────────────────────
        if let platform = detectAIPlatform(app: app, title: title) {
            entities["platform"] = platform
            if let prompt = extractPromptText(from: text) {
                entities["promptText"] = prompt
            }
            return ClassifiedContext(type: .aiPrompting, entities: entities)
        }

        // ── LinkedIn ─────────────────────────────────────────────────────
        if appL.contains("linkedin") || titleL.contains("linkedin") {
            entities["platform"] = "linkedin"
            return ClassifiedContext(type: .linkedIn, entities: entities)
        }

        // ── GitHub repo ──────────────────────────────────────────────────
        //    Detect from ANY of: "github" in the title, a github.com URL in OCR,
        //    or (on a browser) a cluster of GitHub-only UI words — repo tabs are
        //    often titled just "owner/repo: description" with no "github" anywhere
        //    and OCR frequently misses the address bar, so the visible UI is the
        //    most reliable signal.
        let githubUIHits = ["pull requests", "pull request", "issues", "commits",
                            "branches", "fork", "contributors", "releases",
                            "actions", "insights", "watch", "star"]
            .filter { t.contains($0) }.count
        let looksLikeGitHub = titleL.contains("github")
            || (onBrowser && t.contains("github.com"))
            || (onBrowser && githubUIHits >= 3)
        if looksLikeGitHub {
            // Prefer the "owner/repo" from the tab title; fall back to scanning the
            // OCR for a repo slug so the brief still has a target.
            if let repo = extractGitHubRepo(fromTitle: title)
                ?? extractGitHubRepo(fromTitle: text) {
                entities["repoOwner"] = repo.owner
                entities["repoName"] = repo.name
            }
            return ClassifiedContext(type: .githubRepo, entities: entities)
        }

        // ── Email — only on a genuine email surface (an email client, webmail,
        //    or unambiguous compose UI). This stops terminal/editor text (which
        //    can share generic words like "sent"/"drafts") from reading as email
        //    and prevents a bogus "sender" entity being scraped from code output.
        let emailSurface = isEmailSurface(app: app, title: title, text: text)
        if isEmailCompose(text: t),
           emailSurface || t.contains("compose email") || t.contains("new email") {
            if let to = extractField("to", from: text) ?? extractEmailRecipient(from: text) {
                entities["recipient"] = to
            }
            if let subject = extractField("subject", from: text) {
                entities["subject"] = subject
            }
            return ClassifiedContext(type: .emailCompose, entities: entities)
        }
        if emailSurface, isEmailInbox(text: t) {
            if let sender = extractEmailSender(from: text) {
                entities["sender"] = sender
            }
            if let subject = extractField("subject", from: text) {
                entities["subject"] = subject
            }
            return ClassifiedContext(type: .emailInbox, entities: entities)
        }

        // ── iMessage ─────────────────────────────────────────────────────
        if isIMessage(app: app) {
            let contact = extractIMessageSender(from: text)
                ?? (title.isEmpty || titleL == "messages" ? nil : title)
            if let contact { entities["contact"] = contact }
            return ClassifiedContext(type: .iMessage, entities: entities)
        }

        // ── Discord / Slack ──────────────────────────────────────────────
        if isDiscordOrSlack(text: t, app: appL) {
            entities["platform"] = (appL.contains("discord") || t.contains("discord")) ? "discord" : "slack"
            if let channel = extractChannelOrDM(from: text) {
                entities["contact"] = channel
            }
            return ClassifiedContext(type: .chat, entities: entities)
        }

        // ── Coding / browsing / fallback ─────────────────────────────────
        if appL.contains("xcode") || appL.contains("cursor") ||
           appL.contains("code") || appL.contains("vscode") {
            return ClassifiedContext(type: .coding, entities: entities)
        }
        if onBrowser {
            return ClassifiedContext(type: .browsing, entities: entities)
        }
        return ClassifiedContext(type: .unknown, entities: entities)
    }

    // MARK: - AI-prompting / GitHub / LinkedIn detectors

    /// Returns "claude", "chatgpt", or "gemini" when the frontmost app or
    /// window title indicates an AI chat surface; nil otherwise.
    func detectAIPlatform(app: String, title: String) -> String? {
        let combined = app.lowercased() + " " + title.lowercased()
        if combined.contains("claude") { return "claude" }
        if combined.contains("chatgpt") || combined.contains("openai") { return "chatgpt" }
        if combined.contains("gemini") { return "gemini" }
        return nil
    }

    private func aiPlatformDisplayName(_ platform: String) -> String {
        switch platform {
        case "claude": return "Claude"
        case "chatgpt": return "ChatGPT"
        case "gemini": return "Gemini"
        default: return platform
        }
    }

    /// Best-effort extraction of the user's in-progress prompt from an AI chat
    /// UI. The input box sits at the bottom of the window, so scan trailing OCR
    /// lines and keep the last contiguous block of substantive text, skipping
    /// UI chrome the same way the iMessage extractor does.
    func extractPromptText(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let noise = ["send", "stop", "submit", "new chat", "chatgpt", "claude", "gemini",
                     "regenerate", "copy", "share", "retry", "edit", "model", "upgrade",
                     "settings", "search", "attach", "voice", "canvas", "tools",
                     "temporary", "message chatgpt", "message claude", "reply to claude",
                     "reply to chatgpt", "send a message", "send message", "ask anything",
                     "ask gemini", "how can i help", "what can i help",
                     "how can i help you today", "what are you working on", "free plan",
                     "pro plan", "sonnet", "opus", "haiku", "gpt", "thinking",
                     "deep research", "projects", "skip to content", "connect apps",
                     "use tools", "add content", "claude can make mistakes",
                     "chatgpt can make mistakes", "double-check responses",
                     // Holmes UI noise — panel text that leaks into OCR
                     "holmes", "debug", "ocr", "context", "detected", "suggested",
                     "approve", "dismiss", "customize", "actions", "run", "ask", "plan"]

        // Walk upward from the bottom of the screen; collect the first
        // contiguous block of non-chrome lines (that's the input area).
        var collected: [String] = []
        let trailingChrome = CharacterSet(charactersIn: " .…")
        for line in lines.reversed() {
            // Strip trailing spaces/periods/ellipsis so an empty-composer
            // placeholder rendered as "Reply to Claude…" still matches the
            // "reply to claude" chrome term and isn't returned as a fake prompt.
            let l = line.lowercased().trimmingCharacters(in: trailingChrome)
            // A line is chrome when it EXACTLY equals a noise term (a button /
            // placeholder label), or when it starts with a MULTI-WORD chrome
            // phrase ("message chatgpt", "reply to claude", "how can i help").
            // Single-word terms are only trusted as exact matches — otherwise a
            // short real prompt like "run my tests" or "edit this draft" would be
            // dropped just because it starts with "run"/"edit". This is what made
            // brief in-progress prompts vanish before they could be coached.
            let isNoise = noise.contains { term in
                if l == term { return true }
                return term.contains(" ") && l.hasPrefix(term + " ")
            }
                || l.contains("http")
                || line.count < 4
            if isNoise {
                if collected.isEmpty { continue }   // still below the input block
                break                               // hit chrome above the block
            }
            collected.append(line)
            if collected.count >= 5 { break }
        }
        guard !collected.isEmpty else { return nil }
        let prompt = collected.reversed().joined(separator: " ")
        // Keep short prompts: an in-progress question like "how to make a car?"
        // (18 chars) must survive so Prompt Coach can improve it. Only drop
        // fragments too small to be a real instruction.
        guard prompt.count >= 8 else { return nil }
        return String(prompt.prefix(400))
    }

    /// Parses "owner/repo" from a browser window title following GitHub's title
    /// convention (e.g. "GitHub - owner/repo: description" or "owner/repo · …").
    /// Callers gate on a GitHub signal (title or OCR URL) before trusting this.
    func extractGitHubRepo(fromTitle title: String) -> (owner: String, name: String)? {
        var t = title
        // Drop a leading "GitHub - " / "GitHub · " prefix so the anchor lands
        // on the owner segment.
        if let prefix = t.range(of: "^\\s*github\\s*[-–—:·]\\s*",
                                options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(prefix)
        }
        let pattern = "^\\s*([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?=[\\s:·–—-]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = t as NSString
        guard let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3 else { return nil }
        let owner = ns.substring(with: match.range(at: 1))
        let name = ns.substring(with: match.range(at: 2))
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return (owner: owner, name: name)
    }

    // MARK: - OCR-first heuristics

    private func inferDescription(app: String, title: String, text: String, meetings: [UpcomingMeeting] = []) -> String {
        let t = text.lowercased()
        let appL = app.lowercased()
        let titleL = title.lowercased()
        let onBrowser = isBrowserApp(appL)
        let emailSurface = isEmailSurface(app: app, title: title, text: text)
        print("[Context] app='\(app)' title='\(title)' emailSurface=\(emailSurface) emailCompose=\(isEmailCompose(text: t)) emailInbox=\(isEmailInbox(text: t))")

        // ── Explicit app/surface signals FIRST ───────────────────────────────
        //    AI chat / LinkedIn / GitHub are far more specific than the OCR
        //    keyword guesses below. Checking them first keeps a GitHub repo page
        //    from being mislabeled "Watching YouTube" (a stray "youtube" in the
        //    README) and keeps an AI chat from reading as email just because
        //    "reply to Claude…" appears in the composer.

        // ── AI prompting (Claude / ChatGPT / Gemini) ─────────────────────────
        if let platform = detectAIPlatform(app: app, title: title) {
            let name = aiPlatformDisplayName(platform)
            if let prompt = extractPromptText(from: text) {
                let short = prompt.count > 60 ? String(prompt.prefix(60)) + "…" : prompt
                return "Prompting \(name) — \"\(short)\""
            }
            return "Prompting \(name)"
        }

        // ── LinkedIn ─────────────────────────────────────────────────────────
        if appL.contains("linkedin") || titleL.contains("linkedin") {
            return "Browsing LinkedIn"
        }

        // ── GitHub (title/URL signal — wins over generic video/keyword guesses)
        //    Only a "github" window title or, in a browser, a github.com URL
        //    counts; bare "commit"/"pull request" no longer trigger this (they
        //    appear in editors too). If github.com shows up without a repo-shaped
        //    title (e.g. a link on another page), fall through rather than lie.
        if titleL.contains("github") || (onBrowser && t.contains("github.com")) {
            if let repo = extractGitHubRepo(fromTitle: title) {
                return "Working on GitHub — \(repo.owner)/\(repo.name)"
            }
            if titleL.contains("github") { return "Working on GitHub" }
        }

        // ── Email — only on a genuine email surface (Gmail, Outlook web, Apple
        //    Mail, …). Gating on the surface stops terminal/editor text from
        //    reading as "Composing/Reading email".
        if emailSurface, isEmailCompose(text: t) {
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

        if emailSurface, isEmailInbox(text: t) {
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

        // ── YouTube (require a real YouTube URL or title, not a bare keyword) ─
        //    "youtube" alone appears in README links, comments, and article text;
        //    demand youtube.com / youtu.be / a "youtube" title so a GitHub or
        //    docs page can't be mislabeled "Watching YouTube".
        if titleL.contains("youtube") || t.contains("youtube.com") || t.contains("youtu.be") {
            let vidTitle = extractYouTubeTitle(from: text)
            return vidTitle != nil ? "Watching YouTube: \(vidTitle!)" : "Watching YouTube"
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
        if onBrowser && !title.isEmpty && titleL != appL {
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
        // Brand/webmail words are strong: one, plus any mailbox-nav word, is an
        // inbox. Generic nav words ("sent"/"drafts"/"primary") appear in
        // terminals and editors too, so with NO brand word demand a thicker
        // cluster before calling it an inbox.
        let brand = ["gmail", "outlook", "mail.google.com", "proton mail", "protonmail", "yahoo mail"]
        let nav = ["inbox", "sent", "drafts", "starred", "archive", "snooze",
                   "promotions", "primary", "spam", "compose", "unread"]
        let hasBrand = brand.contains { text.contains($0) }
        let navCount = nav.filter { text.contains($0) }.count
        if hasBrand && navCount >= 1 { return true }
        return navCount >= 3
    }

    /// True when the frontmost app is a web browser (used to gate URL-in-OCR
    /// signals like github.com so a code editor showing that URL in a comment
    /// isn't mistaken for the page itself).
    private func isBrowserApp(_ appL: String) -> Bool {
        return appL.contains("safari") || appL.contains("chrome") ||
               appL.contains("firefox") || appL.contains("arc") ||
               appL.contains("comet") || appL.contains("opera") ||
               appL.contains("brave") || appL.contains("edge") ||
               appL.contains("vivaldi") || appL.contains("orion")
    }

    /// True when the surface is genuinely an email client or webmail. Email
    /// classification is gated on this so terminal/editor text (which can share
    /// generic words like "sent"/"drafts") never reads as an email — and no
    /// "sender" entity is ever scraped from arbitrary code/terminal output.
    private func isEmailSurface(app: String, title: String, text: String) -> Bool {
        let a = app.lowercased()
        let ti = title.lowercased()
        let tx = text.lowercased()
        // Native email clients (none of these substrings occur in terminal/editor
        // app names like Terminal, iTerm, Warp, Ghostty, Xcode, Cursor, Code).
        let emailApps = ["mail", "outlook", "spark", "airmail", "thunderbird",
                         "mimestream", "canary", "superhuman", "postbox", "mailmate"]
        if emailApps.contains(where: { a.contains($0) }) { return true }
        // Webmail identified by URL/brand in the title or OCR.
        let webmail = ["mail.google.com", "gmail", "outlook.office", "outlook.live",
                       "mail.yahoo", "proton.me/mail", "protonmail", "fastmail.com"]
        return webmail.contains { ti.contains($0) || tx.contains($0) }
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

    private func iconForScreen(app: String, text: String, title: String = "") -> String {
        let t = text.lowercased()
        let a = app.lowercased()
        let ti = title.lowercased()
        let onBrowser = isBrowserApp(a)
        // Same gates as inferDescription so icon and description can't disagree.
        // Envelope only on a genuine email surface (not bare "reply to"/"sent" in
        // terminal/editor text); YouTube/GitHub require a real URL or window
        // title, not a stray keyword in the OCR body — so a GitHub repo page whose
        // README mentions "youtube" no longer shows the play icon.
        if isEmailSurface(app: app, title: title, text: text),
           isEmailCompose(text: t) || isEmailInbox(text: t) { return "envelope" }
        if isIMessage(app: app) { return "message.fill" }
        if isDiscordOrSlack(text: t, app: a) { return "bubble.left.and.bubble.right" }
        if detectAIPlatform(app: app, title: title) != nil { return "sparkles" }
        if a.contains("linkedin") || ti.contains("linkedin") { return "person.crop.square" }
        // YouTube only when the window TITLE says so (real watching puts "- YouTube"
        // in the title) — never on a stray youtube.com link in another page's body,
        // so a GitHub repo whose README links a video keeps the code icon.
        if ti.contains("youtube") { return "play.rectangle" }
        if ti.contains("github") || (onBrowser && t.contains("github.com")) { return "chevron.left.forwardslash.chevron.right" }
        if t.contains("figma") || a.contains("figma") { return "paintbrush" }
        if t.contains("notion") || a.contains("notion") { return "doc.text" }
        if a.contains("xcode") || a.contains("cursor") || a.contains("code") { return "chevron.left.forwardslash.chevron.right" }
        if a.contains("terminal") || a.contains("iterm") || a.contains("warp") { return "terminal" }
        if a.contains("finder") { return "folder" }
        if a.contains("music") || t.contains("spotify") { return "music.note" }
        return "globe"
    }
}
