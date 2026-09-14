import Foundation

/// One message of the conversation a reply answers, read from the mail page.
struct EmailThreadMessage: Codable, Equatable, Sendable {
    let from: String
    let fromEmail: String
    let date: String
    let text: String
}

/// A literal reading of one composer. Missing controls are never treated as empty.
struct EmailComposeSnapshot: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case browser, accessibility }

    let source: Source
    let identity: String
    let provider: String
    let app: String
    var appBundleIdentifier: String? = nil
    let recipients: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let bodyReadable: Bool
    let bodyIsEmpty: Bool
    let capturedAt: Date
    var bodyRevision: String? = nil
    /// Text the person wrote, excluding the signature and quoted thread. nil when
    /// the reader cannot separate them (then the whole body counts as theirs).
    var userText: String? = nil
    /// True only when the reader verified that the body holds nothing but a
    /// signature and/or quoted text, so Holmes may write above the signature.
    var autoWritable: Bool? = nil
    var hasSignature = false
    var hasQuote = false
    var subjectEditable = true
    var isReply = false
    var threadSubject = ""
    /// Most recent message first.
    var thread: [EmailThreadMessage] = []
    /// Lowercased address to display name, from recipient chips.
    var recipientNames: [String: String] = [:]

    /// Full, collision-free encoding, rather than Swift's process-random hash.
    /// Capture time is deliberately excluded; a second observation can confirm it.
    var revisionKey: String {
        let fields = [source.rawValue, identity, provider, appBundleIdentifier ?? app,
                      Self.encode(recipients), Self.encode(cc), Self.encode(bcc), subject,
                      body, bodyRevision ?? "", bodyReadable ? "readable" : "unreadable", bodyIsEmpty ? "empty" : "nonempty",
                      userText ?? "", autoWritable.map { $0 ? "writable" : "protected" } ?? ""]
        return Self.encode(fields)
    }

    /// What the person typed themselves (never the signature or the quote).
    var ownText: String { userText ?? body }

    /// Nothing of the person's own is in the body: either literally empty, or
    /// verified to contain only a signature and/or quoted thread.
    var isOwnTextEmpty: Bool { autoWritable ?? bodyIsEmpty }

    /// Holmes may predict with no subject and no notes, as long as it knows who
    /// the email is for or which conversation it answers.
    var canAutoDraft: Bool {
        !identity.isEmpty && bodyReadable
            && (isOwnTextEmpty || !Self.isBlankBody(ownText))
            && (recipients + cc + bcc).allSatisfy(Self.isEmailAddress)
            && (!recipients.isEmpty || !thread.isEmpty)
    }

    /// Automatic writing never touches text the person typed.
    var canAutoWrite: Bool { canAutoDraft && isOwnTextEmpty }

    /// Replace and Insert keep the signature and quoted thread only where the
    /// reader can locate them (browser composers). Apple Mail's body text mixes
    /// them in, so a Mail body with any text offers Copy only.
    var supportsReviewedWrite: Bool { source == .browser || bodyIsEmpty }

    func isFresh(at now: Date = Date(), maximumAge: TimeInterval = 8) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= -1 && age <= maximumAge
    }

    static func isBlankBody(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || [0x200B, 0xFEFF].contains($0.value)
        }
    }

    static func isEmailAddress(_ text: String) -> Bool {
        text.range(of: #"^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$"#, options: .regularExpression) != nil
    }

    private static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Browser timestamps are milliseconds since Unix epoch. Never stamp a queued
    /// payload as fresh merely because the socket delivered it just now.
    static func browserCaptureDate(_ value: Any?, now: Date = Date()) -> Date? {
        guard let milliseconds = value as? Double, milliseconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        guard now.timeIntervalSince(date) >= -1, now.timeIntervalSince(date) <= 15 else { return nil }
        return date
    }

    static func fromBrowser(_ dictionary: [String: Any], app: String,
                            bundleIdentifier: String?, capturedAt: Date) -> EmailComposeSnapshot? {
        guard dictionary["source"] as? String == "browser",
              let identity = dictionary["identity"] as? String, !identity.isEmpty,
              let provider = dictionary["provider"] as? String,
              let recipients = dictionary["recipients"] as? [String],
              let cc = dictionary["cc"] as? [String], let bcc = dictionary["bcc"] as? [String],
              let subject = dictionary["subject"] as? String, let body = dictionary["body"] as? String,
              let readable = dictionary["bodyReadable"] as? Bool,
              let empty = dictionary["bodyIsEmpty"] as? Bool,
              let milliseconds = dictionary["capturedAt"] as? Double,
              abs(milliseconds / 1000 - capturedAt.timeIntervalSince1970) < 0.01,
              identity.count <= 2000, subject.count <= 2000, body.count <= 16_000,
              recipients.count + cc.count + bcc.count <= 100 else { return nil }
        var snapshot = EmailComposeSnapshot(source: .browser, identity: identity, provider: provider,
                                    app: app, appBundleIdentifier: bundleIdentifier,
                                    recipients: recipients, cc: cc, bcc: bcc, subject: subject,
                                    body: body, bodyReadable: readable,
                                    bodyIsEmpty: readable && empty && isBlankBody(body), capturedAt: capturedAt,
                                    bodyRevision: dictionary["bodyRevision"] as? String)
        if let own = dictionary["userText"] as? String, own.count <= 16_000 {
            snapshot.userText = own
            if let writable = dictionary["autoWritable"] as? Bool {
                snapshot.autoWritable = readable && writable && isBlankBody(own)
            }
        }
        snapshot.hasSignature = dictionary["hasSignature"] as? Bool ?? false
        snapshot.hasQuote = dictionary["hasQuote"] as? Bool ?? false
        snapshot.subjectEditable = dictionary["subjectEditable"] as? Bool ?? true
        snapshot.isReply = dictionary["isReply"] as? Bool ?? false
        snapshot.threadSubject = String((dictionary["threadSubject"] as? String ?? "").prefix(300))
        if let rows = dictionary["thread"] as? [[String: Any]] {
            snapshot.thread = rows.prefix(8).compactMap { row in
                guard let text = row["text"] as? String, !isBlankBody(text) else { return nil }
                return EmailThreadMessage(from: String((row["from"] as? String ?? "").prefix(120)),
                                          fromEmail: String((row["fromEmail"] as? String ?? "").prefix(200)).lowercased(),
                                          date: String((row["date"] as? String ?? "").prefix(80)),
                                          text: String(text.prefix(2000)))
            }
        }
        if let names = dictionary["recipientNames"] as? [String: String] {
            snapshot.recipientNames = Dictionary(uniqueKeysWithValues: names.prefix(50).map {
                ($0.key.lowercased(), String($0.value.prefix(120)))
            })
        }
        return snapshot
    }

    /// Exact expected values cross the bridge. The browser compares fields directly
    /// before touching the body, avoiding cross-language hash/normalization drift.
    var browserExpectation: [String: Any] {
        var result: [String: Any] = ["identity": identity, "recipients": recipients, "cc": cc, "bcc": bcc,
         "subject": subject, "body": body, "bodyReadable": bodyReadable,
         "bodyIsEmpty": bodyIsEmpty]
        if let bodyRevision { result["bodyRevision"] = bodyRevision }
        return result
    }
}

/// How a draft enters the composer. None of them ever sends.
enum EmailWriteMode: String, Sendable {
    /// Prediction: only into a body holding nothing of the person's own, never while typing.
    case auto
    /// Card "Replace body": replaces the person's text, keeps signature and quote.
    case replace
    /// Card "Insert": adds below the person's text, above signature and quote.
    case insert
}

/// Proof of a verified write, with what one click undo needs.
struct EmailWriteReceipt: Equatable, Sendable {
    let undoToken: String?
    let subjectFilled: Bool
}

enum EmailComposeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}
