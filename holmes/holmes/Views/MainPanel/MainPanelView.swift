import SwiftUI

struct MainPanelView: View {
    @Binding var isVisible: Bool
    @State private var agent = HolmesAgent.shared
    @State private var calendar = CalendarEngine.shared
    @State private var playbooks = PlaybookEngine.shared
    @State private var cardsAppeared = false

    var body: some View {
        ZStack {
            // Match the Settings window's translucency — .hudWindow is far more
            // transparent than .sidebar, so the desktop/gradient shows through.
            AppleGlassBackground(cornerRadius: 18, material: .hudWindow)

            VStack(spacing: 0) {
                headerView

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        // ABOVE the context card, deliberately. Someone asked the
                        // user a question and the answer is already written — that
                        // outranks "here is what you are looking at", which they
                        // can see for themselves. Nothing about it sends: the card
                        // stages text and stops (see ReplyReadyCard).
                        if let reply = agent.pendingReplyDraft,
                           let incoming = agent.pendingReplyTo {
                            ReplyReadyCard(
                                draft: reply,
                                incoming: incoming,
                                onEdit: { agent.notePendingReplyEdit($0) },
                                // The panel is where the reply LIVES, so dismissing
                                // here discards it (and closes the floating card),
                                // unlike the popup's Dismiss which only hides.
                                onDismiss: { agent.clearPendingReply() })
                                .cardEntrance(appeared: cardsAppeared, delay: 0.0)
                        }

                        ContextCard(context: agent.currentContext)
                            .cardEntrance(appeared: cardsAppeared, delay: 0.00)

                        // Where the context came from. Directly under the card it
                        // describes, because "is Holmes reading the DOM or
                        // guessing at pixels" is the first question the headline
                        // above raises.
                        ExtensionStatusRow()
                            .cardEntrance(appeared: cardsAppeared, delay: 0.05)

                        // Status row
                        statusRow
                            .cardEntrance(appeared: cardsAppeared, delay: 0.08)

                        // Proactive drafts (playbooks — draft-never-send)
                        if !playbooks.drafts.isEmpty {
                            DraftsCard(drafts: playbooks.drafts)
                                .cardEntrance(appeared: cardsAppeared, delay: 0.14)
                        }

                        // What Holmes has remembered, and which rows it's using
                        // for the task in flight.
                        AgentMemoryCard()
                            .cardEntrance(appeared: cardsAppeared, delay: 0.18)

                        // Meetings
                        if !calendar.upcomingMeetings.isEmpty {
                            UpcomingMeetingsCard(meetings: calendar.upcomingMeetings)
                                .cardEntrance(appeared: cardsAppeared, delay: 0.16)
                        } else if calendar.isAuthorized {
                            noMeetingsRow
                                .cardEntrance(appeared: cardsAppeared, delay: 0.16)
                        }

                        // Activity log
                        ActivityLog(activities: agent.recentActivities)
                            .cardEntrance(appeared: cardsAppeared, delay: 0.20)
                    }
                    .padding(12)
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(width: 380, height: 600)
        .font(NoirFonts.body())
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(NoirColors.glassStroke, lineWidth: 0.75)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17.5)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.clear, Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .padding(0.5)
        )
        .shadow(color: NoirColors.panelShadow, radius: 32, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation { cardsAppeared = true }
            }
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                agent.clearBadge()
                cardsAppeared = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation { cardsAppeared = true }
                }
            }
        }
    }

    // MARK: Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Brand
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 28, height: 28)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.85))
                    }
                    Text("holmes")
                        .font(NoirFonts.brand(size: 28))
                        .foregroundStyle(NoirColors.textPrimary)
                }

                Spacer()

                // Window controls
                HStack(spacing: 4) {
                    WindowButton(icon: "minus", tooltip: "Minimise") { isVisible = false }
                    WindowButton(icon: "xmark", tooltip: "Close")    { isVisible = false }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(NoirColors.glassChrome)

            // Gradient divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, NoirColors.glassDivider, Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.75)
        }
    }

    // MARK: Status row

    private var statusRow: some View {
        Group {
            if agent.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(Color.white.opacity(0.60))
                    Text("Analyzing screen...")
                        .font(NoirFonts.font(size: 11, weight: .regular, design: .default))
                        .foregroundColor(NoirColors.textTertiary)
                    Spacer()
                    if let updated = agent.lastUpdated {
                        Text(updated, style: .relative)
                            .font(NoirFonts.font(size: 10, weight: .regular, design: .default))
                            .foregroundColor(NoirColors.textTertiary)
                    }
                }
                .padding(.horizontal, 4)
            } else if let updated = agent.lastUpdated {
                HStack(spacing: 6) {
                    // How good the reading behind the headline is. Green only for
                    // .exact — the tier Holmes is allowed to state facts from.
                    Circle()
                        .fill(confidenceColor)
                        .frame(width: 5, height: 5)
                    Text(agent.live.confidence.label.uppercased())
                        .font(NoirFonts.font(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(confidenceColor.opacity(0.85))
                        .tracking(0.8)
                    Text("· \(agent.live.source.label) · \(agent.modelBackend)")
                        .font(NoirFonts.font(size: 10, weight: .regular, design: .default))
                        .foregroundColor(NoirColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(updated, style: .relative)
                        .font(NoirFonts.font(size: 10, weight: .regular, design: .default))
                        .foregroundColor(NoirColors.textTertiary)
                        .fixedSize()
                }
                .padding(.horizontal, 4)
                .help(confidenceHelp)
            } else {
                EmptyView()
            }
        }
    }

    /// Exact = read from the DOM or a structured AX field. Structural = read from
    /// the Accessibility tree (reliable but coarse). Guessing = OCR, which Holmes
    /// will not quote.
    private var confidenceColor: Color {
        switch agent.live.confidence {
        case .exact:      return NoirColors.success
        case .structural: return NoirColors.calendarBlue
        case .inferred:   return NoirColors.textTertiary
        }
    }

    private var confidenceHelp: String {
        agent.live.provenance
    }

    // MARK: No meetings row

    private var noMeetingsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 10))
                .foregroundColor(NoirColors.textTertiary)
            Text("No meetings in next 30 min")
                .font(NoirFonts.font(size: 10, design: .default))
                .foregroundColor(NoirColors.textTertiary)
            Spacer()
            Button(action: { Task { await CalendarEngine.shared.scanUpcomingEvents() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(NoirColors.calendarBlue.opacity(0.70))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

}

// MARK: - Card entrance modifier

struct CardEntranceModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(
                .spring(response: 0.44, dampingFraction: 0.82).delay(delay),
                value: appeared
            )
    }
}

extension View {
    func cardEntrance(appeared: Bool, delay: Double) -> some View {
        modifier(CardEntranceModifier(appeared: appeared, delay: delay))
    }
}

// MARK: - Upcoming Meetings Card

struct UpcomingMeetingsCard: View {
    let meetings: [UpcomingMeeting]
    @State private var calendar = CalendarEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(NoirColors.calendarBlue.opacity(0.12))
                        .frame(width: 22, height: 22)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.calendarBlue)
                }
                Text("UPCOMING")
                    .font(NoirFonts.font(size: 9, weight: .bold, design: .default))
                    .foregroundColor(NoirColors.calendarBlue.opacity(0.80))
                    .tracking(2)
                Spacer()
                Button(action: { Task { await CalendarEngine.shared.debugFireNextMeeting() } }) {
                    Text("TEST")
                        .font(NoirFonts.font(size: 8, weight: .bold, design: .default))
                        .foregroundColor(Color.white.opacity(0.40))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Force-trigger the join alert for the next meeting")

                Button(action: { Task { await CalendarEngine.shared.scanUpcomingEvents() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.calendarBlue.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Re-scan calendar now")
            }

            ForEach(meetings.prefix(3)) { MeetingRow(meeting: $0) }
        }
        .padding(12)
        .background(NoirColors.glassSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(NoirColors.calendarBlue.opacity(0.22), lineWidth: 0.75)
        )
    }
}

struct MeetingRow: View {
    let meeting: UpcomingMeeting

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: meeting.meetingType?.icon ?? "video")
                .font(.system(size: 12))
                .foregroundColor(NoirColors.calendarBlue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(NoirFonts.font(size: 11, weight: .semibold, design: .default))
                    .foregroundColor(NoirColors.textPrimary)
                    .lineLimit(1)
                Text(meeting.meetingType?.rawValue ?? "Meeting")
                    .font(NoirFonts.font(size: 10, design: .default))
                    .foregroundColor(NoirColors.textTertiary)
            }

            Spacer()

            Text(meeting.timeLabel)
                .font(NoirFonts.font(size: 10, weight: .bold, design: .default))
                .foregroundColor(meeting.minutesUntil <= 2 ? NoirColors.error : NoirColors.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((meeting.minutesUntil <= 2 ? NoirColors.error : Color.white).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if meeting.meetingURL != nil {
                Button(action: { MeetingJoinEngine.shared.joinMeeting(meeting) }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(NoirColors.calendarBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Drafts Card (proactive playbooks)

struct DraftsCard: View {
    let drafts: [ProactiveDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 22, height: 22)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.textPrimary)
                }
                Text("DRAFTS")
                    .font(NoirFonts.font(size: 9, weight: .bold, design: .default))
                    .foregroundColor(NoirColors.textSecondary)
                    .tracking(2)
                Spacer()
                Button(action: { PlaybookEngine.shared.clearDrafts() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.iconSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear all drafts")
            }

            ForEach(drafts.prefix(4)) { DraftRow(draft: $0) }
        }
        .padding(12)
        .background(NoirColors.glassSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(NoirColors.glassStroke.opacity(0.6), lineWidth: 0.75)
        )
    }
}

struct DraftRow: View {
    let draft: ProactiveDraft
    @State private var isHovered = false

    var body: some View {
        Button(action: { ConfirmationBus.shared.proposeDraft(draft) }) {
            HStack(spacing: 10) {
                Image(systemName: kindIcon(draft.kind))
                    .font(.system(size: 12))
                    .foregroundColor(NoirColors.textSecondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title)
                        .font(NoirFonts.font(size: 11, weight: .semibold, design: .default))
                        .foregroundColor(NoirColors.textPrimary)
                        .lineLimit(1)
                    Text(draft.contextSummary)
                        .font(NoirFonts.font(size: 10, design: .default))
                        .foregroundColor(NoirColors.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text(draft.createdAt, style: .relative)
                    .font(NoirFonts.font(size: 9, design: .default))
                    .foregroundColor(NoirColors.textTertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Review this draft")
        .onHover { isHovered = $0 }
    }

    private func kindIcon(_ kind: DraftKind) -> String {
        switch kind {
        case .emailReply:       return "envelope.badge"
        case .promptSuggestion: return "wand.and.stars"
        case .repoBrief:        return "arrow.triangle.branch"
        case .linkedInPost:     return "text.badge.checkmark"
        case .meetingPrep:      return "calendar.badge.clock"
        case .chatReply:        return "bubble.left.and.bubble.right"
        case .aiAnswer:         return "magnifyingglass.circle"
        case .briefing:         return "sunrise"
        case .triage:           return "tray.full"
        case .followUp:         return "arrow.uturn.left.circle"
        case .prRadar:          return "dot.radiowaves.left.and.right"
        case .scheduleAlert:    return "exclamationmark.shield"
        case .wrapup:           return "moon.stars"
        }
    }
}

// MARK: - Window Button

struct WindowButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? Color.white.opacity(0.85) : NoirColors.iconSecondary)
                .frame(width: 26, height: 24)
                .background(isHovered ? Color.white.opacity(0.10) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 32, minHeight: 32)
        .help(tooltip)
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { isHovered = h } }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        MainPanelView(isVisible: .constant(true))
    }
    .frame(width: 500, height: 600)
}
