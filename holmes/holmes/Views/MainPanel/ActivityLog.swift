import SwiftUI

struct ActivityLog: View {
    let activities: [ActivityItem]
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(NoirAnimations.smooth) { isExpanded.toggle() }
            }) {
                HStack {
                    Text("RECENT ACTIVITY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.deepTeal)
                        .tracking(1)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.deepTeal)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .background(NoirColors.charcoalDark.opacity(0.25))

                VStack(spacing: 0) {
                    ForEach(activities) { ActivityRow(activity: $0) }
                }
                .padding(.vertical, 6)
            }
        }
        .background(NoirColors.creamWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
    }
}

struct ActivityRow: View {
    let activity: ActivityItem
    
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(activity.statusColor)
                .frame(width: 5, height: 5)

            Text(activity.description)
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.charcoalDark)
                .lineLimit(1)

            Spacer()

            Text(activity.timeAgo)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(NoirColors.iconSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let description: String
    let timeAgo: String
    let status: ActivityStatus
    
    var statusColor: Color {
        switch status {
        case .completed: return NoirColors.deepTeal
        case .pending:   return NoirColors.orangeAccent
        case .failed:    return Color(hex: "#C0392B")
        }
    }
    
    enum ActivityStatus {
        case completed
        case pending
        case failed
    }
    
    static let samples: [ActivityItem] = [
        ActivityItem(description: "Renamed 5 files in Downloads", timeAgo: "2m ago", status: .completed),
        ActivityItem(description: "Organized desktop icons", timeAgo: "8m ago", status: .completed),
        ActivityItem(description: "Updated Excel formulas", timeAgo: "15m ago", status: .completed),
        ActivityItem(description: "Backed up documents", timeAgo: "1h ago", status: .completed)
    ]
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        ActivityLog(activities: ActivityItem.samples).padding()
    }
    .frame(width: 400, height: 400)
}
