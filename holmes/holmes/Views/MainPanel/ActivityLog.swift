import SwiftUI

struct ActivityLog: View {
    let activities: [ActivityItem]
    @State private var isExpanded = true
    @State private var rowsAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            Button(action: {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                    isExpanded.toggle()
                    if isExpanded { triggerRowAnimation() }
                }
            }) {
                HStack {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.07))
                                .frame(width: 22, height: 22)
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(NoirColors.iconSecondary)
                        }
                        Text("RECENT ACTIVITY")
                            .font(.system(size: 9, weight: .bold, design: .default))
                            .foregroundColor(NoirColors.textTertiary)
                            .tracking(2)
                    }
                    Spacer()

                    // Item count
                    if !isExpanded {
                        Text("\(activities.count)")
                            .font(.system(size: 9, weight: .bold, design: .default))
                            .foregroundColor(NoirColors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .transition(.opacity.combined(with: .scale))
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NoirColors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.spring(response: 0.30, dampingFraction: 0.72), value: isExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .background(NoirColors.glassDivider)
                    .transition(.opacity)

                VStack(spacing: 0) {
                    ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                        ActivityRow(activity: activity)
                            .opacity(rowsAppeared ? 1 : 0)
                            .offset(x: rowsAppeared ? 0 : -12)
                            .animation(
                                .spring(response: 0.38, dampingFraction: 0.76)
                                .delay(Double(index) * 0.05),
                                value: rowsAppeared
                            )

                        if index < activities.count - 1 {
                            Divider()
                                .background(NoirColors.glassDivider.opacity(0.5))
                                .padding(.leading, 40)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .push(from: .top).combined(with: .opacity),
                    removal: .push(from: .bottom).combined(with: .opacity)
                ))
            }
        }
        .background(
            ZStack {
                NoirColors.glassSurface
                LinearGradient(
                    colors: [Color.white.opacity(0.05), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassBorder(cornerRadius: 12)
        .onAppear { triggerRowAnimation() }
    }

    private func triggerRowAnimation() {
        rowsAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { rowsAppeared = true }
        }
    }
}

struct ActivityRow: View {
    let activity: ActivityItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator with subtle glow
            ZStack {
                Circle()
                    .fill(activity.statusColor.opacity(0.15))
                    .frame(width: 20, height: 20)
                Text(activity.statusPrefix)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .foregroundColor(activity.statusColor)
            }

            Text(activity.description)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundColor(isHovered ? NoirColors.textPrimary : NoirColors.textSecondary)
                .lineLimit(1)
                .animation(.easeInOut(duration: 0.12), value: isHovered)

            Spacer()

            Text(activity.timeAgo)
                .font(.system(size: 10, weight: .regular, design: .default))
                .foregroundColor(NoirColors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .onHover { h in isHovered = h }
        .contentShape(Rectangle())
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let description: String
    let timeAgo: String
    let status: ActivityStatus

    var statusColor: Color {
        switch status {
        case .completed: return NoirColors.success
        case .pending:   return Color.white.opacity(0.60)
        case .failed:    return NoirColors.error
        }
    }

    var statusPrefix: String {
        switch status {
        case .completed: return "✓"
        case .pending:   return "·"
        case .failed:    return "✗"
        }
    }

    enum ActivityStatus {
        case completed
        case pending
        case failed
    }

    static let samples: [ActivityItem] = [
        ActivityItem(description: "Renamed 5 files in Downloads", timeAgo: "2m ago",  status: .completed),
        ActivityItem(description: "Organized desktop icons",       timeAgo: "8m ago",  status: .completed),
        ActivityItem(description: "Updated Excel formulas",        timeAgo: "15m ago", status: .completed),
        ActivityItem(description: "Backed up documents",           timeAgo: "1h ago",  status: .completed),
    ]
}

#Preview {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        ActivityLog(activities: ActivityItem.samples).padding()
    }
    .frame(width: 400, height: 400)
}
