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

    @discardableResult
    func clickButton(label: String, in app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call
        if let button = findElement(in: axApp, role: kAXButtonRole, label: label) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return true
        }
        return false
    }

    // MARK: - Find and focus a text field in an app, then type

    @discardableResult
    func focusAndType(in app: NSRunningApplication, fieldHint: String? = nil, text: String) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // a stalled app must not freeze Holmes for the 6 s default per call

        // Try to find a text area / text field
        let roles = [kAXTextAreaRole, kAXTextFieldRole]
        for role in roles {
            if let field = findElement(in: axApp, role: role, label: fieldHint) {
                // Focus it
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)
                // Small delay for focus to settle
                Thread.sleep(forTimeInterval: 0.1)
                // Set value
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
                if settable.boolValue {
                    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFTypeRef)
                    return true
                }
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
        if let textArea = findTextAreaDeep(in: axApp) {
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

    private func findElement(in element: AXUIElement, role: String, label: String?) -> AXUIElement? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let r = roleRef as? String, r == role {
            if let label {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, title.lowercased().contains(label.lowercased()) {
                    return element
                }
            } else {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            if let found = findElement(in: child, role: role, label: label) {
                return found
            }
        }
        return nil
    }

    private func findTextAreaDeep(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == kAXTextAreaRole as String {
            return element
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            if let found = findTextAreaDeep(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased().contains(name.lowercased()) == true
        }
    }
}
