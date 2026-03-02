import SwiftUI

struct ActivityLog: View {
    let activities: [ActivityItem]
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }) {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "5A7A8A"))
                        Text("RECENT ACTIVITY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "5A7A8A"))
                            .tracking(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "3D5A6A"))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().background(Color(hex: "1E2D38"))
                VStack(spacing: 0) {
                    ForEach(activities) { ActivityRow(activity: $0) }
                }
            }
        }
        .background(Color(hex: "111820"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "1E2D38"), lineWidth: 1))
    }
}

struct ActivityRow: View {
    let activity: ActivityItem

    var body: some View {
        HStack(spacing: 10) {
            Text(activity.statusPrefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(activity.statusColor)
                .frame(width: 12, alignment: .center)

            Text(activity.description)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "8FA8B0"))
                .lineLimit(1)

            Spacer()

            Text(activity.timeAgo)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "3D5A6A"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let description: String
    let timeAgo: String
    let status: ActivityStatus
    
    var statusColor: Color {
        switch status {
        case .completed: return Color(hex: "5DBB7A")
        case .pending:   return Color(hex: "B8881C")
        case .failed:    return Color(hex: "E05252")
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
