import SwiftUI

struct ContextCard: View {
    let context: DetectedContext
    @State private var appeared = false
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 22, height: 22)
                    Image(systemName: context.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoirColors.iconPrimary)
                }
                Text("CONTEXT DETECTED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .tracking(2)

                Spacer()

                // Live dot
                Circle()
                    .fill(NoirColors.success)
                    .frame(width: 5, height: 5)
                    .overlay(
                        Circle()
                            .fill(NoirColors.success)
                            .frame(width: 5, height: 5)
                            .scaleEffect(appeared ? 1.8 : 1.0)
                            .opacity(appeared ? 0 : 0.5)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: appeared)
                    )
            }

            Text(context.description)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(NoirColors.textSecondary)
                .lineLimit(2)
                .lineSpacing(3)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 4)
                .animation(.spring(response: 0.45, dampingFraction: 0.80).delay(0.08), value: appeared)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                NoirColors.glassSurface
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassBorder(cornerRadius: 12)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.42, dampingFraction: 0.80), value: appeared)
        .onAppear { appeared = true }
    }
}

struct DetectedContext {
    let icon: String
    let description: String
    let appName: String

    static let placeholder = DetectedContext(
        icon: "doc.text",
        description: "Working on \"Project Proposal.docx\" in Microsoft Word",
        appName: "Microsoft Word"
    )
}

#Preview {
    ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        ContextCard(context: .placeholder).padding()
    }
    .frame(width: 400, height: 200)
}
