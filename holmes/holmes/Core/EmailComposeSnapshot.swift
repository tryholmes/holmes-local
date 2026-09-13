import Foundation

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

    /// Full, collision-free encoding, rather than Swift's process-random hash.
    /// Capture time is deliberately excluded; a second observation can confirm it.
    var revisionKey: String {
        let fields = [source.rawValue, identity, provider, appBundleIdentifier ?? app,
                      Self.encode(recipients), Self.encode(cc), Self.encode(bcc), subject,
                      body, bodyRevision ?? "", bodyReadable ? "readable" : "unreadable", bodyIsEmpty ? "empty" : "nonempty"]
        return Self.encode(fields)
    }

    var canAutoDraft: Bool {
        !identity.isEmpty && bodyReadable && bodyIsEmpty && Self.isBlankBody(body)
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recipients.isEmpty && (recipients + cc + bcc).allSatisfy(Self.isEmailAddress)
    }

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
        return EmailComposeSnapshot(source: .browser, identity: identity, provider: provider,
                                    app: app, appBundleIdentifier: bundleIdentifier,
                                    recipients: recipients, cc: cc, bcc: bcc, subject: subject,
                                    body: body, bodyReadable: readable,
                                    bodyIsEmpty: readable && empty && isBlankBody(body), capturedAt: capturedAt,
                                    bodyRevision: dictionary["bodyRevision"] as? String)
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

enum EmailComposeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}
