import Foundation
import AppKit
import ApplicationServices

// MARK: - MessagesReader
// Reads the conversation the user is looking at in the native Messages app,
// through the Accessibility API only.
//
// Why AX and nothing else:
//   • chat.db (~/Library/Messages/chat.db) is SIP-protected, requires Full Disk
//     Access, and would hand Holmes the user's ENTIRE message history — a
//     privacy overreach for a feature that only needs the thread on screen.
//   • AppleScript against Messages needs the Automation permission and, since
//     Big Sur, exposes almost nothing of the transcript anyway.
//   • AX reads exactly what is already rendered — the same bytes the user is
//     looking at, nothing more, and it uses the Accessibility permission Holmes
//     already holds.
//
// Everything below is a HEURISTIC over a private, undocumented view hierarchy.
// Messages' AX tree changes between macOS releases, so every step is written to
// FAIL CLOSED: if the shape doesn't match what we expect, we return nil rather
// than hand a caller a half-invented conversation. A wrong transcript would be
// worse than no transcript — the reply composer grounds real text on it.

// Emoji-only bubbles ("👍") are real messages and must survive chrome filtering.
private extension Character {
    var isEmojiGlyph: Bool {
        unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0x238C } ?? false
    }
}

@MainActor
final class MessagesReader {
    static let shared = MessagesReader()
    private init() {}

    // MARK: - Model

    /// One rendered bubble. `sender` is "Me" for outgoing, otherwise the
    /// conversation name — see `readFrontmostThread()` for why per-person
    /// attribution inside group chats is deliberately not attempted.
    struct Message {
        let sender: String
        let text: String
        let isFromMe: Bool
    }

    /// The conversation currently displayed in a native chat app's transcript
    /// pane. `inputFieldValue` is whatever the user has already typed but not
    /// sent — a half-written reply is a strong signal of intent for the composer.
    struct Thread {
        let contact: String
        let messages: [Message]
        let inputFieldValue: String
        /// Which native chat app this was read from ("Messages", "WhatsApp",
        /// "Discord", …) — lets callers label the surface with the real app.
        let app: String

        init(contact: String, messages: [Message], inputFieldValue: String,
             app: String = "Messages") {
            self.contact = contact
            self.messages = messages
            self.inputFieldValue = inputFieldValue
            self.app = app
        }
    }

    // MARK: - Tuning

    /// Transcript cap. Enough for the composer to catch the thread's tone and
    /// the question being asked; short enough to stay out of prompt bloat.
    private static let maxMessages = 15

    private static let messagesBundleID = "com.apple.MobileSMS"

    // MARK: - Supported native chat apps
    //
    // Holmes reads these desktop chat apps through the SAME AX transcript logic
    // as Messages: a right-pinned scroll area of AXStaticText bubbles, right = me
    // by margin, chrome filtered. Every entry is FRAGILE per-app (Electron /
    // Catalyst trees that shift between releases), which is why every read fails
    // closed — a wrong match, or a tree that doesn't fit, yields nil, never a
    // half-invented conversation.

    /// The display name for a running app when it is one Holmes can read as a
    /// chat, else nil. Matched by bundle id (exact) or app name. Shared with
    /// ScreenEngine, which routes these apps to its `.chat` AX family.
    static func chatAppDisplayName(name: String, bundleID: String) -> String? {
        let n = name.lowercased(), b = bundleID.lowercased()
        if b == messagesBundleID.lowercased() || n == "messages" { return "Messages" }
        if b == "net.whatsapp.whatsapp" || b.contains("whatsapp") || n.contains("whatsapp") { return "WhatsApp" }
        if b == "com.hnc.discord" || n == "discord" { return "Discord" }
        if b == "com.tinyspeck.slackmacgap" || n == "slack" { return "Slack" }
        if b.contains("telegram") || n == "telegram" { return "Telegram" }
        if b.contains("signal") || n == "signal" { return "Signal" }
        return nil
    }

    /// Traversal bounds — an AX walk over a busy window must never become the
    /// reason the main thread stutters.
    private static let maxDepth = 14
    private static let maxChildrenPerNode = 150
    private static let maxCollectedTexts = 400

    // MARK: - Frontmost check

    /// True when Messages is the app the user is actually in right now.
    /// Callers gate on this before treating a read thread as "the conversation
    /// the user is having"; `readFrontmostThread()` itself does NOT require it,
    /// because the Holmes panel steals frontmost the moment it opens.
    func isMessagesFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.bundleIdentifier == Self.messagesBundleID { return true }
        return (front.localizedName ?? "").lowercased() == "messages"
    }

    /// True when Messages is running at all, frontmost or not.
    ///
    /// This is the gate a BACKGROUND poller wants. `readFrontmostThread()` works
    /// perfectly well against a backgrounded Messages — it builds its AXUIElement
    /// from the pid, not from the frontmost app — so the only thing a poller
    /// actually needs to know is whether there is a process to read at all.
    /// One array scan over NSWorkspace, cheap enough to run on every tick, which
    /// is exactly why the expensive AX walk sits behind it.
    func isMessagesRunning() -> Bool {
        messagesApp() != nil
    }

    /// True when ANY supported native chat app (Messages / WhatsApp / Discord /
    /// Slack / Telegram / Signal) is the frontmost app — the fast-cadence gate.
    func isChatAppFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return Self.chatAppDisplayName(name: front.localizedName ?? "",
                                       bundleID: front.bundleIdentifier ?? "") != nil
    }

    /// True when ANY supported native chat app is running, frontmost or not —
    /// the background poller's cheap gate in front of the AX walk.
    func isChatAppRunning() -> Bool {
        frontmostChatApp() != nil
    }

    // MARK: - Read the displayed thread

    /// Reads the conversation shown in Messages' transcript pane, or nil when
    /// Messages isn't running / has no window / the AX tree doesn't look like a
    /// transcript. Returns at most the last `maxMessages` bubbles, oldest first.
    ///
    /// Group chats: Messages does not expose a per-bubble sender in the AX tree
    /// (the name label above a bubble is an untagged AXStaticText that is
    /// indistinguishable from a short message). Rather than guess who said what
    /// — the exact failure mode that would put words in a third party's mouth —
    /// incoming bubbles are attributed to the conversation as a whole.
    func readFrontmostThread() -> Thread? {
        guard let (app, appName) = frontmostChatApp() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call

        guard let window = frontWindow(of: axApp),
              let windowFrame = frame(of: window),
              windowFrame.width > 200, windowFrame.height > 200
        else { return nil }

        // The window title IS the conversation name in Messages/WhatsApp (it
        // falls back to the app's own name only when no chat is selected — which
        // is exactly the case where there is nothing to read).
        let contact = conversationName(of: window, appName: appName)

        guard let transcript = findTranscript(in: window, windowFrame: windowFrame),
              let transcriptFrame = frame(of: transcript)
        else { return nil }

        var texts: [(frame: CGRect, text: String)] = []
        collectStaticTexts(from: transcript, into: &texts, depth: 0)

        // Bubbles only — timestamps, "Delivered"/"Read" receipts and day
        // separators are laid out inside the same container.
        let bubbles = texts.filter { isLikelyMessageText($0.text) }
        guard !bubbles.isEmpty else { return nil }

        // AX geometry is top-left origin in screen points, so ascending y is
        // top-to-bottom — i.e. oldest message first in a Messages transcript.
        let ordered = bubbles.sorted { $0.frame.minY < $1.frame.minY }
        let recent = ordered.suffix(Self.maxMessages)

        let messages = recent.map { bubble -> Message in
            let fromMe = isFromMe(bubble: bubble.frame, in: transcriptFrame)
            return Message(
                sender: fromMe ? "Me" : (contact.isEmpty ? "Them" : contact),
                text: bubble.text,
                isFromMe: fromMe
            )
        }

        return Thread(contact: contact,
                      messages: Array(messages),
                      inputFieldValue: inputFieldValue(in: window),
                      app: appName)
    }

    // MARK: - Locating the app + window

    private func messagesApp() -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let byID = running.first(where: { $0.bundleIdentifier == Self.messagesBundleID }) {
            return byID
        }
        return running.first { ($0.localizedName ?? "").lowercased() == "messages" }
    }

    /// The chat app to read, with its display name: the frontmost supported chat
    /// app when the user is in one right now, otherwise the first running
    /// supported app — Messages first, so nothing about the original single-app
    /// iMessage path changes when only Messages is running.
    private func frontmostChatApp() -> (app: NSRunningApplication, display: String)? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let display = Self.chatAppDisplayName(name: front.localizedName ?? "",
                                                 bundleID: front.bundleIdentifier ?? "") {
            return (front, display)
        }
        let running = NSWorkspace.shared.runningApplications
        if let messages = messagesApp() { return (messages, "Messages") }
        for app in running {
            if let display = Self.chatAppDisplayName(name: app.localizedName ?? "",
                                                     bundleID: app.bundleIdentifier ?? "") {
                return (app, display)
            }
        }
        return nil
    }

    /// Focused window, then main window, then the first window — Messages keeps
    /// exactly one chat window in practice, but a detached conversation window
    /// (double-clicked thread) is focused rather than main.
    private func frontWindow(of axApp: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
               let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }
        return windows.first
    }

    private func conversationName(of window: AXUIElement, appName: String) -> String {
        let title = (string(window, kAXTitleAttribute as String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The app's own name (e.g. "Messages", "WhatsApp") is the empty-state /
        // static window title, not a contact.
        if title.isEmpty
            || title.lowercased() == appName.lowercased()
            || title.lowercased() == "messages" { return "" }
        return title
    }

    // MARK: - Locating the transcript

    /// Finds the scroll area / table that holds the message bubbles.
    ///
    /// FRAGILE, and knowingly so. The sidebar (chat list) is also a scrollable
    /// container full of AXStaticText — the preview snippets — so text count
    /// alone would pick the wrong pane. What actually separates them is layout:
    /// the transcript is the pane pinned to the window's RIGHT edge and taking
    /// most of its height. Candidates must satisfy that geometry first, and the
    /// winner is then the one holding the most message-shaped text. Ties go to
    /// the LAST candidate found, which is the deepest one — Messages nests the
    /// real transcript scroll area inside outer group/scroll wrappers, and the
    /// inner node is the one whose bounds match the bubbles.
    private func findTranscript(in window: AXUIElement, windowFrame: CGRect) -> AXUIElement? {
        let containerRoles: Set<String> = ["AXScrollArea", "AXTable", "AXList", "AXOutline", "AXGroup"]
        var best: (element: AXUIElement, score: Int)?

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < Self.maxDepth else { return }

            if let role = role(of: element), containerRoles.contains(role), let f = frame(of: element) {
                let pinnedRight = f.maxX >= windowFrame.maxX - 60
                let largeEnough = f.width >= windowFrame.width * 0.30
                                  && f.height >= windowFrame.height * 0.30
                if pinnedRight && largeEnough {
                    var texts: [(frame: CGRect, text: String)] = []
                    collectStaticTexts(from: element, into: &texts, depth: 0)
                    let score = texts.filter { isLikelyMessageText($0.text) }.count
                    // >= (not >) so equal-scoring deeper containers replace their
                    // own wrappers — see the note above.
                    if score > 0 && score >= (best?.score ?? 0) {
                        best = (element, score)
                    }
                }
            }

            for child in children(of: element).prefix(40) {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return best?.element
    }

    /// The compose box: the one AXTextArea in the window. Empty string when the
    /// user hasn't typed anything (or when the field can't be found — an empty
    /// draft and an unreadable draft are the same thing to every caller).
    private func inputFieldValue(in window: AXUIElement) -> String {
        guard let field = findTextArea(in: window, depth: 0) else { return "" }
        return (string(field, kAXValueAttribute as String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findTextArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < Self.maxDepth else { return nil }
        if role(of: element) == (kAXTextAreaRole as String) { return element }
        for child in children(of: element).prefix(60) {
            if let found = findTextArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Bubble collection + attribution

    private func collectStaticTexts(from element: AXUIElement,
                                    into result: inout [(frame: CGRect, text: String)],
                                    depth: Int) {
        guard depth < Self.maxDepth, result.count < Self.maxCollectedTexts else { return }

        if role(of: element) == (kAXStaticTextRole as String) {
            let raw = string(element, kAXValueAttribute as String)
                ?? string(element, kAXTitleAttribute as String)
                ?? ""
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 1500,
               let f = frame(of: element), f.width > 1, f.height > 1 {
                result.append((f, text))
            }
            return  // static text has no children worth walking
        }

        for child in children(of: element).prefix(Self.maxChildrenPerNode) {
            collectStaticTexts(from: child, into: &result, depth: depth + 1)
        }
    }

    /// From-me vs from-them, decided purely by where the bubble sits.
    ///
    /// THE HEURISTIC: iMessage right-aligns the bubbles you sent and
    /// left-aligns the ones you received, so the giveaway is the MARGIN — a
    /// sent bubble hugs the transcript's right edge no matter how wide it is,
    /// while a received bubble hugs the left. Comparing margins (rather than
    /// midpoints) is what keeps long, nearly-full-width messages classified
    /// correctly. When the two margins are within a few points of each other
    /// the bubble spans the pane and margins say nothing, so we fall back to
    /// which half of the pane its center lands in.
    ///
    /// This breaks if Apple ever centers bubbles or flips the layout for RTL
    /// locales. It is the least-bad signal available: the AX tree carries no
    /// direction attribute on message rows.
    private func isFromMe(bubble: CGRect, in container: CGRect) -> Bool {
        let leftMargin = bubble.minX - container.minX
        let rightMargin = container.maxX - bubble.maxX
        if abs(leftMargin - rightMargin) < 8 {
            return bubble.midX > container.midX
        }
        return rightMargin < leftMargin
    }

    // MARK: - Chrome filtering

    /// Labels Messages renders as AXStaticText that are not messages.
    private static let chromeLabels: Set<String> = [
        "delivered", "read", "sent", "sending", "not delivered", "unsent",
        "today", "yesterday", "now", "imessage", "sms", "mms", "text message",
        "message", "new message", "edited", "you", "me", "typing",
        "read receipts", "send", "details", "facetime", "audio", "video",
        "tapback", "reactions", "sent with invisible ink", "screen effect",
        "message send failure", "your message could not be sent"
    ]

    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday",
                                   "friday", "saturday", "sunday",
                                   "mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    private func isLikelyMessageText(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 1500 else { return false }
        if Self.chromeLabels.contains(t) { return false }

        // Receipt lines carry a time: "Delivered 9:41 AM", "Read Tuesday".
        if t.hasPrefix("delivered") || t.hasPrefix("read ") || t.hasPrefix("edited") { return false }

        // Timestamp separators: "9:41 AM", "Today 9:41 AM", "Mon 10:02 PM".
        if isTimestampOnly(t) { return false }

        // Pure ornament (separator rules, stray punctuation). Emoji-only
        // bubbles are real messages, so they're explicitly kept.
        let hasWordCharacter = t.rangeOfCharacter(from: .alphanumerics) != nil
        let hasEmoji = text.contains { $0.isEmojiGlyph }
        return hasWordCharacter || hasEmoji
    }

    /// True only when the line is NOTHING BUT a date/time — i.e. every
    /// character is accounted for by digits, separators, am/pm or a day word.
    /// Written subtractively on purpose: a naive `contains("pm")` test would
    /// throw away a real message like "see you at 5pm".
    private func isTimestampOnly(_ t: String) -> Bool {
        guard t.count <= 30, t.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        var remainder = t
        for token in Self.weekdays + ["today", "yesterday", "am", "pm", "at"] {
            remainder = remainder.replacingOccurrences(of: token, with: " ")
        }
        remainder = remainder
            .components(separatedBy: CharacterSet(charactersIn: "0123456789:/.,- ")).joined()
        return remainder.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - AX primitives

    private func role(of element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref as? String
        else { return nil }
        return value
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement]
        else { return [] }
        return kids
    }

    /// Screen-space rect of an element. AXPosition/AXSize come back as opaque
    /// AXValues that must be unwrapped with AXValueGetValue — a plain bridging
    /// cast yields nothing.
    private func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let size = sizeRef,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
