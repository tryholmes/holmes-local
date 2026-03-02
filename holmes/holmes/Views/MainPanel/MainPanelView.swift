import SwiftUI

struct MainPanelView: View {
    @Binding var isVisible: Bool
    @State private var context: DetectedContext = .placeholder
    @State private var suggestions: [ActionSuggestion] = ActionSuggestion.samples
    @State private var activities: [ActivityItem] = ActivityItem.samples
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 12) {
                    ContextCard(context: context)
                    ActionSuggestions(
                        suggestions: suggestions,
                        onSelect: { selectSuggestion($0) },
                        onApproveAll: { approveAllSuggestions() }
                    )
                    ActivityLog(activities: activities)
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
        if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            suggestions[index].isSelected.toggle()
        }
    }
    
    private func approveAllSuggestions() {
        for index in suggestions.indices {
            suggestions[index].isSelected = true
        }
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
