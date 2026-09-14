import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Collects what an email prediction may use. Every source is optional, bounded
/// and silent: no permission prompt, no app launch, and a failure means skip.
@MainActor
enum EmailContextGatherer {
    private final class StoreHolder: @unchecked Sendable { let store = EKEventStore() }
    private static let calendarStore = StoreHolder()

    static func gather(for compose: EmailComposeSnapshot, instruction: String) async -> EmailPredictionContext {
        var context = EmailPredictionContext(compose: compose)
        context.instruction = instruction
        context.now = Date()
        context.timeZone = .current
        let calendar = await calendarBlocks(now: context.now)
        context.calendarAvailable = calendar.available
        context.calendar = calendar.blocks
        context.memory = await memory(for: compose)
        context.sentSamples = await sentSamples(for: compose)
        return context
    }

    /// Busy blocks for the prompt's days, only when calendar access was already
    /// granted. This path never requests access.
    static func calendarBlocks(now: Date) async -> (available: Bool, blocks: [EmailCalendarBlock]) {
        let holder = calendarStore
        return await EmailDeadline.firstOnThread(within: 2) { queryCalendar(holder.store, now: now) } ?? (false, [])
    }

    nonisolated private static func queryCalendar(_ store: EKEventStore, now: Date) -> (available: Bool, blocks: [EmailCalendarBlock]) {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return (false, []) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: EmailPredictionPrompt.calendarDays + 1, to: start) else { return (false, []) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let blocks = store.events(matching: predicate)
            .filter { $0.availability != .free && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map { EmailCalendarBlock(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
        return (true, Array(blocks))
    }

    /// Holmes memory about the recipients and the subject, most relevant first.
    static func memory(for compose: EmailComposeSnapshot) async -> [String] {
        var topics: [String] = []
        let generic: Set<String> = ["info", "hello", "team", "support", "sales", "billing", "noreply", "no-reply", "contact", "admin", "office"]
        for address in compose.recipients + compose.cc {
            if let name = compose.recipientNames[address.lowercased()], !name.isEmpty { topics.append(name) }
            if let local = address.split(separator: "@").first.map(String.init), local.count >= 3, !generic.contains(local.lowercased()) {
                topics.append(local)
            }
        }
        let subject = (compose.threadSubject.isEmpty ? compose.subject : compose.threadSubject)
            .replacingOccurrences(of: #"^\s*((re|fwd?|aw|sv|wg|tr)\s*:\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.count >= 3 { topics.append(subject) }
        guard !topics.isEmpty else { return [] }
        let hits = await MemoryStore.shared.recall(topics: topics, limit: 10)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        // The composer itself is recorded as context; it is not a memory of anything.
        return hits.map(\.event)
            .filter { $0.activity != "composing" && !$0.summary.hasPrefix("Composing an email") }
            .prefix(5)
            .map { event in
                let detail = event.detail.isEmpty ? "" : " (\(String(event.detail.prefix(160))))"
                return "\(formatter.string(from: event.date)): \(event.summary)\(detail)"
            }
    }

    /// Recent mail the user sent to the first recipient: Composio Gmail when
    /// connected, else Apple Mail's Sent mailbox when Mail is running and
    /// automation is already allowed, else nothing.
    static func sentSamples(for compose: EmailComposeSnapshot) async -> [EmailSentSample] {
        guard let recipient = compose.recipients.first, EmailComposeSnapshot.isEmailAddress(recipient) else { return [] }
        if let fromGmail = await composioSent(to: recipient), !fromGmail.isEmpty { return fromGmail }
        return await EmailDeadline.firstOnThread(within: 4) { appleMailSent(to: recipient) } ?? []
    }

    private static func composioSent(to address: String) async -> [EmailSentSample]? {
        let tools = MCPClient.shared.tools.filter { $0.serverName.lowercased() == ComposioCatalog.composioServerName }
        let arguments: [String: Any] = ["query": "in:sent to:\(address)", "max_results": 3, "include_payload": false]
        let call: (name: String, arguments: [String: Any])
        if let direct = tools.first(where: { $0.name.uppercased() == "GMAIL_FETCH_EMAILS" }) {
            call = (direct.namespacedName, arguments)
        } else if let meta = tools.first(where: { $0.name.uppercased() == ComposioCatalog.metaExecuteTool }),
                  ComposioCatalog.connectedApps(toolNames: MCPClient.shared.tools.map(\.namespacedName)).contains("GMAIL") {
            call = (meta.namespacedName, ["tools": [["tool_slug": "GMAIL_FETCH_EMAILS", "arguments": arguments]]])
        } else {
            return nil
        }
        guard let result = await EmailDeadline.first(within: 8, { await MCPClient.shared.call(namespacedName: call.name, arguments: call.arguments) }),
              !result.isError else { return nil }
        return parseSentMail(result.text, to: address)
    }

    /// Composio returns nested JSON; any object with a subject and message text is a message.
    static func parseSentMail(_ text: String, to address: String) -> [EmailSentSample] {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var samples: [EmailSentSample] = []
        func walk(_ value: Any) {
            guard samples.count < 3 else { return }
            if let object = value as? [String: Any] {
                let preview = object["preview"] as? [String: Any]
                let body = (object["messageText"] as? String) ?? (object["snippet"] as? String) ?? (preview?["body"] as? String)
                if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let subject = (object["subject"] as? String) ?? (preview?["subject"] as? String) {
                    let date = (object["messageTimestamp"] as? String) ?? (object["date"] as? String) ?? ""
                    samples.append(EmailSentSample(to: address, subject: subject, date: String(date.prefix(40)), text: String(body.prefix(600))))
                    return
                }
                object.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return samples
    }

    /// Runs on the dedicated context thread with a deadline, never the main
    /// thread. Reads at most 25 recent sent messages and never launches Mail or
    /// asks for automation.
    nonisolated private static func appleMailSent(to address: String) -> [EmailSentSample] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty,
              automationAlreadyAllowed("com.apple.mail") else { return [] }
        let wanted = address.lowercased().filter { !"\"\\".contains($0) }
        let source = """
        set output to ""
        set found to 0
        tell application "Mail"
            set sentBox to sent mailbox
            set total to count of messages of sentBox
            if total > 25 then set total to 25
            repeat with i from 1 to total
                set m to message i of sentBox
                set matched to false
                repeat with r in (to recipients of m)
                    if (address of r as string) is "\(wanted)" then set matched to true
                end repeat
                if matched then
                    set c to content of m
                    if length of c > 600 then set c to text 1 thru 600 of c
                    set output to output & (subject of m) & (ASCII character 31) & ((date sent of m) as string) & (ASCII character 31) & c & (ASCII character 30)
                    set found to found + 1
                    if found is 2 then exit repeat
                end if
            end repeat
        end tell
        return output
        """
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, error == nil else { return [] }
        return output.components(separatedBy: "\u{1E}").compactMap { record in
            let fields = record.components(separatedBy: "\u{1F}")
            guard fields.count == 3, !fields[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return EmailSentSample(to: address, subject: fields[0], date: fields[1], text: fields[2])
        }
    }

    nonisolated private static func automationAlreadyAllowed(_ bundleIdentifier: String) -> Bool {
        var target = AEAddressDesc()
        let created = bundleIdentifier.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
    }

}
