import Foundation
import AppKit
import UserNotifications

// MARK: - MeetingJoinEngine
// Triggered by CalendarEngine when a meeting is ≤ 2 minutes away.
// Strategy:
//   1. Show a Holmes confirmation proposal so the user can approve the join.
//   2. If the meeting URL is Google Meet — open in default browser (no app needed).
//   3. If Zoom — preload the Zoom app first (wake it), then open the join link.
//   4. If Teams/Webex — open their URL which deep-links into the installed app.
//   5. Show a system notification as a fallback for when Holmes is backgrounded.

@MainActor
final class MeetingJoinEngine {
    static let shared = MeetingJoinEngine()
    private init() {
        requestNotificationPermission()
    }

    // MARK: - Entry point from CalendarEngine

    func handleImminent(meeting: UpcomingMeeting) async {
        print("[MeetingJoinEngine] Handling imminent: \(meeting.title)")

        // Always fire a system notification (even if app is hidden)
        sendNotification(for: meeting)

        // Build a Holmes PendingAction proposal
        let proposal = buildProposal(for: meeting)
        ConfirmationBus.shared.propose(proposal)

        // If Zoom — preload the app in background so it's warm
        if meeting.meetingType == .zoom {
            preloadZoom()
        }

        // Update HolmesAgent context to show meeting card
        HolmesAgent.shared.showMeetingContext(meeting)
    }

    // MARK: - Execute join (called when user approves the confirmation)

    func joinMeeting(_ meeting: UpcomingMeeting) {
        guard let url = meeting.meetingURL else {
            print("[MeetingJoinEngine] No URL for \(meeting.title)")
            openCalendarApp()
            return
        }

        switch meeting.meetingType {
        case .zoom:
            joinZoom(url: url)
        case .googleMeet:
            joinGoogleMeet(url: url)
        case .teams:
            joinTeams(url: url)
        case .webex:
            NSWorkspace.shared.open(url)
        default:
            NSWorkspace.shared.open(url)
        }

        print("[MeetingJoinEngine] Joined: \(meeting.title) via \(url)")
    }

    // MARK: - Platform-specific join

    private func joinZoom(url: URL) {
        // If Zoom.app is installed, open via URL scheme for deep-link join
        // Otherwise fall back to browser
        let zoomScheme = buildZoomScheme(from: url)
        if let zoomURL = zoomScheme, canOpen(scheme: "zoommtg") {
            NSWorkspace.shared.open(zoomURL)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func buildZoomScheme(from url: URL) -> URL? {
        // Convert https://zoom.us/j/123456?pwd=xxx → zoommtg://zoom.us/join?action=join&confno=123456&pwd=xxx
        guard let host = url.host else { return nil }
        let path = url.path  // /j/123456
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard components.count >= 2, components[0] == "j",
              let confno = components.last else { return nil }

        var query = "action=join&confno=\(confno)"
        if let existing = url.query { query += "&\(existing)" }

        return URL(string: "zoommtg://\(host)/join?\(query)")
    }

    private func joinGoogleMeet(url: URL) {
        // Open in default browser — Meet is web-based
        NSWorkspace.shared.open(url)
    }

    private func joinTeams(url: URL) {
        // Teams URL scheme for deep linking
        if canOpen(scheme: "msteams") {
            var urlString = url.absoluteString
            urlString = urlString.replacingOccurrences(of: "https://teams.microsoft.com", with: "msteams:")
            if let teamsURL = URL(string: urlString) {
                NSWorkspace.shared.open(teamsURL)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    private func canOpen(scheme: String) -> Bool {
        guard let url = URL(string: "\(scheme)://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    // MARK: - Zoom preload (wake up the app before meeting)

    private func preloadZoom() {
        let zoomBundleIDs = ["us.zoom.xos", "us.zoom.videomeetings"]
        for bundleID in zoomBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                // Launch without activating (stays in background)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    if let error {
                        print("[MeetingJoinEngine] Zoom preload error: \(error)")
                    } else {
                        print("[MeetingJoinEngine] Zoom preloaded in background")
                    }
                }
                return
            }
        }
        print("[MeetingJoinEngine] Zoom not installed — will use browser join")
    }

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    // MARK: - Holmes confirmation proposal

    private func buildProposal(for meeting: UpcomingMeeting) -> PendingAction {
        let type = meeting.meetingType?.rawValue ?? "Video Call"
        let timeLabel = meeting.minutesUntil < 1 ? "now" : "in \(Int(meeting.minutesUntil))m"
        let title = "\(type) \(timeLabel) — \(meeting.title)"

        let preview: String
        if let url = meeting.meetingURL {
            preview = url.absoluteString
        } else {
            preview = meeting.location ?? "No meeting link found"
        }

        return PendingAction(
            title: title,
            preview: preview,
            appName: meeting.meetingType?.appName ?? "Browser",
            actionType: .openMeeting,
            meetingURL: meeting.meetingURL,
            meeting: meeting
        )
    }

    // MARK: - System notification

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("[MeetingJoinEngine] Notifications: \(granted ? "granted" : "denied")")
        }
    }

    func sendNotification(for meeting: UpcomingMeeting) {
        let content = UNMutableNotificationContent()
        let type = meeting.meetingType?.rawValue ?? "Meeting"
        content.title = "⏰ \(type) starting \(meeting.timeLabel)"
        content.body = meeting.title
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        if meeting.meetingURL != nil {
            content.subtitle = "Tap to join"
        }

        // Fire immediately
        let request = UNNotificationRequest(
            identifier: "meeting-\(meeting.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[MeetingJoinEngine] Notification error: \(error)") }
        }
    }
}
