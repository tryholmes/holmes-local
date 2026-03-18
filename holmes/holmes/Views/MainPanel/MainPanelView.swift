import SwiftUI

struct MainPanelView: View {
    @Binding var isVisible: Bool
    @State private var agent = HolmesAgent.shared
    @State private var calendar = CalendarEngine.shared
    @State private var localSuggestions: [ActionSuggestion] = ActionSuggestion.samples

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 12) {
                    // Live context from agent, falls back to placeholder
                    ContextCard(context: agent.currentContext)

                    // DEBUG: show raw OCR word count + context
                    if !agent.lastOCRText.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DEBUG — OCR: \(agent.lastOCRText.count) chars")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.yellow)
                            Text(String(agent.lastOCRText.prefix(120)).replacingOccurrences(of: "\n", with: " ↩ "))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.yellow.opacity(0.7))
                                .lineLimit(3)
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                    }

                    // Analyzing indicator
                    if agent.isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(Color(hex: "B8881C"))
                            Text("Analyzing screen...")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "5A7A8A"))
                            Spacer()
                            if let updated = agent.lastUpdated {
                                Text(updated, style: .relative)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(Color(hex: "3D5A6A"))
                            }
                        }
                        .padding(.horizontal, 4)
                    } else if let updated = agent.lastUpdated {
                        HStack {
                            Text("· via \(agent.modelBackend)")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "3D5A6A"))
                            Spacer()
                            Text(updated, style: .relative)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "3D5A6A"))
                        }
                        .padding(.horizontal, 4)
                    }

                    // Live suggestions from agent, falls back to local state
                    let displayedSuggestions = agent.suggestedActions.isEmpty ? localSuggestions : agent.suggestedActions
                    ActionSuggestions(
                        suggestions: displayedSuggestions,
                        onSelect: { selectSuggestion($0) },
                        onApproveAll: { approveAllSuggestions(displayedSuggestions) }
                    )

                    // Upcoming meetings
                    if !calendar.upcomingMeetings.isEmpty {
                        UpcomingMeetingsCard(meetings: calendar.upcomingMeetings)
                    } else if calendar.isAuthorized {
                        // Authorized but nothing in next 30 min — show debug scan button
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "3D5A6A"))
                            Text("No meetings in next 30 min")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "3D5A6A"))
                            Spacer()
                            Button(action: {
                                Task { await CalendarEngine.shared.scanUpcomingEvents() }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "4A9EDB").opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                    }

                    // Live activity log from agent
                    let displayedActivities = agent.recentActivities.isEmpty ? ActivityItem.samples : agent.recentActivities
                    ActivityLog(activities: displayedActivities)
                }
                .padding(14)
            }
            .background(Color(hex: "0A0F14"))
        }
        .frame(width: 380, height: 520)
        .background(Color(hex: "0A0F14"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "2A3D4A"), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        .onChange(of: isVisible) { _, visible in
            if visible { agent.clearBadge() }
        }
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "B8881C"))
                Text("HOLMES")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "E8D5A3"))
                    .tracking(3)
            }
            Spacer()
            HStack(spacing: 6) {
                WindowButton(icon: "minus") { isVisible = false }
                WindowButton(icon: "xmark") { isVisible = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(hex: "0D1318"))
        .overlay(Divider().background(Color(hex: "1E2D38")), alignment: .bottom)
    }
    
    private func selectSuggestion(_ suggestion: ActionSuggestion) {
        if let index = localSuggestions.firstIndex(where: { $0.id == suggestion.id }) {
            localSuggestions[index].isSelected.toggle()
        }
    }

    private func approveAllSuggestions(_ current: [ActionSuggestion]) {
        for index in localSuggestions.indices {
            localSuggestions[index].isSelected = true
        }
    }
}

// MARK: - Upcoming Meetings Card

struct UpcomingMeetingsCard: View {
    let meetings: [UpcomingMeeting]
    @State private var calendar = CalendarEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "4A9EDB"))
                Text("UPCOMING")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "4A9EDB"))
                    .tracking(2)
                Spacer()
                // Debug: force-fire the join alert for the next meeting
                Button(action: {
                    Task { await CalendarEngine.shared.debugFireNextMeeting() }
                }) {
                    Text("TEST")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "B8881C"))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(hex: "B8881C").opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Force-trigger the join alert for the next meeting")

                Button(action: {
                    Task { await CalendarEngine.shared.scanUpcomingEvents() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "4A9EDB").opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Re-scan calendar now")
            }

            ForEach(meetings.prefix(3)) { meeting in
                MeetingRow(meeting: meeting)
            }
        }
        .padding(12)
        .background(Color(hex: "0D1820"))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: "4A9EDB").opacity(0.25), lineWidth: 1))
    }
}

struct MeetingRow: View {
    let meeting: UpcomingMeeting

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: meeting.meetingType?.icon ?? "video")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "4A9EDB"))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "E8D5A3"))
                    .lineLimit(1)
                Text(meeting.meetingType?.rawValue ?? "Meeting")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
            }

            Spacer()

            Text(meeting.timeLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(meeting.minutesUntil <= 2 ? Color(hex: "E05252") : Color(hex: "B8881C"))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((meeting.minutesUntil <= 2 ? Color(hex: "E05252") : Color(hex: "B8881C")).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if meeting.meetingURL != nil {
                Button(action: {
                    MeetingJoinEngine.shared.joinMeeting(meeting)
                }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "4A9EDB"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WindowButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? Color(hex: "B8881C") : Color(hex: "3D5A6A"))
                .frame(width: 28, height: 26)
                .background(Color(hex: "0A0F14"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "1E2D38"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 36, minHeight: 36)
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { isHovered = h } }
    }
}

#Preview {
    ZStack {
        Color(hex: "060A0D").ignoresSafeArea()
        MainPanelView(isVisible: .constant(true))
    }
    .frame(width: 500, height: 600)
}
