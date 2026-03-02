import SwiftUI

struct ActionSuggestions: View {
    let suggestions: [ActionSuggestion]
    let onSelect: (ActionSuggestion) -> Void
    let onApproveAll: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.orangeAccent)

                Text("SUGGESTED ACTIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textSecondary)
                    .tracking(1)
            }

            VStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    ActionRow(suggestion: suggestion) { onSelect(suggestion) }
                }
            }

            HStack(spacing: 10) {
                NoirButton("Approve All", icon: "checkmark", style: .primary) { onApproveAll() }
                NoirButton("Customize", style: .secondary) {}
            }
        }
        .padding(14)
        .background(NoirColors.creamWhite)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .pixelBevel(cornerRadius: 6)
    }
}

struct ActionRow: View {
    let suggestion: ActionSuggestion
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(suggestion.isSelected ? NoirColors.goldAccent : NoirColors.iconSecondary, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(NoirColors.goldAccent)
                            .frame(width: 10, height: 10)
                            .opacity(suggestion.isSelected ? 1 : 0)
                    )

                Text(suggestion.title)
                    .font(NoirFonts.body())
                    .foregroundColor(NoirColors.charcoalDark)

                Spacer()

                if isHovered {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(NoirColors.deepTeal)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(isHovered ? NoirColors.lightBlue.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }
}

struct ActionSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    var isSelected: Bool = false
    
    static let samples: [ActionSuggestion] = [
        ActionSuggestion(title: "Auto-sum columns A-D", action: "excel_sum"),
        ActionSuggestion(title: "Format as currency", action: "format_currency"),
        ActionSuggestion(title: "Create revenue chart", action: "create_chart")
    ]
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        ActionSuggestions(suggestions: ActionSuggestion.samples, onSelect: { _ in }, onApproveAll: {})
            .padding()
    }
    .frame(width: 400, height: 400)
}
