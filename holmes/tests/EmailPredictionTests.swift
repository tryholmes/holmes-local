import Foundation

// Deterministic checks for the prediction prompt, cleanup, grounding, action
// validation and the single repair retry. No model, browser or calendar access.
@main
struct EmailPredictionTests {
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        // Sunday, September 13 2026, 10:30 local time.
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10, minute: 30))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        func compose(subject: String? = nil, notes: String = "", thread: [EmailThreadMessage] = [],
                     editable: Bool = true) -> EmailComposeSnapshot {
            // Replies normally carry "Re:"; new emails start with an empty subject.
            let subject = subject ?? (thread.isEmpty ? "" : "Re: Budget meeting")
            var snapshot = EmailComposeSnapshot(source: .browser, identity: "tab/composer", provider: "Gmail", app: "Chrome",
                recipients: ["dana@example.com"], cc: [], bcc: [], subject: subject, body: notes,
                bodyReadable: true, bodyIsEmpty: notes.isEmpty, capturedAt: now)
            snapshot.recipientNames = ["dana@example.com": "Dana Lee"]
            snapshot.thread = thread
            snapshot.isReply = !thread.isEmpty
            snapshot.subjectEditable = editable
            snapshot.userText = notes
            snapshot.autoWritable = notes.isEmpty
            return snapshot
        }
        func context(_ snapshot: EmailComposeSnapshot, calendar: [EmailCalendarBlock]? = nil) -> EmailPredictionContext {
            var result = EmailPredictionContext(compose: snapshot)
            result.now = now
            result.timeZone = zone
            if let calendar {
                result.calendarAvailable = true
                result.calendar = calendar
            }
            return result
        }
        func answer(_ fields: [String: Any]) -> String {
            var all: [String: Any] = ["subject": "", "event_title": "", "event_start": "", "event_minutes": 0, "follow_up_days": 0]
            fields.forEach { all[$0.key] = $0.value }
            return String(decoding: try! JSONSerialization.data(withJSONObject: all), as: UTF8.self)
        }
        let scheduling = [EmailThreadMessage(from: "Dana Lee", fromEmail: "dana@example.com", date: "Sep 12",
                                             text: "Could we meet about the budget? I can do Tuesday at 2pm or Wednesday at 10am.")]

        // Cleanup: preambles, trailing chatter and sign offs never reach the composer.
        let cleaned = [
            ("Here's a polite email you can send:\n\nHi Dana,\n\nThanks for the update.\n\nBest,\nAlex", "Hi Dana,\n\nThanks for the update."),
            ("Certainly!\nHi Dana,\n\nSounds good.", "Hi Dana,\n\nSounds good."),
            ("Sure! Here's a draft reply:\n\nHi Dana,\n\nWednesday works.", "Hi Dana,\n\nWednesday works."),
            ("Here is a short, friendly response to Dana:\nHi Dana,\n\nWednesday works.", "Hi Dana,\n\nWednesday works."),
            ("Hi Dana,\n\nSee you then.\n\nLet me know if you'd like any changes to the tone.", "Hi Dana,\n\nSee you then."),
            ("Hi Dana,\n\nThanks!\n\nBest regards,\n[Your Name]", "Hi Dana,\n\nThanks!"),
            ("Hi Dana,\n\nThat works.\n\nThanks, Alex", "Hi Dana,\n\nThat works."),
            ("Hi Dana,\n\nThat works.\n\nCheers", "Hi Dana,\n\nThat works."),
            ("**Hi Dana,**\n\nThat works.", "Hi Dana,\n\nThat works.")
        ]
        for (raw, expected) in cleaned {
            expect(EmailBodySanitizer.clean(raw).body == expected, "Cleanup must produce only the email: \(raw.prefix(40))")
        }
        let legitimate = "Hi Dana,\n\nLet me know if Tuesday works for you."
        expect(EmailBodySanitizer.clean(legitimate).body == legitimate, "A real request to the recipient is not treated as chatter")
        let withSubject = EmailBodySanitizer.clean("Subject: Budget numbers\n\nHi Dana,\n\nHere they are.")
        expect(withSubject.subject == "Budget numbers" && withSubject.body == "Hi Dana,\n\nHere they are.", "A subject header in the body becomes the subject")
        expect(!EmailBodySanitizer.problems("Hi [Name],\n\nThanks for the update.").isEmpty, "Placeholders are rejected")
        expect(!EmailBodySanitizer.problems("As an AI language model I cannot send email.").isEmpty, "Meta answers are rejected")
        expect(EmailBodySanitizer.problems("Hi Dana,\n\nThanks for the update.").isEmpty, "A plain email has no problems")

        // Grounding: no invented times, days, amounts or links.
        let reply = context(compose(thread: scheduling))
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nWednesday at 10am works for me.", context: reply).isEmpty, "Times from the thread are grounded")
        let invented = EmailGrounding.ungrounded("Hi Dana,\n\nThursday at 4pm works for me.", context: reply)
        expect(invented.contains("4pm") && invented.contains("Thursday"), "An invented day and time are flagged without a calendar")
        let busyTuesday = [EmailCalendarBlock(title: "Dentist", start: at(15, 13, 30), end: at(15, 15), isAllDay: false)]
        let withCalendar = context(compose(thread: [EmailThreadMessage(from: "Dana Lee", fromEmail: "dana@example.com", date: "", text: "When are you free this week?")]), calendar: busyTuesday)
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nI'm free Thursday at 11am.", context: withCalendar).isEmpty, "A free calendar slot may be offered")
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nI'm free Tuesday at 2pm.", context: withCalendar) == ["2pm"], "A busy calendar slot is not free to offer")
        let pricing = context(compose(thread: [EmailThreadMessage(from: "Dana Lee", fromEmail: "dana@example.com", date: "", text: "The quote is $450 for 3 seats.")]))
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nThe $450 quote works.", context: pricing).isEmpty, "Amounts from the thread are grounded")
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nCould you do $400 instead?", context: pricing) == ["$400"], "An invented amount is flagged")
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nThe notes are at https://example.com/notes.", context: pricing) == ["https://example.com/notes"], "An invented link is flagged")
        expect(EmailGrounding.ungrounded("Hi Dana,\n\nLet's plan the 2026 budget.", context: pricing).isEmpty, "The current year is not an invented number")

        // Actions come from the structured fields and are validated against the email.
        switch EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nWednesday at 10am works for me. See you then.",
                                                   "event_title": "Budget sync", "event_start": "2026-09-16 10:00", "event_minutes": 30]),
                                           context: context(compose(thread: scheduling), calendar: busyTuesday)) {
        case .success(let prediction):
            expect(prediction.actions == [.calendarEvent(title: "Budget sync", start: at(16, 10), minutes: 30)], "An accepted time becomes a calendar candidate")
            expect(prediction.subject == nil || prediction.subject?.isEmpty == false, "Subject handling does not break a reply")
        case .failure(let rejection): fatalError("Valid scheduling reply rejected: \(rejection.issues)")
        }
        let declined = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nTuesday at 2pm doesn't work for me. I'll check other times.",
                                                           "subject": "Budget meeting", "event_start": "2026-09-15 14:00", "event_minutes": 30]),
                                                    context: context(compose(thread: scheduling), calendar: busyTuesday))
        if case .success(let prediction) = declined {
            expect(prediction.actions.isEmpty, "A declined time is never offered as an event")
        } else { fatalError("Declining reply should parse") }
        // Availability claims must match the calendar, and need one at all.
        let noCalendarIssues = EmailPredictionParser.availabilityIssues("Hi Dana,\n\nWednesday at 10am works for me.", context: reply)
        expect(noCalendarIssues.count == 1 && noCalendarIssues[0].contains("calendar is not available"), "Without calendar access the email may not claim the user is free")
        let mixed = context(compose(thread: scheduling), calendar: busyTuesday)
        expect(EmailPredictionParser.availabilityIssues("Hi Dana,\n\nTuesday at 2pm doesn't work, but Wednesday at 10am works for me.", context: mixed).isEmpty,
               "Declining a busy slot and accepting a free one in one sentence is consistent")
        expect(EmailPredictionParser.availabilityIssues("Hi Dana,\n\nTuesday at 2pm works for me.", context: mixed).first?.contains("busy") == true, "Accepting a busy slot is rejected")
        expect(EmailPredictionParser.availabilityIssues("Hi Dana,\n\nI'm busy Wednesday at 10am.", context: mixed).first?.contains("free") == true, "Inventing a conflict at a free time is rejected")
        expect(EmailGrounding.mentionedWeekdays(in: "¿puedes enviarlo antes del viernes?", context: reply).all == [5], "Weekdays in other languages are recognized")
        expect(EmailPredictionParser.validatedActions(["follow_up_days": 0], body: "Hi Omar,\n\nI'd appreciate it if you could introduce me to Kate.", context: reply) == [.followUp(days: 3)],
               "A direct request gets a follow up even when the model left the field at 0")
        expect(EmailPredictionParser.validatedActions(["follow_up_days": 3], body: "Hi,\n\nThanks for the reminder. Let me know if you need anything else.", context: reply).isEmpty,
               "Offering help is not waiting for a reply")
        let conflicted = context(compose(thread: scheduling), calendar: busyTuesday)
        if case .failure(let rejection) = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nTuesday at 2pm works for me.", "subject": "Budget",
                                                                              "event_start": "2026-09-15 14:00", "event_minutes": 30]), context: conflicted) {
            expect(rejection.issues.contains { $0.contains("busy") }, "Accepting a busy slot is rejected before any event is offered")
        } else { fatalError("Accepting a busy slot must be rejected") }
        if case .success(let prediction) = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nCould you send the Q3 numbers?", "subject": "Q3 numbers", "follow_up_days": 3]),
                                                                       context: context(compose())) {
            expect(prediction.actions == [.followUp(days: 3)] && prediction.subject == "Q3 numbers", "A request gets a follow up candidate and the empty subject is filled")
        } else { fatalError("Request email should parse") }
        if case .success(let prediction) = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nThanks for the update.", "subject": "Thanks", "follow_up_days": 3]),
                                                                       context: context(compose())) {
            expect(prediction.actions.isEmpty, "An email that asks nothing gets no follow up")
        } else { fatalError("Thank you email should parse") }
        if case .success(let prediction) = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nThanks for the update.", "subject": "Something else"]),
                                                                       context: context(compose(subject: "My own subject"))) {
            expect(prediction.subject == nil, "A subject the user wrote is never replaced")
        } else { fatalError("Existing subject email should parse") }
        if case .failure(let rejection) = EmailPredictionParser.parse(answer(["body": "Hi Dana,\n\nThanks for the update."]), context: context(compose())) {
            expect(rejection.onlySubjectMissing, "A missing subject is a repairable issue on its own")
        } else { fatalError("Missing subject should be reported") }

        // Prompt: sources are budgeted and newest thread messages come first.
        let longThread = (1...6).map { index in
            EmailThreadMessage(from: "Dana Lee", fromEmail: "dana@example.com", date: "Sep \(13 - index)",
                               text: "Message \(index). " + String(repeating: "Details about the plan. ", count: 60))
        }
        let prompt = EmailPredictionPrompt.user(context(compose(subject: "", thread: longThread)))
        expect(prompt.contains("[1] From Dana Lee <dana@example.com>, Sep 12:\nMessage 1."), "Newest message is first")
        expect(!prompt.contains("Message 6."), "Older messages beyond the thread budget are dropped")
        expect(prompt.contains("GREETING NAME: Dana") && prompt.contains("CALENDAR: not available") && prompt.contains("CURRENT SUBJECT: (empty)"), "Prompt names the greeting, calendar state and empty subject")
        expect(prompt.count < 6000, "Prompt fits the small model's context")
        let calendarPrompt = EmailPredictionPrompt.user(conflicted)
        expect(calendarPrompt.contains("Tuesday 2026-09-15: busy 13:30 to 15:00 Dentist") && calendarPrompt.contains("Wednesday 2026-09-16: free"), "Calendar lines list busy blocks per day")
        expect(EmailPredictionPrompt.stripQuoted("Sounds good.\n\nOn Sat, Sep 12, 2026 at 9:00 AM Dana Lee wrote:\n> old text") == "Sounds good.", "Quoted history is removed from thread messages")

        // Generation: one repair retry, never more.
        var calls: [String] = []
        let repaired = try await EmailPredictionGenerator.generate(context: context(compose())) { system, _ in
            calls.append(system)
            return calls.count == 1 ? answer(["body": "Hi [Name],\n\nThanks.", "subject": "Hello"])
                : answer(["body": "Hi Dana,\n\nThanks for the update.", "subject": "Thanks for the update"])
        }
        expect(calls.count == 2 && calls[1].contains("REJECTED") && repaired.body == "Hi Dana,\n\nThanks for the update.", "An invalid answer gets exactly one repair")
        calls = []
        do {
            _ = try await EmailPredictionGenerator.generate(context: reply) { system, _ in
                calls.append(system)
                return answer(["body": "Hi Dana,\n\nFriday at 5pm works.", "subject": "x"])
            }
            fatalError("Invented facts must never be written")
        } catch EmailPredictionError.rejected(let issues) {
            expect(calls.count == 2 && issues.contains { $0.contains("5pm") }, "Two ungrounded answers fail with the reason")
        }
        let noSubject = try await EmailPredictionGenerator.generate(context: context(compose())) { _, _ in
            answer(["body": "Hi Dana,\n\nThanks for the update."])
        }
        expect(noSubject.subject == nil && noSubject.body == "Hi Dana,\n\nThanks for the update.", "A good body is still written when the subject never arrives")
        // Regression: slow context sources (AppleScript, Composio) could hold a prediction indefinitely.
        let slowStarted = Date()
        let slow: String? = await EmailDeadline.first(within: 0.2) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return Task.isCancelled ? "cancelled late" : "late"
        }
        expect(slow == nil && Date().timeIntervalSince(slowStarted) < 1, "The deadline stops waiting and ignores a late result")
        let quick: String? = await EmailDeadline.first(within: 2) { "ready" }
        expect(quick == "ready", "Work that finishes in time returns its value")
        let threaded: Bool? = await EmailDeadline.firstOnThread(within: 2) { !Thread.isMainThread }
        expect(threaded == true, "Blocking work runs off the main thread")
        let blockingStarted = Date()
        let blocking: Int? = await EmailDeadline.firstOnThread(within: 0.2) { Thread.sleep(forTimeInterval: 1); return 1 }
        expect(blocking == nil && Date().timeIntervalSince(blockingStarted) < 0.8, "Blocking work on the dedicated thread cannot hold the caller past the deadline")
        print("Passed \(checks) email prediction prompt, cleanup, grounding and action checks")
    }
}
