import AppKit
import ApplicationServices
import Foundation

/// Apple Mail's labeled AX fields. No OCR, clipboard, focus guessing or keystrokes.
@MainActor
enum MailComposeReader {
    private struct Candidate {
        let snapshot: EmailComposeSnapshot
        let body: AXUIElement
    }
    private static var identities: [(element: AXUIElement, id: String)] = []

    static func readCurrent() -> EmailComposeSnapshot? { readCandidate()?.snapshot }

    static func refreshEmailComposeContext() -> LiveContext? {
        guard let compose = readCurrent() else { return nil }
        let reading = ScreenReading(appName: compose.app, windowTitle: compose.subject,
                                    bodyText: compose.body, emailCompose: compose)
        return LiveContextBuilder.fromAccessibility(reading: reading, focused: nil)
    }

    static func stageEmailDraft(_ text: String, expected: EmailComposeSnapshot) async throws -> Bool {
        guard expected.source == .accessibility, expected.appBundleIdentifier == "com.apple.mail",
              expected.bodyReadable, !EmailComposeSnapshot.isBlankBody(text), text.count <= 16_000,
              let current = readCandidate(), current.snapshot.revisionKey == expected.revisionKey else {
            throw EmailComposeError.unavailable("The Mail composer or its contents changed. Refresh the draft before inserting.")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(current.body, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw EmailComposeError.unavailable("Mail does not expose a writable message body. Copy the draft instead.")
        }
        // Re-read after the AX capability query. The setter below addresses only
        // this exact body element; no app activation or keyboard paste is involved.
        guard let validated = readCandidate(), CFEqual(validated.body, current.body),
              validated.snapshot.revisionKey == expected.revisionKey else {
            throw EmailComposeError.unavailable("The Mail composer changed before insertion.")
        }
        guard AXUIElementSetAttributeValue(current.body, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw EmailComposeError.unavailable("Mail refused to insert the draft. Copy it instead.")
        }
        guard let after = readCandidate(), after.snapshot.identity == expected.identity,
              after.snapshot.subject == expected.subject, after.snapshot.recipients == expected.recipients,
              after.snapshot.cc == expected.cc, after.snapshot.bcc == expected.bcc,
              after.snapshot.body == text else {
            throw EmailComposeError.unavailable("Mail did not confirm the inserted draft. Check the composer before retrying.")
        }
        return true
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
        let nodes = descendants(window)
        let editableRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea"]
        func controls(_ names: Set<String>) -> [AXUIElement] {
            nodes.filter { node in
                editableRoles.contains(string(node, kAXRoleAttribute) ?? "")
                    && !labels(node).isDisjoint(with: names)
            }
        }
        let subjects = controls(["subject"])
        let to = controls(["to", "to recipients"])
        // Both labeled controls establish that this is an actual compose window,
        // rather than Mail's reader pane containing arbitrary message text.
        guard subjects.count == 1, to.count == 1,
              let subject = string(subjects[0], kAXValueAttribute) else { return nil }
        let bodies = nodes.filter { node in
            let role = string(node, kAXRoleAttribute) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { return false }
            return !labels(node).isDisjoint(with: ["body", "message body", "message content", "messagecontentview", "message-body"])
        }
        guard bodies.count == 1 else { return nil }
        let bodyElement = bodies[0]
        let rawBody = string(bodyElement, kAXValueAttribute)
        let bodyNodes = descendants(bodyElement)
        let hasRichObjects = bodyNodes.contains {
            ["AXImage", "AXTable", "AXAttachment", "AXWebArea"].contains(string($0, kAXRoleAttribute) ?? "")
        } || nodes.contains { string($0, kAXRoleAttribute) == "AXAttachment" }
        // Attributed text may carry attachments invisible in its .string.
        let attributed = value(bodyElement, kAXValueAttribute) as? NSAttributedString
        var attributedAttachment = false
        attributed?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed?.length ?? 0)) { value, _, _ in
            if value != nil { attributedAttachment = true }
        }
        let body = rawBody ?? ""
        // Rich AX bodies are not fully serializable here, so refuse staging and
        // auto-generation instead of silently erasing non-text content.
        let readable = rawBody != nil && body.count <= 16_000 && !hasRichObjects && !attributedAttachment
        func recipients(_ fields: [AXUIElement]) -> [String] {
            guard fields.count <= 1 else { return ["(ambiguous recipient field)"] }
            guard let field = fields.first else { return [] }
            let values = ([field] + descendants(field)).compactMap { string($0, kAXValueAttribute) }
            let text = values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let pattern = #"[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let emails = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]).lowercased() }
            }
            return emails.isEmpty ? ["(recipient address unavailable)"] : Array(Set(emails)).sorted()
        }
        let from = controls(["from", "from account"]).first.flatMap { string($0, kAXValueAttribute) } ?? ""
        let id = "mail|\(app.processIdentifier)|\(app.launchDate?.timeIntervalSince1970 ?? 0)|\(identity(window))|\(identity(bodyElement))|\(from)"
        let snapshot = EmailComposeSnapshot(source: .accessibility, identity: id, provider: "Apple Mail",
            app: app.localizedName ?? "Mail", appBundleIdentifier: "com.apple.mail", recipients: recipients(to),
            cc: recipients(controls(["cc", "cc recipients"])), bcc: recipients(controls(["bcc", "bcc recipients"])),
            subject: subject, body: String(body.prefix(16_000)), bodyReadable: readable,
            bodyIsEmpty: readable && EmailComposeSnapshot.isBlankBody(body), capturedAt: Date(),
            bodyRevision: body)
        return Candidate(snapshot: snapshot, body: bodyElement)
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
    private static func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth < 12, result.count < 180 else { return }
            let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children.prefix(40) {
                guard result.count < 180 else { break }
                result.append(child)
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return result
    }
}
