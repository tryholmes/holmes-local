import SwiftUI

// MARK: - ActionSuggestions

struct ActionSuggestions: View {
    let suggestions: [ActionSuggestion]
    let onSelect: (ActionSuggestion) -> Void
    let onApproveAll: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 22, height: 22)
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.iconPrimary)
                }
                Text("SUGGESTED ACTIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .tracking(2)

                Spacer()

                // Live count badge
                Text("\(suggestions.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }

            // Action rows with staggered entrance
            VStack(spacing: 1) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    ActionRow(suggestion: suggestion) { onSelect(suggestion) }
                        .opacity(appeared ? 1 : 0)
                        .offset(x: appeared ? 0 : -16)
                        .animation(
                            .spring(response: 0.40, dampingFraction: 0.78)
                            .delay(Double(index) * 0.06),
                            value: appeared
                        )
                }
            }

            // CTA row
            HStack(spacing: 8) {
                // Approve All — bold black pill
                Button(action: onApproveAll) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("Approve All")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        ZStack {
                            Color(hex: "0D0D0D")
                            LinearGradient(
                                colors: [Color.white.opacity(0.07), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)

                // Customize — ghost
                Button(action: {}) {
                    Text("Customize")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(NoirColors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(NoirColors.glassChrome)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .glassBorder(cornerRadius: 9)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            ZStack {
                NoirColors.glassSurface
                // Subtle top-shimmer gradient
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassBorder(cornerRadius: 12)
        .onAppear {
            withAnimation { appeared = true }
        }
        .onChange(of: suggestions.count) { _, _ in
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation { appeared = true }
            }
        }
    }
}

// MARK: - ActionRow

struct ActionRow: View {
    let suggestion: ActionSuggestion
    let onTap: () -> Void
    @State private var isHovered = false
    @State private var isSelected: Bool

    init(suggestion: ActionSuggestion, onTap: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onTap = onTap
        self._isSelected = State(initialValue: suggestion.isSelected)
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                isSelected.toggle()
            }
            onTap()
            CommandBus.shared.dispatch(suggestion.action)
        }) {
            HStack(spacing: 11) {
                // Animated checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.22),
                            lineWidth: 1.25
                        )
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                        )

                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.90))
                        .scaleEffect(isSelected ? 1.0 : 0.3)
                        .opacity(isSelected ? 1 : 0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.60), value: isSelected)
                }

                // Command text
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(isHovered ? NoirColors.textPrimary : NoirColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Hover arrow
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.55))
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -4)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = h }
        }
        .onChange(of: suggestion.isSelected) { _, v in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) { isSelected = v }
        }
    }
}

// MARK: - Data

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
        Color.black.opacity(0.55).ignoresSafeArea()
        ActionSuggestions(suggestions: ActionSuggestion.samples, onSelect: { _ in }, onApproveAll: {})
            .padding()
    }
    .frame(width: 400, height: 420)
}
