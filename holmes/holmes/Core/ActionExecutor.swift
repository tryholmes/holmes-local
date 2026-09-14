import Foundation
import AppKit

// MARK: - ActionExecutor
// Uses macOS Accessibility API to actually control apps on screen.
// Requires Accessibility permission (already in entitlements).
//
// Threading: the async entry points are nonisolated, so their blocking AX IPC
// and event posting run on the concurrency pool, never the main thread, and
// they wait with Task.sleep. NSAppleScript is the exception: it is only ever
// executed on the main actor (see runAppleScript).
//
// Honesty: every text entry returns a TextEntryResult. A field whose value can
// be read back is VERIFIED; otherwise the result is "unverified", never a
// silent success. Nothing presses ⌘A unless the caller explicitly asks to
// replace the field's contents.

final class ActionExecutor {
    static let shared = ActionExecutor()
    private init() {}

    /// Pause between synthetic key events so the target app's event queue
    /// keeps up with long text.
    private static let keyEventPacingNanoseconds: UInt64 = 6_000_000

    // MARK: - Type text into the focused element of the frontmost app

    /// True when the app's focused AX element accepts text (a text area/field
    /// whose value is settable). Used to decide whether a ⌘N is needed first.
    func hasEditableFocus(in app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success ? roleRef as? String : nil) ?? ""
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String || role == "AXWebArea" { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Sets the focused field's value through Accessibility (verified by reading
    /// it back), or types it with keyboard events when the value isn't settable.
    func typeIntoFocusedField(in app: NSRunningApplication, text: String) async -> TextEntryResult {
        guard let element = focusedElement(of: app.processIdentifier) else {
            return await typeViaKeyboard(text: text, verifyIn: nil)
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
            if TextEntryVerifier.fieldValue(Self.stringValue(of: element), contains: text) { return .verified }
            // Typing now could enter the text twice if the set did land.
            return .unverified("the field accepted the text but did not report it back")
        }

        return await typeViaKeyboard(text: text, verifyIn: element)
    }

    // MARK: - Click a button by label in the frontmost app

    /// Roles a "press the control named X" request may target.
    private static let pressableRoles: Set<String> = [
        kAXButtonRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXMenuItemRole as String, "AXLink"
    ]

    /// Presses the best matching control (exact, then case insensitive, then
    /// substring across title/description/identifier/placeholder; help text
    /// only when it equals the label). The commit gate runs on the MATCHED
    /// control: unless `allowCommit`, a send/submit class control is not
    /// pressed and `.needsConfirmation` names it. `.pressed` only when AXPress
    /// itself reported success. Bounded tree walk with blocking IPC: call it
    /// OFF the main thread.
    func pressControl(label: String, in app: NSRunningApplication, allowCommit: Bool) -> AXPressOutcome {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        guard let button = findElement(in: axApp, roles: Self.pressableRoles, label: label) else { return .notFound }
        let names = Self.names(of: button)
        let matched = names.visibleName.isEmpty ? label : names.visibleName
        if CommitControlGate.pressNeedsConfirmation(requested: label, matched: names, userConfirmed: allowCommit) {
            return .needsConfirmation(matched: matched)
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            print("[Holmes] AXPress on “\(label)” failed: AXError \(result.rawValue)")
            return .failed(code: result.rawValue)
        }
        return .pressed(matched: matched)
    }

    // MARK: - Find and focus a text field in an app, then type

    /// Nonisolated async: runs on the concurrency pool, never the main thread,
    /// and waits for focus with Task.sleep instead of blocking a thread.
    func focusAndType(in app: NSRunningApplication, fieldHint: String? = nil, text: String) async -> TextEntryResult {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call

        // One bounded walk that prefers a text area (the body) over a text
        // field (a search box) at equal label quality.
        if let field = findTextEntryField(in: axApp, hint: fieldHint) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)
            // Small delay for focus to settle, without blocking a thread.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return .failed("Stopped.") }
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
            if settable.boolValue,
               AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                return TextEntryVerifier.fieldValue(Self.stringValue(of: field), contains: text)
                    ? .verified
                    : .unverified("the field accepted the text but did not report it back")
            }
        }
        // Fallback to clipboard paste
        return await pasteText(text, into: app)
    }

    // MARK: - Paste via clipboard (most reliable cross-app method)

    /// Activates the app and pastes at the cursor (never select all first).
    func pasteText(_ text: String, into app: NSRunningApplication) async -> TextEntryResult {
        app.activate()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return .failed("Stopped.") }
        return await pasteFromClipboard(text, field: focusedElement(of: app.processIdentifier), replaceExisting: false)
    }

    // MARK: - Main entry point

    /// Puts text into the target app's message field. Never presses Send.
    /// For iMessage/Messages: uses AX + CGEvent (no Automation permission required).
    /// For other apps (Discord, Slack, Teams): AppleScript activation and paste.
    /// `replaceExisting` selects all first; only pass true when the caller
    /// really means to wipe what is already in the field.
    func sendMessageInApp(_ appName: String, message: String, replaceExisting: Bool = false) async -> TextEntryResult {
        if appName.lowercased().contains("messages") {
            guard let app = runningApp(named: appName) ?? runningApp(named: "Messages") else {
                // Typing blind into whatever has focus is not "sending".
                return .failed("Messages is not running")
            }
            return await pasteIntoMessagesApp(app, message: message, replaceExisting: replaceExisting)
        }
        return await pasteIntoApp(named: appName, text: message, replaceExisting: replaceExisting)
    }

    /// Stages text into the target app at the CURRENT cursor position — activate
    /// + paste only, never Cmd+A. Used by the draft review card's Insert, which
    /// can run long after the draft's original context: a select-all there could
    /// replace unrelated content wholesale (e.g. a Google Doc focused in the same
    /// browser that once showed Gmail). Never presses Send/Return.
    func stageTextInApp(_ appName: String, text: String) async -> TextEntryResult {
        await sendMessageInApp(appName, message: text, replaceExisting: false)
    }

    /// AppleScript path: the clipboard is snapshotted in full, set by the
    /// script (message and app name escaped as AppleScript literals), the app is
    /// activated, and System Events pastes. The snapshot is restored once the
    /// paste is confirmed or after a longer adaptive delay.
    private func pasteIntoApp(named appName: String, text: String, replaceExisting: Bool) async -> TextEntryResult {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        let prepare = """
        set holmesTargetApp to \(AppleScriptText.literal(appName))
        set the clipboard to \(AppleScriptText.literal(text))
        tell application holmesTargetApp to activate
        """
        guard await runAppleScript(prepare) else {
            await restore(snapshot, onlyIfChangeCountIs: nil)
            return .failed("AppleScript could not put the text on the clipboard or activate \(appName)")
        }
        let ownChangeCount = pasteboard.changeCount
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else {
            await restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
            return .failed("Stopped.")
        }
        let field = runningApp(named: appName).flatMap { focusedElement(of: $0.processIdentifier) }
        let before = field.flatMap(Self.stringValue(of:))
        let keystrokes = replaceExisting
            ? "keystroke \"a\" using command down\n    delay 0.1\n    keystroke \"v\" using command down"
            : "keystroke \"v\" using command down"
        guard await runAppleScript("tell application \"System Events\"\n    \(keystrokes)\nend tell") else {
            await restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
            return .failed("System Events could not paste into \(appName)")
        }
        return await confirmPaste(text, field: field, before: before, replaced: replaceExisting,
                                  snapshot: snapshot, ownChangeCount: ownChangeCount)
    }

    /// AX-based paste for Messages.app — no Automation permission needed.
    /// `replaceExisting: false` skips the Cmd+A so the paste lands at the cursor.
    private func pasteIntoMessagesApp(_ app: NSRunningApplication, message: String, replaceExisting: Bool) async -> TextEntryResult {
        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return .failed("Stopped.") }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        var field = findElement(in: axApp, roles: [kAXTextAreaRole as String], label: nil)
        if let textArea = field {
            AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, true as CFTypeRef)
            try? await Task.sleep(nanoseconds: 150_000_000)
        } else {
            field = focusedElement(of: app.processIdentifier)
        }
        return await pasteFromClipboard(message, field: field, replaceExisting: replaceExisting)
    }

    /// CGEvent paste with a full clipboard snapshot.
    private func pasteFromClipboard(_ text: String, field: AXUIElement?, replaceExisting: Bool) async -> TextEntryResult {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            await restore(snapshot, onlyIfChangeCountIs: nil)
            return .failed("couldn't put the text on the clipboard")
        }
        let ownChangeCount = pasteboard.changeCount
        let before = field.flatMap(Self.stringValue(of:))
        if replaceExisting {
            guard await postKey(0x00, flags: .maskCommand) else {  // Cmd+A, only when asked
                await restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
                return .failed("couldn't create keyboard events (is Accessibility granted?)")
            }
        }
        guard await postKey(0x09, flags: .maskCommand) else {      // Cmd+V
            await restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
            return .failed("couldn't create keyboard events (is Accessibility granted?)")
        }
        return await confirmPaste(text, field: field, before: before, replaced: replaceExisting,
                                  snapshot: snapshot, ownChangeCount: ownChangeCount)
    }

    /// Polls the field for the pasted text. Confirmed: restore the clipboard
    /// now. Unconfirmed: leave the text on the clipboard a while longer (a slow
    /// app may still be reading it), then restore, and say it is unverified.
    private func confirmPaste(_ text: String, field: AXUIElement?, before: String?, replaced: Bool,
                              snapshot: PasteboardSnapshot, ownChangeCount: Int) async -> TextEntryResult {
        if let field {
            let alreadyThere = !replaced && TextEntryVerifier.fieldValue(before, contains: text)
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let value = Self.stringValue(of: field)
                if TextEntryVerifier.fieldValue(value, contains: text), !alreadyThere || value != before {
                    await restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
                    return .verified
                }
                if Task.isCancelled { break }
            }
        }
        let delay = TextEntryVerifier.unconfirmedRestoreDelay(forLength: text.count)
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.restore(snapshot, onlyIfChangeCountIs: ownChangeCount)
        }
        return .unverified(field == nil
            ? "the paste was sent, but the target field does not expose its contents"
            : "the paste was sent, but the text did not show up in the field's value")
    }

    /// Restores the user's clipboard unless someone else changed it since
    /// Holmes borrowed it (then theirs is newer and must be kept).
    @MainActor
    private func restore(_ snapshot: PasteboardSnapshot, onlyIfChangeCountIs expected: Int?) {
        let pasteboard = NSPasteboard.general
        if let expected, pasteboard.changeCount != expected { return }
        snapshot.restore(to: pasteboard)
    }

    /// NSAppleScript is not thread safe and must only run on the main actor.
    /// Scripts here are short (no `delay`); waits happen in Swift.
    @MainActor
    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let err = error {
            print("[Holmes] AppleScript error: \(err)")
            return false
        }
        print("[Holmes] AppleScript executed — result: \(result.stringValue ?? "ok")")
        return true
    }

    // MARK: - Helpers

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)
        return true
    }

    /// Types with keyboard events carrying whole UTF-16 chunks (surrogate pairs
    /// and grapheme clusters never split), paced so fast text isn't dropped.
    /// Verified only when `element` exposes its value and it contains the text.
    private func typeViaKeyboard(text: String, verifyIn element: AXUIElement?) async -> TextEntryResult {
        let chunks = KeyboardText.utf16Chunks(text)
        guard !chunks.isEmpty else { return .verified }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in chunks {
            guard !Task.isCancelled else { return .failed("Stopped before all of the text was typed.") }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .failed("couldn't create keyboard events (is Accessibility granted?)")
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: Self.keyEventPacingNanoseconds)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: Self.keyEventPacingNanoseconds)
        }
        if let element {
            for _ in 0..<5 {
                if TextEntryVerifier.fieldValue(Self.stringValue(of: element), contains: text) { return .verified }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return .unverified(element == nil
            ? "keystrokes were sent, but no focused field could be read back"
            : "keystrokes were sent, but the text did not show up in the field's value")
    }

    private func focusedElement(of pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 1.0)
        return element
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute as String)
    }

    /// Wall clock budget for one element lookup, on top of the depth and
    /// element count limits in AXElementSearch.
    private static let searchTimeBudget: TimeInterval = 2.5

    /// Bounded breadth first lookup. With a label, the best ranked match wins
    /// (exact title/description/help/identifier/placeholder beats case
    /// insensitive beats substring); without one, the first element of a role.
    private func findElement(in root: AXUIElement, roles: Set<String>, label: String?) -> AXUIElement? {
        findBest(in: root, stopScore: label == nil ? 1 : AXLabelMatch.exact.rawValue) { role, names in
            guard roles.contains(role) else { return nil }
            guard let label else { return 1 }
            return AXElementSearch.labelMatch(label, in: names())?.rawValue
        }
    }

    /// The field ax_type should fill: text areas beat text fields.
    private func findTextEntryField(in root: AXUIElement, hint: String?) -> AXUIElement? {
        findBest(in: root, stopScore: AXElementSearch.textEntryStopScore(hasHint: hint != nil)) { role, names in
            AXElementSearch.textEntryScore(role: role, hint: hint, names: names)
        }
    }

    /// Bounded walk scoring each element by role and (lazily read) names.
    private func findBest(in root: AXUIElement, stopScore: Int,
                          score: (String, () -> AXNames) -> Int?) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(Self.searchTimeBudget)
        let result = AXElementSearch.best(
            from: root,
            stopScore: stopScore,
            children: { element in
                guard Date() < deadline else { return [] }
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { return [] }
                for child in children { AXUIElementSetMessagingTimeout(child, 1.0) }
                return children
            },
            score: { element in
                guard let role = Self.stringAttribute(element, kAXRoleAttribute as String) else { return nil }
                return score(role) { Self.names(of: element) }
            })
        if result.node == nil, result.truncated {
            print("[Holmes] AX lookup stopped at its limit after \(result.visited) elements")
        }
        return result.node
    }

    private static func names(of element: AXUIElement) -> AXNames {
        AXNames(title: stringAttribute(element, kAXTitleAttribute as String),
                description: stringAttribute(element, kAXDescriptionAttribute as String),
                help: stringAttribute(element, kAXHelpAttribute as String),
                identifier: stringAttribute(element, "AXIdentifier"),
                placeholder: stringAttribute(element, kAXPlaceholderValueAttribute as String))
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased().contains(name.lowercased()) == true
        }
    }
}
