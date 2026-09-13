import Foundation

@MainActor private final class HeldEmailValue<Value> {
    var started = false
    var cancelled = false
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                started = true
            }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
    }
    func release(_ value: Value) {
        let pending = continuation
        continuation = nil
        precondition(pending != nil)
        pending?.resume(returning: value)
    }
}

@MainActor private final class DraftFixture {
    var ready = true
    var generated = 0
    var refreshed = 0
    var published: [PreparedEmailDraft] = []
    var modelOwners: [UUID?] = []
    var generator: (EmailDraftInput) async throws -> String = { _ in "Hi,\nI'm running late. I'm sorry for the delay." }
    var refresher: (EmailComposeSnapshot) async -> EmailComposeSnapshot? = { $0 }
    lazy var session = EmailDraftSession(dependencies: .init(
        isReady: { self.ready },
        notReadyMessage: { "The local model is not downloaded" },
        generate: { input, _ in
            self.generated += 1
            self.modelOwners.append(WorkActivityScope.id)
            return try await self.generator(input)
        },
        refresh: { expected in
            self.refreshed += 1
            return await self.refresher(expected)
        },
        publish: { self.published.append($0) }
    ))
}

@main
struct EmailDraftingTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func json(_ body: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: ["body": body]), as: UTF8.self)
        }

        let validBodies = [
            "Hi,\nI'm running late. I'm sorry for the delay.",
            "Please open the attached report before our meeting.",
            "You can open the document using the link I sent.",
            "I can't send the signed document until Friday.",
            "I am unable to access the shared folder.",
            "To write the report, I need the figures.",
            "Here is the draft of the report for review."
        ]
        for body in validBodies {
            let parsed = try EmailDraftText.body(from: json(body))
            expect(parsed == body, "Legitimate email body must not be mistaken for model instructions: \(body)")
        }
        let invalidBodies = [
            "", "Sure, here's a draft email:\nHi there",
            "You should write an email explaining your delay.",
            "Please open your email app and type the reply.",
            "I cannot access your email application.",
            "I can't draft an email for you.",
            "I cannot send email on your behalf.",
            "To draft an email, open the compose window.",
            "As an AI, I cannot interact with your computer.",
            "Hi [Recipient Name], I'm running late. Thanks, [Your Name]",
            "Hi [Boss's Name], I'm running late.", "Hi [Boss’s Name], I'm running late.",
            "Hi, I will arrive at [arrival time].",
            "Subject: Running late\nHi there", String(repeating: "a", count: 8001)
        ]
        for body in invalidBodies {
            do {
                _ = try EmailDraftText.body(from: json(body))
                fatalError("Unusable output was accepted: \(body.prefix(120))")
            } catch is EmailDraftTextError { checks += 1 }
        }
        for raw in ["Here's the email you can send.", "```json\n{\"body\":\"Hi\"}\n```", "{\"body\":12}", "{\"answer\":\"Hi\"}"] {
            do {
                _ = try EmailDraftText.body(from: raw)
                fatalError("Malformed/non-contract output must fail")
            } catch is EmailDraftTextError { checks += 1 }
        }

        for request in ["Write an email saying I'm running late", "Draft an email: I'm going to be late", "Write an email, I'm gonna be late"] {
            expect(EmailDraftInput(instruction: request, compose: nil).hasContent, "Terminal lateness phrase supplies its own topic")
        }
        expect(!EmailDraftInput(instruction: "draft this for me", compose: nil).hasContent, "A bare pronoun cannot supply missing email facts")
        expect(!EmailDraftInput(instruction: "draft an email about ", compose: nil).hasContent, "An empty topic marker is not content")
        let literal = EmailDraftInput(instruction: "Rewrite \"this\"\npolitely", compose: nil,
                                      subject: "Quote: \"hello\"", recipient: "jamie@example.com", sourceBody: "First\nSecond")
        let fields = try JSONSerialization.jsonObject(with: Data(literal.modelPrompt.utf8)) as! [String: String]
        expect(fields["existing_text"] == "First\nSecond" && fields["subject"] == "Quote: \"hello\"", "Prompt preserves literal field boundaries and newlines")
        expect(fields["user_request"] == literal.instruction, "User instruction is represented independently of email data")

        let input = EmailDraftInput(instruction: "Draft this email", compose: snapshot())
        var repairs: [String] = []
        let repaired = try await EmailDraftText.generate(input: input) { system, _ in
            repairs.append(system)
            return repairs.count == 1 ? "Open Mail and click compose." : json(validBodies[0])
        }
        expect(repaired == validBodies[0] && repairs.count == 2, "Raw teaching prose receives one repair before publication")
        expect(repairs[1].contains("previous response was not a usable email body"), "Repair tells the model to write the body itself")
        var invalidAttempts = 0
        do {
            _ = try await EmailDraftText.generate(input: input) { _, _ in
                invalidAttempts += 1
                return "Open the compose window."
            }
            fatalError("Repeated invalid output must fail")
        } catch is EmailDraftTextError { checks += 1 }
        expect(invalidAttempts == 2, "Malformed model replies must not cause an unbounded repair loop")

        // Stable, exact headers must survive a dwell and a fresh second read.
        let now = Date()
        var trigger = EmailComposeTrigger()
        let original = snapshot(now: now)
        expect(trigger.observe(original, now: now) == EmailComposeTrigger.dwell, "First stable headers start a dwell")
        expect(!trigger.claim(original, now: now.addingTimeInterval(0.5)), "Automatic draft cannot claim before dwell")
        let afterOne = snapshot(now: now.addingTimeInterval(1))
        expect(trigger.observe(afterOne, now: now.addingTimeInterval(1)) == 0.5, "Unchanged observation does not restart the timer")
        let stable = snapshot(now: now.addingTimeInterval(1.5))
        expect(trigger.claim(stable, now: now.addingTimeInterval(1.5)), "Fresh unchanged headers may claim after dwell")
        expect(!trigger.claim(stable, now: now.addingTimeInterval(1.5)), "Duplicate timer cannot claim the same attempt")
        expect(trigger.observe(snapshot(now: now.addingTimeInterval(10)), now: now.addingTimeInterval(10)) == nil, "Failed attempts have a retry cooldown")
        expect(trigger.observe(snapshot(now: now.addingTimeInterval(62)), now: now.addingTimeInterval(62)) == 0, "A failure becomes eligible again after the bounded cooldown")
        expect(trigger.claim(snapshot(now: now.addingTimeInterval(62)), now: now.addingTimeInterval(62)), "Retry claims after cooldown")
        trigger.succeeded(original, now: now.addingTimeInterval(62))
        expect(trigger.observe(snapshot(now: now.addingTimeInterval(80)), now: now.addingTimeInterval(80)) == nil, "A completed unchanged email is not drafted repeatedly")

        var changing = EmailComposeTrigger()
        _ = changing.observe(original, now: now)
        let changedHeader = snapshot(subject: "Different subject", now: now.addingTimeInterval(1))
        expect(changing.observe(changedHeader, now: now.addingTimeInterval(1)) == EmailComposeTrigger.dwell, "Editing a header restarts dwell")
        expect(!changing.claim(snapshot(now: now.addingTimeInterval(2)), now: now.addingTimeInterval(2)), "An old header's timer cannot claim the new email")
        expect(changing.observe(snapshot(body: "User is writing", now: now.addingTimeInterval(2)), now: now.addingTimeInterval(2)) == nil, "Existing body blocks automatic drafting")
        expect(!changing.claim(snapshot(subject: "Different subject", now: now.addingTimeInterval(3)), now: now.addingTimeInterval(3)), "Typing in the body cancels a pending automatic trigger")
        _ = changing.observe(original, now: now)
        expect(changing.observe(nil, now: now) == nil, "Leaving the compose window cancels dwell")
        expect(!changing.claim(snapshot(now: now.addingTimeInterval(2)), now: now.addingTimeInterval(2)), "Navigation cannot leave an old timer eligible")
        expect(!snapshot(recipients: []).canAutoDraft, "Automatic generation requires a resolved recipient")
        expect(!snapshot(readable: false).canAutoDraft, "Unreadable body is never assumed empty")
        expect(changing.observe(snapshot(now: now.addingTimeInterval(-20)), now: now) == nil, "Stale header observations cannot start drafting")

        let center = WorkActivityCenter.shared
        center.invalidateAll()
        let missingModel = DraftFixture()
        missingModel.ready = false
        let missing = await missingModel.session.request(input, origin: .background)
        expect(missing == .failed("The local model is not downloaded"), "Model readiness failure preserves its reason")
        expect(center.completion?.outcome == .failure && center.completion?.origin == .background, "Automatic model failure gets an owned visible outcome")
        expect(center.activeCount == 0 && !missingModel.session.isRunning && missingModel.generated == 0, "Early model failure releases all ownership without generation")

        let noContext = DraftFixture()
        let noContent = await noContext.session.request(EmailDraftInput(instruction: "draft this", compose: nil), origin: .user)
        guard case .needsContext = noContent else { fatalError("Missing context must remain typed") }
        expect(center.completion?.outcome == .failure && center.activeCount == 0, "Missing content also completes its owned activity visibly")
        expect(noContext.generated == 0, "No facts means no model request")

        let successful = DraftFixture()
        let parentID = center.begin(title: "Voice parent", origin: .user)
        var parentWasCancelled = false
        center.setCancellationHandler(parentID) { parentWasCancelled = true }
        let success = await WorkActivityScope.$id.withValue(parentID) {
            await successful.session.request(input, origin: .user)
        }
        guard case .ready = success else { fatalError("Expected draft") }
        expect(successful.published.count == 1 && successful.refreshed == 1, "A stable composer publishes one reviewed draft after refresh")
        expect(successful.published[0].input == input && successful.published[0].isUserInitiated, "Published draft retains the exact input and explicit origin")
        expect(successful.modelOwners == [parentID], "Model generation inherits the caller's activity")
        expect(center.isActive(parentID), "Nested draft success cannot finish its caller's activity")
        center.cancel(parentID)
        expect(parentWasCancelled, "Draft session must never replace an inherited cancellation handler")

        // Header, body, identity, and navigation changes during generation must
        // invalidate work, even if the provider returns a late successful body.
        let variants: [EmailComposeSnapshot?] = [
            snapshot(subject: "Changed"), snapshot(recipients: ["other@example.com"]),
            snapshot(cc: ["copy@example.com"]), snapshot(bcc: ["hidden@example.com"]),
            snapshot(body: "My own draft"), snapshot(identity: "another-tab/compose"),
            snapshot(bodyRevision: "edited-and-cleared"), nil
        ]
        for changed in variants {
            let fixture = DraftFixture()
            let held = HeldEmailValue<String>()
            fixture.generator = { _ in await held.wait() }
            let work = Task { await fixture.session.request(input, origin: .user) }
            await eventually { held.started }
            fixture.session.noteContext(changed)
            await eventually { held.cancelled }
            held.release("Late model body")
            let outcome = await work.value
            guard case .needsContext = outcome else { fatalError("Changed email must explain why drafting stopped") }
            expect(fixture.published.isEmpty, "Changed email cannot receive the old generated draft")
            expect(center.activeCount == 0 && center.completion?.outcome == .failure, "Changed context finishes its own visible outcome")
        }

        // Refresh is an asynchronous boundary too: cancellation while the second
        // read is pending must suppress a result even if it later matches.
        let refreshing = DraftFixture()
        let heldRefresh = HeldEmailValue<EmailComposeSnapshot?>()
        refreshing.refresher = { _ in await heldRefresh.wait() }
        let duringRefresh = Task { await refreshing.session.request(input, origin: .background) }
        await eventually { heldRefresh.started }
        refreshing.session.cancel()
        await eventually { heldRefresh.cancelled }
        let revisionAfterCancel = center.revision
        heldRefresh.release(snapshot())
        let refreshOutcome = await duringRefresh.value
        expect(refreshOutcome == .cancelled, "Cancelling a held refresh returns cancellation")
        expect(refreshing.published.isEmpty && center.revision == revisionAfterCancel, "Late refresh cannot publish or revive cancelled work")

        let refreshChanged = DraftFixture()
        refreshChanged.refresher = { _ in snapshot(body: "New body") }
        let revalidated = await refreshChanged.session.request(input, origin: .user)
        guard case .needsContext = revalidated else { fatalError("A changed fresh read must be refused") }
        expect(refreshChanged.published.isEmpty, "Final revalidation catches a body edit even without an observation event")

        for latest in [nil, snapshot(now: Date().addingTimeInterval(-30))] as [EmailComposeSnapshot?] {
            let unavailable = DraftFixture()
            unavailable.refresher = { _ in latest }
            let outcome = await unavailable.session.request(input, origin: .user)
            guard case .needsContext = outcome else { fatalError("A missing or stale second read must stop publication") }
            expect(unavailable.published.isEmpty && center.activeCount == 0, "Missing/stale final context cannot publish an unverified target")
        }

        let old = HeldEmailValue<String>()
        let newer = HeldEmailValue<String>()
        let superseding = DraftFixture()
        superseding.generator = { input in
            input.instruction == "Old request" ? await old.wait() : await newer.wait()
        }
        let oldTask = Task { await superseding.session.request(EmailDraftInput(instruction: "Old request", compose: snapshot()), origin: .background) }
        await eventually { old.started }
        let newTask = Task { await superseding.session.request(EmailDraftInput(instruction: "New request", compose: snapshot()), origin: .user) }
        await eventually { newer.started && old.cancelled }
        let newOwner = center.selectedActivity?.id
        old.release("Old draft")
        let oldOutcome = await oldTask.value
        expect(oldOutcome == .cancelled, "Superseded request returns cancellation")
        expect(center.activeCount == 1 && center.selectedActivity?.id == newOwner, "Old completion cannot hide the new request")
        expect(superseding.session.isRunning && superseding.published.isEmpty, "Old cleanup cannot clear the newer session")
        newer.release("New draft")
        guard case .ready = await newTask.value else { fatalError("New request must finish") }
        expect(superseding.published.map(\.body) == ["New draft"], "Only the latest explicit draft may publish")
        expect(center.activeCount == 0, "Completed supersession leaves no leaked activity")

        let sleeping = DraftFixture()
        let beforeSleep = HeldEmailValue<String>()
        sleeping.generator = { _ in await beforeSleep.wait() }
        let sleepTask = Task { await sleeping.session.request(input, origin: .background) }
        await eventually { beforeSleep.started }
        center.invalidateAll()
        await eventually { beforeSleep.cancelled }
        let afterWakeID = center.begin(title: "After wake")
        beforeSleep.release("Result from before sleep")
        let sleepOutcome = await sleepTask.value
        expect(sleepOutcome == .cancelled, "Lifecycle invalidation cancels the owned generation")
        expect(center.selectedActivity?.id == afterWakeID && center.completion == nil && sleeping.published.isEmpty, "Pre-sleep generation cannot replace post-wake work")
        center.cancel(afterWakeID)
        print("Passed \(checks) email draft content, trigger, and lifecycle checks")
    }

    private static func snapshot(subject: String = "I'm gonna be late", recipients: [String] = ["jamie@example.com"],
                                 cc: [String] = [], bcc: [String] = [], body: String = "", readable: Bool = true,
                                 identity: String = "tab-1/compose-1", bodyRevision: String? = nil,
                                 now: Date = Date()) -> EmailComposeSnapshot {
        EmailComposeSnapshot(source: .browser, identity: identity, provider: "gmail", app: "Chrome",
                             recipients: recipients, cc: cc, bcc: bcc, subject: subject, body: body,
                             bodyReadable: readable, bodyIsEmpty: body.isEmpty && readable, capturedAt: now,
                             bodyRevision: bodyRevision)
    }

    @MainActor private static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for email draft lifecycle transition")
    }
}
