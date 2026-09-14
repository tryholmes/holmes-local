import AppKit
import ApplicationServices
import Foundation

/// Apple Mail's labeled AX fields. No OCR or focus guessing. The body may be a
/// plain text area or, in current Mail, a WebKit AXWebArea; writing uses the AX
/// value when Mail allows it and otherwise a paste into that exact body, with the
/// clipboard saved and restored. Nothing here ever sends.
@MainActor
enum MailComposeReader {
    private struct Candidate {
        let snapshot: EmailComposeSnapshot
        let match: MailComposeMatch
        let body: AXUIElement
        let subject: AXUIElement
        let processIdentifier: pid_t
    }
    private struct UndoRecord {
        let identity: String
        let before: String
        let after: String
        let subjectBefore: String?
        let subjectAfter: String?
        let usedPaste: Bool
    }
    private static var identities: [(element: AXUIElement, id: String)] = []
    private static var undoRecords: [String: UndoRecord] = [:]

    static func readCurrent() -> EmailComposeSnapshot? { readCandidate()?.snapshot }

    static func refreshEmailComposeContext() -> LiveContext? {
        guard let compose = readCurrent() else { return nil }
        let reading = ScreenReading(appName: compose.app, windowTitle: compose.subject,
                                    bodyText: compose.body, emailCompose: compose)
        return LiveContextBuilder.fromAccessibility(reading: reading, focused: nil)
    }

    static func stageEmailDraft(_ text: String, expected: EmailComposeSnapshot) async throws -> Bool {
        _ = try await writeEmailDraft(text, subject: nil, mode: expected.bodyIsEmpty ? .auto : .replace, expected: expected)
        return true
    }

    /// Mail's AX body includes its signature as plain text that cannot be told
    /// apart, so automatic writes need a truly empty body, and replacing existing
    /// text needs a settable AX value.
    static func writeEmailDraft(_ text: String, subject: String?, mode: EmailWriteMode,
                                expected: EmailComposeSnapshot) async throws -> EmailWriteReceipt {
        guard expected.source == .accessibility, expected.appBundleIdentifier == "com.apple.mail",
              expected.bodyReadable, !EmailComposeSnapshot.isBlankBody(text), text.count <= 16_000,
              let current = readCandidate(), current.snapshot.revisionKey == expected.revisionKey else {
            throw EmailComposeError.unavailable("The Mail composer or its contents changed. Refresh the draft before inserting.")
        }
        if mode == .auto, !current.snapshot.bodyIsEmpty {
            throw EmailComposeError.unavailable("The Mail message already has text, so Holmes did not write automatically.")
        }
        let before = current.snapshot.body
        let hasText = !EmailComposeSnapshot.isBlankBody(before)
        // Mail's body text includes its signature and quoted thread: replacing
        // would erase them and inserting would land below them.
        guard current.snapshot.supportsReviewedWrite else {
            throw EmailComposeError.unavailable("This Mail message already has text, including any signature or quote, so Holmes will not change it. Copy the draft instead.")
        }
        let target = mode == .insert && hasText ? before + "\n\n" + text : text
        let usedPaste: Bool
        if current.match.bodyValueSettable {
            guard AXUIElementSetAttributeValue(current.body, kAXValueAttribute as CFString, target as CFString) == .success else {
                throw EmailComposeError.unavailable("Mail refused to insert the draft. Copy it instead.")
            }
            usedPaste = false
        } else {
            guard mode != .replace || !hasText else {
                throw EmailComposeError.unavailable("Mail does not let Holmes replace this message's text. Copy the draft instead.")
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" else {
                throw EmailComposeError.unavailable("Return to the Mail message to insert the draft.")
            }
            try await paste(hasText ? "\n\n" + text : text, into: current)
            usedPaste = true
        }

        var filled = false
        if let subject, !subject.isEmpty, current.snapshot.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isSettable(current.subject),
           AXUIElementSetAttributeValue(current.subject, kAXValueAttribute as CFString, subject as CFString) == .success {
            filled = true
        }

        guard let after = readCandidate(), after.snapshot.identity == expected.identity,
              after.snapshot.recipients == expected.recipients, after.snapshot.cc == expected.cc, after.snapshot.bcc == expected.bcc,
              Self.lines(after.snapshot.body) == Self.lines(target),
              after.snapshot.subject == (filled ? subject! : expected.subject) else {
            await rollback(to: before, subject: filled ? expected.subject : nil, usedPaste: usedPaste)
            throw EmailComposeError.unavailable("Mail did not confirm the inserted draft, so Holmes put the message back.")
        }
        let token = UUID().uuidString
        undoRecords[token] = UndoRecord(identity: expected.identity, before: before, after: after.snapshot.body,
                                        subjectBefore: filled ? expected.subject : nil, subjectAfter: filled ? subject : nil,
                                        usedPaste: usedPaste)
        if undoRecords.count > 10, let oldest = undoRecords.keys.first(where: { $0 != token }) { undoRecords.removeValue(forKey: oldest) }
        return EmailWriteReceipt(undoToken: token, subjectFilled: filled)
    }

    /// Restores the body and subject exactly, but only while Mail still shows
    /// exactly what Holmes wrote.
    static func undoEmailDraft(token: String, expected: EmailComposeSnapshot) async throws {
        guard let record = undoRecords[token] else {
            throw EmailComposeError.unavailable("There is nothing of Holmes's left to undo in this message.")
        }
        guard let current = readCandidate(), current.snapshot.identity == record.identity else {
            throw EmailComposeError.unavailable("The Mail message Holmes wrote into is no longer open.")
        }
        guard Self.lines(current.snapshot.body) == Self.lines(record.after),
              record.subjectAfter == nil || current.snapshot.subject == record.subjectAfter else {
            throw EmailComposeError.unavailable("You changed the message after Holmes wrote it, so Undo would erase your edits. Use Command Z in Mail instead.")
        }
        await rollback(to: record.before, subject: record.subjectBefore, usedPaste: record.usedPaste)
        guard let restored = readCandidate(), Self.lines(restored.snapshot.body) == Self.lines(record.before) else {
            throw EmailComposeError.unavailable("Holmes could not confirm the undo. Check the Mail message.")
        }
        undoRecords.removeValue(forKey: token)
    }

    private static func rollback(to body: String, subject: String?, usedPaste: Bool) async {
        guard let current = readCandidate() else { return }
        if let subject, isSettable(current.subject) {
            AXUIElementSetAttributeValue(current.subject, kAXValueAttribute as CFString, subject as CFString)
        }
        switch MailComposeMatcher.rollback(bodyNow: current.snapshot.body, before: body,
                                           valueSettable: current.match.bodyValueSettable, usedPaste: usedPaste) {
        case .none:
            break
        case .setValue:
            AXUIElementSetAttributeValue(current.body, kAXValueAttribute as CFString, body as CFString)
        case .undoPaste:
            // Mail's own undo reverses exactly the paste. Command Z is never a send shortcut.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail",
                  focusBody(current) else { break }
            postCommandKey(0x06, to: current.processIdentifier)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Pastes into the exact body element, then restores every clipboard item.
    private static func paste(_ text: String, into candidate: Candidate) async throws {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), focusBody(candidate) else {
            throw EmailComposeError.unavailable("Mail did not move focus to the message body, so Holmes did not paste. Copy the draft instead.")
        }
        // Revalidate after focusing: the paste goes only to the same unchanged body.
        guard let validated = readCandidate(), CFEqual(validated.body, candidate.body),
              validated.snapshot.revisionKey == candidate.snapshot.revisionKey else {
            throw EmailComposeError.unavailable("The Mail composer changed before insertion.")
        }
        postCommandKey(0x09, to: candidate.processIdentifier)
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// Focuses the body, then confirms Mail's focused element really is that
    /// body, so a paste or undo can never land in To, Subject or elsewhere.
    private static func focusBody(_ candidate: Candidate) -> Bool {
        guard AXUIElementSetAttributeValue(candidate.body, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        let axApp = AXUIElementCreateApplication(candidate.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        let focused = element(axApp, kAXFocusedUIElementAttribute)
        return MailComposeMatcher.canPaste(focusedID: focused.map { CFEqual($0, candidate.body) ? 1 : 0 }, bodyID: 1)
    }

    private static func postCommandKey(_ keyCode: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private static func readCandidate() -> Candidate? {
        guard AXIsProcessTrusted(), let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let ownBundle = Bundle.main.bundleIdentifier
        guard frontmost.bundleIdentifier == "com.apple.mail" || frontmost.bundleIdentifier == ownBundle else { return nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        guard let window = element(axApp, kAXFocusedWindowAttribute),
              value(window, kAXMinimizedAttribute) as? Bool != true else { return nil }

        var elements: [Int: AXUIElement] = [:]
        var count = 0
        let labeledRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea", "AXWebArea"]
        func build(_ node: AXUIElement, depth: Int) -> MailAXNode {
            count += 1
            let id = count
            elements[id] = node
            let role = string(node, kAXRoleAttribute) ?? ""
            var copy = MailAXNode(id: id, role: role)
            if labeledRoles.contains(role) {
                copy.labels = labels(node)
                copy.value = string(node, kAXValueAttribute)
                copy.valueSettable = isSettable(node)
            } else if role == "AXStaticText" {
                copy.value = string(node, kAXValueAttribute)
            }
            guard depth < 14, count < 400 else { return copy }
            let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children.prefix(80) where count < 400 {
                copy.children.append(build(child, depth: depth + 1))
            }
            return copy
        }
        let tree = build(window, depth: 0)
        guard let match = MailComposeMatcher.match(window: tree),
              let bodyElement = elements[match.bodyID], let subjectElement = elements[match.subjectID] else { return nil }

        // Attributed text may carry attachments invisible in its .string.
        var attributedAttachment = false
        if match.bodyKind == .textArea, let attributed = value(bodyElement, kAXValueAttribute) as? NSAttributedString {
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if value != nil { attributedAttachment = true }
            }
        }
        let attachmentInWindow = MailComposeMatcher.flatten(tree).contains { $0.role == "AXAttachment" }
        let body = match.bodyText
        // Rich bodies are not fully serializable here, so refuse staging and
        // automatic generation instead of silently erasing non-text content.
        let readable = match.bodyReadable && !attributedAttachment && !attachmentInWindow
        func recipients(_ ids: [Int]) -> [String] {
            guard ids.count <= 1 else { return ["(ambiguous recipient field)"] }
            return MailComposeMatcher.recipients(ids.first.flatMap { MailComposeMatcher.node($0, in: tree) })
        }
        let from = MailComposeMatcher.flatten(tree).first {
            MailComposeMatcher.editableRoles.contains($0.role) && !$0.labels.isDisjoint(with: ["from", "from account"])
        }?.value ?? ""
        let id = "mail|\(app.processIdentifier)|\(app.launchDate?.timeIntervalSince1970 ?? 0)|\(identity(window))|\(identity(bodyElement))|\(from)"
        let snapshot = EmailComposeSnapshot(source: .accessibility, identity: id, provider: "Apple Mail",
            app: app.localizedName ?? "Mail", appBundleIdentifier: "com.apple.mail", recipients: recipients([match.toID]),
            cc: recipients(match.ccIDs), bcc: recipients(match.bccIDs),
            subject: match.subject, body: body, bodyReadable: readable,
            bodyIsEmpty: readable && EmailComposeSnapshot.isBlankBody(body), capturedAt: Date(),
            bodyRevision: body)
        return Candidate(snapshot: snapshot, match: match, body: bodyElement, subject: subjectElement,
                         processIdentifier: app.processIdentifier)
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isSettable(_ node: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func identity(_ element: AXUIElement) -> String {
        if let found = identities.first(where: { CFEqual($0.element, element) }) { return found.id }
        let id = UUID().uuidString
        identities.append((element, id))
        if identities.count > 64 { identities.removeFirst(identities.count - 64) }
        return id
    }

    private static func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        let result = value(node, attribute)
        return result as? String ?? (result as? NSAttributedString)?.string
    }
    private static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(node, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private static func labels(_ node: AXUIElement) -> Set<String> {
        var names = [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", "AXPlaceholderValue"].compactMap { string(node, $0) }
        if let label = element(node, kAXTitleUIElementAttribute) {
            names.append(string(label, kAXValueAttribute) ?? string(label, kAXTitleAttribute) ?? "")
        }
        return Set(names.map { $0.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))) })
    }
}
