import Foundation
import EventKit
import AppKit

// MARK: - CalendarEngine
// Monitors the system calendar (which syncs Google Calendar, iCloud, Exchange, etc.)
// Every 60 seconds it scans for events starting in the next 15 minutes.
// When an event is 2 minutes away it fires MeetingJoinEngine to auto-join.

// Wraps EKEventStore so it can be passed across actor boundaries safely.
// EKEventStore is thread-safe per Apple docs but not marked Sendable.
private final class CalendarStore: @unchecked Sendable {
    let store = EKEventStore()
}

@Observable
@MainActor
final class CalendarEngine {
    static let shared = CalendarEngine()

    private let calendarStore = CalendarStore()
    private var store: EKEventStore { calendarStore.store }
    private var timer: Timer?
    private var firedMeetingIDs: Set<String> = []  // prevent double-firing

    var isAuthorized: Bool = false
    var upcomingMeetings: [UpcomingMeeting] = []

    private init() {}

    // MARK: - Start

    func start() async {
        let granted = await requestAccess()
        isAuthorized = granted
        guard granted else {
            print("[CalendarEngine] Calendar access denied")
            return
        }
        print("[CalendarEngine] Access granted — starting monitor")
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Create / delete (the autonomy "eventkit" lane's executor)
    // The planner was TAUGHT an "eventkit" backend, but no executor existed —
    // every planned calendar step routed to pixels and failed with "Unknown
    // computer action". This is the real one.

    /// Creates an event in the default calendar. Returns (eventId, nil) on
    /// success or (nil, reason) on failure.
    func createEvent(title: String, start: Date, end: Date, notes: String?, location: String?) -> (id: String?, error: String?) {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .authorized || status == .fullAccess else {
            return (nil, "Calendar access is not granted — System Settings ▸ Privacy & Security ▸ Calendars ▸ enable Holmes.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return (nil, "No default calendar is configured for new events.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.location = location
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return (event.eventIdentifier, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Removes an event created by createEvent — the undo closure's body.
    @discardableResult
    func deleteEvent(id: String) -> Bool {
        guard let event = store.event(withIdentifier: id) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Permission

    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                print("[CalendarEngine] Request error: \(error)")
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Timer

    private func startTimer() {
        // Scan immediately then every 60s
        Task { @MainActor in
            await scanUpcomingEvents()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scanUpcomingEvents()
            }
        }
    }

    // MARK: - Scan

    func scanUpcomingEvents() async {
        let now = Date()
        let horizon = now.addingTimeInterval(30 * 60)  // show next 30 min in panel

        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: calendars)
        let events = store.events(matching: predicate)

        var meetings: [UpcomingMeeting] = []
        for event in events {
            guard let startDate = event.startDate else { continue }
            let minutesUntil = startDate.timeIntervalSince(now) / 60
            guard minutesUntil >= 0 else { continue }

            let meetingURL = extractMeetingURL(from: event)
            let meeting = UpcomingMeeting(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                startDate: startDate,
                minutesUntil: minutesUntil,
                meetingURL: meetingURL,
                meetingType: meetingURL.flatMap { MeetingType.detect(from: $0) },
                calendarName: event.calendar?.title ?? "Calendar",
                location: event.location,
                notes: event.notes
            )
            meetings.append(meeting)
        }

        let sorted = meetings.sorted { $0.startDate < $1.startDate }
        // Only publish on real change — the unconditional 60s reassign was
        // invalidating MainPanelView every minute even when nothing moved.
        if sorted.map(\.id) != upcomingMeetings.map(\.id)
            || sorted.map(\.minutesUntil) != upcomingMeetings.map(\.minutesUntil) {
            upcomingMeetings = sorted
        }

        // Auto-join trigger: ≤ 2 min away
        for meeting in upcomingMeetings where meeting.minutesUntil <= 2 {
            guard !firedMeetingIDs.contains(meeting.id) else { continue }
            firedMeetingIDs.insert(meeting.id)
            print("[CalendarEngine] 🔔 Firing join for: \(meeting.title)")
            await MeetingJoinEngine.shared.handleImminent(meeting: meeting)
        }

        print("[CalendarEngine] Scan complete — \(upcomingMeetings.count) event(s) in next 30 min")
        for m in upcomingMeetings {
            print("  · \(m.title) in \(Int(m.minutesUntil))m | url: \(m.meetingURL?.absoluteString ?? "none")")
        }
    }

    // MARK: - Debug: force-fire the join alert for the next upcoming meeting

    func debugFireNextMeeting() async {
        await scanUpcomingEvents()
        guard let next = upcomingMeetings.first else {
            print("[CalendarEngine] DEBUG: no upcoming meetings found in next 30 min")
            return
        }
        print("[CalendarEngine] DEBUG: force-firing join for '\(next.title)'")
        // Remove from fired set so it re-fires even if already triggered
        firedMeetingIDs.remove(next.id)
        await MeetingJoinEngine.shared.handleImminent(meeting: next)
    }

    // MARK: - URL Extraction

    private func extractMeetingURL(from event: EKEvent) -> URL? {
        // 1. Check URL field
        if let url = event.url { return url }

        // 2. Search notes for meeting links
        let searchIn = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
        return extractFirstMeetingURL(from: searchIn)
    }

    func extractFirstMeetingURL(from text: String) -> URL? {
        let patterns = [
            // Google Meet
            #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#,
            // Zoom
            #"https://[a-zA-Z0-9]+\.zoom\.us/j/[0-9]+(?:\?[^\s]*)?"#,
            // Zoom short
            #"https://zoom\.us/j/[0-9]+(?:\?[^\s]*)?"#,
            // Microsoft Teams
            #"https://teams\.microsoft\.com/l/meetup-join/[^\s]+"#,
            // Webex
            #"https://[a-zA-Z0-9]+\.webex\.com/meet/[^\s]+"#,
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let urlString = String(text[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>\"'"))
                if let url = URL(string: urlString) { return url }
            }
        }
        return nil
    }
}

// MARK: - UpcomingMeeting

struct UpcomingMeeting: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let minutesUntil: Double
    let meetingURL: URL?
    let meetingType: MeetingType?
    let calendarName: String
    let location: String?
    let notes: String?

    var timeLabel: String {
        if minutesUntil < 1 { return "Starting now" }
        if minutesUntil < 60 { return "in \(Int(minutesUntil))m" }
        let h = Int(minutesUntil / 60)
        let m = Int(minutesUntil.truncatingRemainder(dividingBy: 60))
        return m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
    }
}

// MARK: - MeetingType

enum MeetingType: String {
    case googleMeet = "Google Meet"
    case zoom = "Zoom"
    case teams = "Microsoft Teams"
    case webex = "Webex"
    case unknown = "Video Call"

    var appName: String? {
        switch self {
        case .zoom: return "zoom.us"
        case .teams: return "Microsoft Teams"
        case .webex: return "Cisco Webex"
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .googleMeet: return "video.fill"
        case .zoom: return "video.circle.fill"
        case .teams: return "person.3.fill"
        case .webex: return "video.badge.checkmark"
        case .unknown: return "video"
        }
    }

    static func detect(from url: URL) -> MeetingType {
        let host = url.host ?? ""
        if host.contains("meet.google.com") { return .googleMeet }
        if host.contains("zoom.us") { return .zoom }
        if host.contains("teams.microsoft.com") { return .teams }
        if host.contains("webex.com") { return .webex }
        return .unknown
    }
}
