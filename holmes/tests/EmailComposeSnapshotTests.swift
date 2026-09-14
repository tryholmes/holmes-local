import Foundation

@main struct EmailComposeSnapshotTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(identity: String = "tab1/document1/composer1", recipient: String = "boss@example.test",
                    subject: String = "I'm gonna be late", body: String = "", readable: Bool = true,
                    empty: Bool = true, date: Date? = nil) -> EmailComposeSnapshot {
            EmailComposeSnapshot(source: .browser, identity: identity, provider: "Gmail", app: "Chrome",
                recipients: [recipient], cc: [], bcc: [], subject: subject, body: body,
                bodyReadable: readable, bodyIsEmpty: empty, capturedAt: date ?? now)
        }
        let base = sample()
        precondition(base.canAutoDraft)
        precondition(sample(subject: "", body: "I am sick", empty: false).canAutoDraft)
        precondition(sample(body: "I am sick", empty: false).canAutoDraft)
        // Prediction needs only a recipient or a thread: an empty subject is fine.
        precondition(sample(subject: "").canAutoDraft && sample(subject: " \n").canAutoWrite)
        for bad in [sample(recipient: "unfinished"), sample(readable: false), sample(empty: false), sample(identity: "")] {
            precondition(!bad.canAutoDraft)
        }
        var noRecipient = EmailComposeSnapshot(source: .browser, identity: "tab1/document1/composer1", provider: "Gmail", app: "Chrome",
            recipients: [], cc: [], bcc: [], subject: "", body: "", bodyReadable: true, bodyIsEmpty: true, capturedAt: now)
        precondition(!noRecipient.canAutoDraft)
        noRecipient.thread = [EmailThreadMessage(from: "Dana", fromEmail: "dana@example.test", date: "", text: "Can we meet?")]
        precondition(noRecipient.canAutoDraft, "A thread alone is enough to predict a reply")
        // A signature or quoted thread is not the person's own text.
        var signed = sample(body: "--\nAlex Rivera", empty: false)
        signed.userText = ""
        signed.autoWritable = true
        signed.hasSignature = true
        precondition(signed.canAutoWrite && signed.ownText.isEmpty)
        var typed = signed
        typed.userText = "Quick note"
        typed.autoWritable = false
        precondition(typed.canAutoDraft && !typed.canAutoWrite && typed.revisionKey != signed.revisionKey)
        precondition(sample(body: " \n\u{00a0}\u{200b}").canAutoDraft)
        precondition(base.revisionKey == sample(date: now.addingTimeInterval(1)).revisionKey)
        for changed in [sample(identity: "tab2/document2/composer1"), sample(recipient: "other@example.test"),
                        sample(subject: "New subject"), sample(body: "typed"), sample(readable: false)] {
            precondition(changed.revisionKey != base.revisionKey)
        }
        precondition(base.isFresh(at: now.addingTimeInterval(7)))
        precondition(!base.isFresh(at: now.addingTimeInterval(9)))
        precondition(!sample(date: now.addingTimeInterval(2)).isFresh(at: now))
        precondition(EmailComposeSnapshot.browserCaptureDate(now.timeIntervalSince1970 * 1000, now: now) == now)
        precondition(EmailComposeSnapshot.browserCaptureDate(now.addingTimeInterval(-20).timeIntervalSince1970 * 1000, now: now) == nil)
        precondition(EmailComposeSnapshot.browserCaptureDate(now.addingTimeInterval(5).timeIntervalSince1970 * 1000, now: now) == nil)
        precondition(EmailComposeSnapshot.browserCaptureDate(nil, now: now) == nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
        let decoded = EmailComposeSnapshot.fromBrowser(raw, app: "Chrome", bundleIdentifier: nil, capturedAt: now)
        precondition(decoded == base)
        precondition(EmailComposeSnapshot.fromBrowser(raw, app: "Chrome", bundleIdentifier: nil, capturedAt: now.addingTimeInterval(1)) == nil)
        var rich = base; rich.bodyRevision = "<img src=one>"
        var changedRich = rich; changedRich.bodyRevision = "<img src=two>"
        precondition(rich.revisionKey != changedRich.revisionKey)
        precondition(rich.browserExpectation["bodyRevision"] as? String == "<img src=one>")
        print("Email compose snapshot: readiness, exact revisions, source timestamps and wire round-trip checks passed")
    }
}
