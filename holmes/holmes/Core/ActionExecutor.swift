import Foundation
import AppKit

// MARK: - ActionExecutor
// Uses macOS Accessibility API to actually control apps on screen.
// Requires Accessibility permission (already in entitlements).

final class ActionExecutor {
    static let shared = ActionExecutor()
    private init() {}

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

    @discardableResult
    func typeIntoFocusedField(in app: NSRunningApplication, text: String) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call

        // Find focused UI element
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else {
            // Try to focus the main window's text area first
            return typeViaKeyboard(text: text)
        }

        let element = focused as! AXUIElement

        // Check if it's settable
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)

        if settable.boolValue {
            // Set value directly (fastest, works for most fields)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            if result == .success {
                return true
            }
        }

        // Fallback: simulate keyboard typing
        return typeViaKeyboard(text: text)
    }

    // MARK: - Click a button by label in the frontmost app

    /// Roles a "press the control named X" request may target.
    private static let pressableRoles: Set<String> = [
        kAXButtonRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXMenuItemRole as String, "AXLink"
    ]

    /// Presses the best matching control (exact, then case insensitive, then
    /// substring, across title/description/help/identifier). Returns true only
    /// when AXPress itself reported success. Does a bounded tree walk with
    /// blocking IPC: call it OFF the main thread.
    @discardableResult
    func clickButton(label: String, in app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        guard let button = findElement(in: axApp, roles: Self.pressableRoles, label: label) else { return false }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            print("[Holmes] AXPress on “\(label)” failed: AXError \(result.rawValue)")
            return false
        }
        return true
    }

    // MARK: - Find and focus a text field in an app, then type

    /// Nonisolated async: runs on the concurrency pool, never the main thread,
    /// and waits for focus with Task.sleep instead of blocking a thread.
    @discardableResult
    func focusAndType(in app: NSRunningApplication, fieldHint: String? = nil, text: String) async -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call

        // Find the best matching text area / text field in one bounded walk.
        let roles: Set<String> = [kAXTextAreaRole as String, kAXTextFieldRole as String]
        if let field = findElement(in: axApp, roles: roles, label: fieldHint) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)
            // Small delay for focus to settle, without blocking a thread.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return false }
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
            if settable.boolValue,
               AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                return true
            }
        }
        // Fallback to clipboard paste
        return pasteText(text, into: app)
    }

    // MARK: - Paste via clipboard (most reliable cross-app method)

    func pasteText(_ text: String, into app: NSRunningApplication) -> Bool {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Bring app to front and simulate Cmd+A (select all) then paste
        app.activate()
        Thread.sleep(forTimeInterval: 0.15)

        // Simulate Cmd+V
        let src = CGEventSource(stateID: .hidSystemState)
        let vKeyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let vKeyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vKeyDown?.flags = .maskCommand
        vKeyUp?.flags   = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)

        // Restore clipboard after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let prev = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
        }
        return true
    }

    // MARK: - Send message in a specific app

    // MARK: - Main entry point

    /// Puts text into the frontmost/target app's message field.
    /// For iMessage/Messages: uses AX + CGEvent (no Automation permission required).
    /// For Electron apps (Discord, Slack): uses AppleScript.
    func sendMessageInApp(_ appName: String, message: String) -> Bool {
        let lower = appName.lowercased()

        // iMessage / Messages.app — use AX to find text area, then CGEvent paste
        // This avoids needing Automation permission which AppleScript requires.
        if lower.contains("messages") {
            guard let app = runningApp(named: appName) ?? runningApp(named: "Messages") else {
                return typeViaKeyboard(text: message)
            }
            return pasteIntoMessagesApp(app, message: message)
        }

        // Electron apps (Discord, Slack, Teams) — clipboard + AppleScript
        let safe = message.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let simpleScript = """
set the clipboard to "\(safe)"
tell application "\(appName)" to activate
delay 0.5
tell application "System Events"
    keystroke "a" using command down
    delay 0.1
    keystroke "v" using command down
end tell
"""
        return runAppleScript(simpleScript)
    }

    /// Stages text into the target app at the CURRENT cursor position — activate
    /// + paste only, never Cmd+A. Used by the draft review card's Insert, which
    /// can run long after the draft's original context: a select-all there could
    /// replace unrelated content wholesale (e.g. a Google Doc focused in the same
    /// browser that once showed Gmail). Never presses Send/Return.
    func stageTextInApp(_ appName: String, text: String) -> Bool {
        let lower = appName.lowercased()

        if lower.contains("messages") {
            guard let app = runningApp(named: appName) ?? runningApp(named: "Messages") else {
                return typeViaKeyboard(text: text)
            }
            return pasteIntoMessagesApp(app, message: text, replaceExisting: false)
        }

        let safe = text.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
set the clipboard to "\(safe)"
tell application "\(appName)" to activate
delay 0.5
tell application "System Events"
    keystroke "v" using command down
end tell
"""
        return runAppleScript(script)
    }

    /// AX-based paste for Messages.app — no Automation permission needed.
    /// `replaceExisting: false` skips the Cmd+A so the paste lands at the cursor.
    private func pasteIntoMessagesApp(_ app: NSRunningApplication, message: String, replaceExisting: Bool = true) -> Bool {
        // 1. Set clipboard
        let pasteboard = NSPasteboard.general
        let prev = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)

        // 2. Bring Messages to front
        app.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.4)

        // 3. Try to AX-focus the text input area
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        if let textArea = findElement(in: axApp, roles: [kAXTextAreaRole as String], label: nil) {
            AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, true as CFTypeRef)
            Thread.sleep(forTimeInterval: 0.15)
        }

        // 4. Cmd+A to clear any existing draft, then Cmd+V to paste
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ key: CGKeyCode, flags: CGEventFlags = []) {
            let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
            d?.flags = flags; u?.flags = flags
            d?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
            u?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
        }
        if replaceExisting {
            post(0x00, flags: .maskCommand)  // Cmd+A (select all in input)
        }
        post(0x09, flags: .maskCommand)  // Cmd+V (paste)

        // 5. Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let prev {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
        }
        return true
    }

    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&error)
            if let err = error {
                print("[Holmes] AppleScript error: \(err)")
                return false
            }
            print("[Holmes] AppleScript executed — result: \(result.stringValue ?? "ok")")
            return true
        }
        return false
    }

    // MARK: - Helpers

    private func typeViaKeyboard(text: String) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        for char in text.unicodeScalars {
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
            keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Wall clock budget for one element lookup, on top of the depth and
    /// element count limits in AXElementSearch.
    private static let searchTimeBudget: TimeInterval = 2.5

    /// Bounded breadth first lookup. With a label, the best ranked match wins
    /// (exact title/description/help/identifier/placeholder beats case
    /// insensitive beats substring); without one, the first element of a role.
    private func findElement(in root: AXUIElement, roles: Set<String>, label: String?) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(Self.searchTimeBudget)
        let result = AXElementSearch.best(
            from: root,
            stopScore: label == nil ? 1 : AXLabelMatch.exact.rawValue,
            children: { element in
                guard Date() < deadline else { return [] }
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { return [] }
                for child in children { AXUIElementSetMessagingTimeout(child, 1.0) }
                return children
            },
            score: { element in
                guard let role = Self.stringAttribute(element, kAXRoleAttribute as String), roles.contains(role) else {
                    return nil
                }
                guard let label else { return 1 }
                let names = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                             kAXHelpAttribute as String, "AXIdentifier", kAXPlaceholderValueAttribute as String]
                    .map { Self.stringAttribute(element, $0) }
                return AXElementSearch.labelMatch(label, names: names)?.rawValue
            })
        if result.node == nil, result.truncated {
            print("[Holmes] AX lookup stopped at its limit after \(result.visited) elements")
        }
        return result.node
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
