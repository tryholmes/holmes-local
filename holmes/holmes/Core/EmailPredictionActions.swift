import EventKit
import Foundation

/// Follow up actions suggested by a written email. Each one is shown on the
/// existing confirmation card and runs only after the person approves it.
@MainActor
enum EmailActionOffers {
    private static let reminderStore = EKEventStore()

    /// `isCurrent` turns false once the written email is undone; no further
    /// question about it is asked.
    static func offer(_ actions: [EmailActionCandidate], compose: EmailComposeSnapshot, body: String, subject: String,
                      isCurrent: @escaping @MainActor () -> Bool) async {
        let saveDraft = canSaveGmailDraft(for: compose)
        guard !actions.isEmpty || saveDraft else { return }
        // Let the person see the written email before any question appears.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for action in actions {
            guard !Task.isCancelled, isCurrent() else { return }
            switch action {
            case .calendarEvent(let title, let start, let minutes):
                await offerEvent(title: title, start: start, minutes: minutes, compose: compose)
            case .followUp(let days):
                await offerFollowUp(days: days, compose: compose, subject: subject)
            }
        }
        if saveDraft, !Task.isCancelled, isCurrent() { await offerGmailDraft(compose: compose, body: body, subject: subject) }
    }

    private static func who(_ compose: EmailComposeSnapshot) -> String {
        guard let first = compose.recipients.first else { return "them" }
        return compose.recipientNames[first.lowercased()] ?? first
    }

    private static func report(_ title: String, success: Bool, summary: String) {
        let activity = WorkActivityCenter.shared.begin(title: title)
        WorkActivityCenter.shared.finish(activity, outcome: success ? .success : .failure, summary: summary)
    }

    private static func offerEvent(title: String, start: Date, minutes: Int, compose: EmailComposeSnapshot) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let preview = "\(title)\n\(formatter.string(from: start)), \(minutes) minutes\nWith \(who(compose))"
        let decision = await ConfirmationBus.shared.decide(PendingAction(
            title: "Add this to your calendar?", preview: preview, appName: "Calendar", actionType: .agentToolCall))
        guard case .approved(let edited) = decision else { return }
        let finalTitle = edited.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? title
        guard await CalendarEngine.shared.requestAccess() else {
            report("Calendar event", success: false, summary: "Calendar access is off. Allow Holmes in System Settings, Privacy and Security, Calendars.")
            return
        }
        let outcome = CalendarEngine.shared.createEvent(title: finalTitle, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                                        notes: "Added from your email to \(who(compose)).", location: nil)
        report("Calendar event", success: outcome.id != nil,
               summary: outcome.id != nil ? "Added “\(finalTitle)” to your calendar." : (outcome.error ?? "The event could not be added."))
    }

    /// Holmes cannot watch for the reply itself, so the check is a reminder the
    /// person sees when it is due and can mark done if they already got an answer.
    private static func offerFollowUp(days: Int, compose: EmailComposeSnapshot, subject: String) async {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: Date()),
              let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let topic = subject.isEmpty ? "your email" : "“\(subject)”"
        let decision = await ConfirmationBus.shared.decide(PendingAction(
            title: "Remind you to follow up?",
            preview: "Follow up with \(who(compose)) about \(topic) if they have not replied by \(formatter.string(from: due)).",
            appName: "Reminders", actionType: .agentToolCall))
        guard case .approved = decision else { return }
        do {
            guard try await reminderStore.requestFullAccessToReminders() else {
                report("Follow up reminder", success: false, summary: "Reminders access is off. Allow Holmes in System Settings, Privacy and Security, Reminders.")
                return
            }
            let reminder = EKReminder(eventStore: reminderStore)
            reminder.title = "Follow up with \(who(compose)): \(subject.isEmpty ? "email" : subject)"
            reminder.notes = "Holmes added this when you wrote the email. Mark it done if they already replied."
            reminder.calendar = reminderStore.defaultCalendarForNewReminders()
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            try reminderStore.save(reminder, commit: true)
            report("Follow up reminder", success: true, summary: "Reminder set for \(formatter.string(from: due)).")
        } catch {
            report("Follow up reminder", success: false, summary: error.localizedDescription)
        }
    }

    /// Hidden for Gmail on the web, which already keeps this draft in Drafts,
    /// and whenever Composio's Gmail tools are not connected.
    static func canSaveGmailDraft(for compose: EmailComposeSnapshot) -> Bool {
        compose.provider != "Gmail" && gmailDraftTool() != nil && !compose.recipients.isEmpty
    }

    private static func gmailDraftTool() -> (name: String, meta: Bool)? {
        let composio = MCPClient.shared.tools.filter { $0.serverName.lowercased() == ComposioCatalog.composioServerName }
        if let direct = composio.first(where: { $0.name.uppercased() == "GMAIL_CREATE_EMAIL_DRAFT" }) {
            return (direct.namespacedName, false)
        }
        if let meta = composio.first(where: { $0.name.uppercased() == ComposioCatalog.metaExecuteTool }),
           ComposioCatalog.connectedApps(toolNames: MCPClient.shared.tools.map(\.namespacedName)).contains("GMAIL") {
            return (meta.namespacedName, true)
        }
        return nil
    }

    private static func offerGmailDraft(compose: EmailComposeSnapshot, body: String, subject: String) async {
        guard let tool = gmailDraftTool(), let to = compose.recipients.first else { return }
        let decision = await ConfirmationBus.shared.decide(PendingAction(
            title: "Save a copy to Gmail Drafts?",
            preview: "To: \(compose.recipients.joined(separator: ", "))\nSubject: \(subject)\n\n\(body)",
            appName: "Gmail", actionType: .agentToolCall))
        guard case .approved = decision else { return }
        var arguments: [String: Any] = ["recipient_email": to, "subject": subject, "body": body, "is_html": false]
        let extra = Array(compose.recipients.dropFirst()) + compose.cc
        if !extra.isEmpty { arguments["cc"] = extra }
        if !compose.bcc.isEmpty { arguments["bcc"] = compose.bcc }
        let result = tool.meta
            ? await MCPClient.shared.call(namespacedName: tool.name, arguments: ["tools": [["tool_slug": "GMAIL_CREATE_EMAIL_DRAFT", "arguments": arguments]]])
            : await MCPClient.shared.call(namespacedName: tool.name, arguments: arguments)
        report("Gmail draft", success: !result.isError,
               summary: result.isError ? "Gmail did not save the draft." : "Saved to Gmail Drafts. Nothing was sent.")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
