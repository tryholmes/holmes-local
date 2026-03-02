import SwiftUI

struct ActionSuggestions: View {
    let suggestions: [ActionSuggestion]
    let onSelect: (ActionSuggestion) -> Void
    let onApproveAll: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "B8881C"))
                Text("SUGGESTED ACTIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
                    .tracking(2)
            }

            VStack(spacing: 2) {
                ForEach(suggestions) { suggestion in
                    ActionRow(suggestion: suggestion) { onSelect(suggestion) }
                }
            }

            HStack(spacing: 8) {
                // Approve All
                Button(action: onApproveAll) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Text("Approve All")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Color(hex: "111820"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(hex: "B8881C"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                // Customize
                Button(action: {}) {
                    Text("Customize")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "5A7A8A"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(hex: "0D1318"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "1E2D38"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color(hex: "111820"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "1E2D38"), lineWidth: 1))
    }
}

struct ActionRow: View {
    let suggestion: ActionSuggestion
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Checkbox
                RoundedRectangle(cornerRadius: 3)
                    .stroke(suggestion.isSelected ? Color(hex: "B8881C") : Color(hex: "2A3D4A"), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(suggestion.isSelected ? Color(hex: "B8881C").opacity(0.2) : Color.clear)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: "B8881C"))
                            .opacity(suggestion.isSelected ? 1 : 0)
                    )

                Text(suggestion.title)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(isHovered ? Color(hex: "E8D5A3") : Color(hex: "8FA8B0"))

                Spacer()

                if isHovered {
                    Text("❯")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "B8881C"))
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(isHovered ? Color(hex: "0D1318") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { isHovered = h } }
    }
}

struct ActionSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    var isSelected: Bool = false
    
    static let samples: [ActionSuggestion] = [
        ActionSuggestion(title: "/run  Complete this form automatically", action: "run_form"),
        ActionSuggestion(title: "/watch  Monitor screen for changes",      action: "watch_screen"),
        ActionSuggestion(title: "/plan  Break this task into steps",        action: "plan_task"),
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
