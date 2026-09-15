import Foundation

/// A read only copy of one accessibility element. Apple Mail's compose window is
/// copied into this tree first, so the matching rules run (and are tested)
/// without a live app.
struct MailAXNode: Equatable {
    var id: Int
    var role: String
    var labels: Set<String> = []
    var value: String? = nil
    var valueSettable = false
    var children: [MailAXNode] = []
}

struct MailComposeMatch: Equatable {
    enum BodyKind: Equatable { case textArea, webArea }
    let subjectID: Int
    let subject: String
    let toID: Int
    let ccIDs: [Int]
    let bccIDs: [Int]
    let bodyID: Int
    let bodyKind: BodyKind
    let bodyText: String
    /// False when the body holds images, tables or attachments that plain text
    /// cannot represent; Holmes then never writes or treats it as empty.
    let bodyReadable: Bool
    /// The AX value can be set directly. Otherwise writing needs a paste.
    let bodyValueSettable: Bool
}

enum MailComposeMatcher {
    static let editableRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea"]
    static let bodyLabels: Set<String> = ["body", "message body", "message content", "messagecontentview", "message-body"]
    static let richRoles: Set<String> = ["AXImage", "AXTable", "AXAttachment"]
    static let blockRoles: Set<String> = ["AXGroup", "AXParagraph", "AXListItem", "AXHeading", "AXBlockquote"]

    static func flatten(_ root: MailAXNode) -> [MailAXNode] {
        var result: [MailAXNode] = []
        func walk(_ node: MailAXNode) {
            for child in node.children {
                result.append(child)
                walk(child)
            }
        }
        walk(root)
        return result
    }

    static func match(window: MailAXNode) -> MailComposeMatch? {
        let nodes = flatten(window)
        func controls(_ names: Set<String>) -> [MailAXNode] {
            nodes.filter { editableRoles.contains($0.role) && !$0.labels.isDisjoint(with: names) }
        }
        let subjects = controls(["subject"])
        let to = controls(["to", "to recipients"])
        // Both labeled controls establish that this is an actual compose window,
        // rather than Mail's reader pane containing arbitrary message text.
        guard subjects.count == 1, to.count == 1, let subject = subjects[0].value else { return nil }

        let textBodies = nodes.filter { ["AXTextArea", "AXTextField"].contains($0.role) && !$0.labels.isDisjoint(with: bodyLabels) }
        let body: MailAXNode
        let kind: MailComposeMatch.BodyKind
        if textBodies.count == 1 {
            body = textBodies[0]
            kind = .textArea
        } else if textBodies.isEmpty {
            // Current Mail renders the body with WebKit: an AXWebArea, usually
            // unlabeled. Prefer a labeled one; an unlabeled one must be unique.
            let webAreas = nodes.filter { $0.role == "AXWebArea" }
            let labeled = webAreas.filter { !$0.labels.isDisjoint(with: bodyLabels) }
            let candidates = labeled.isEmpty ? webAreas : labeled
            guard candidates.count == 1 else { return nil }
            body = candidates[0]
            kind = .webArea
        } else {
            return nil
        }

        let inside = flatten(body)
        let rich = inside.contains { richRoles.contains($0.role) }
        let text: String
        let hasText: Bool
        switch kind {
        case .textArea:
            text = body.value ?? ""
            hasText = body.value != nil
        case .webArea:
            if let value = body.value, !value.isEmpty {
                text = value
            } else {
                text = webAreaText(body)
            }
            hasText = true
        }
        return MailComposeMatch(subjectID: subjects[0].id, subject: subject, toID: to[0].id,
                                ccIDs: controls(["cc", "cc recipients"]).map(\.id),
                                bccIDs: controls(["bcc", "bcc recipients"]).map(\.id),
                                bodyID: body.id, bodyKind: kind, bodyText: String(text.prefix(16_000)),
                                bodyReadable: hasText && text.count <= 16_000 && !rich,
                                bodyValueSettable: body.valueSettable)
    }

    /// WebKit exposes text as static text runs grouped into blocks. Each block
    /// is a line; an empty block is a blank line, like <div><br></div>.
    static func webAreaText(_ root: MailAXNode) -> String {
        var lines: [String] = []
        var current = ""
        func walk(_ node: MailAXNode) {
            if node.role == "AXStaticText" {
                current += node.value ?? ""
                return
            }
            let block = blockRoles.contains(node.role)
            if block, !current.isEmpty {
                lines.append(current)
                current = ""
            }
            let linesBefore = lines.count
            node.children.forEach(walk)
            if block {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                } else if lines.count == linesBefore {
                    lines.append("")
                }
            }
        }
        root.children.forEach(walk)
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Addresses in a recipient field and its token children.
    static func recipients(_ field: MailAXNode?) -> [String] {
        guard let field else { return [] }
        let text = ([field] + flatten(field)).compactMap(\.value).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let pattern = #"[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let emails = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
        return emails.isEmpty ? ["(recipient address unavailable)"] : Array(Set(emails)).sorted()
    }

    enum Rollback: Equatable { case none, setValue, undoPaste }

    /// What restores the body. Command Z is sent only when Holmes's own paste
    /// changed this body; otherwise it could undo an edit of the person's.
    static func rollback(bodyNow: String, before: String, valueSettable: Bool, usedPaste: Bool) -> Rollback {
        let lines = { (text: String) in
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard lines(bodyNow) != lines(before) else { return .none }
        if valueSettable { return .setValue }
        return usedPaste ? .undoPaste : .none
    }

    /// A paste may only go where focus verifiably is: the exact body element.
    static func canPaste(focusedID: Int?, bodyID: Int) -> Bool {
        focusedID == bodyID
    }

    static func node(_ id: Int, in root: MailAXNode) -> MailAXNode? {
        if root.id == id { return root }
        return flatten(root).first { $0.id == id }
    }
}
