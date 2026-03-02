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
                VStack(spacing: 16) {
                    ContextCard(context: context)

                    ActionSuggestions(
                        suggestions: suggestions,
                        onSelect: { selectSuggestion($0) },
                        onApproveAll: { approveAllSuggestions() }
                    )

                    ActivityLog(activities: activities)
                }
                .padding(16)
            }
        }
        .frame(width: 380, height: 520)
        .background(NoirColors.skyBlue)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
        .shadow(color: NoirColors.charcoalDark.opacity(0.12), radius: 14, x: 0, y: 5)
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.creamWhite)
                    .rotationEffect(.degrees(-45))

                Text("HOLMES")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.creamWhite)
                    .tracking(2)
            }

            Spacer()

            HStack(spacing: 6) {
                WindowButton(icon: "minus") { isVisible = false }
                WindowButton(icon: "xmark") { isVisible = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(NoirColors.deepTeal)
    }

    private var retroBackground: some View {
        NoirColors.skyBlue
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
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isHovered ? NoirColors.deepTeal : NoirColors.creamWhite)
                .frame(width: 30, height: 28)
                .background(isHovered ? NoirColors.creamWhite : NoirColors.midBlue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NoirColors.goldAccent, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .frame(minWidth: 44, minHeight: 44)
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }
}

#Preview {
    ZStack {
        NoirColors.deepTeal.opacity(0.3).ignoresSafeArea()
        MainPanelView(isVisible: .constant(true))
    }
    .frame(width: 500, height: 600)
}
