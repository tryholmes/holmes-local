import SwiftUI

// Retro pixel bevel card — raised or recessed Mac OS classic style
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    var raised: Bool = true
    let content: Content

    init(cornerRadius: CGFloat = 6, raised: Bool = true, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.raised = raised
        self.content = content()
    }

    var body: some View {
        content
            .background(NoirColors.warmWhite)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .pixelBevel(raised: raised, cornerRadius: cornerRadius)
            .shadow(color: NoirColors.glassShadow, radius: 8, x: 0, y: 3)
    }
}

// VisualEffectBlur retained for any callers that still need it
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct HeavyGlassBackground: View {
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(NoirColors.creamWhite)
            .pixelBevel(cornerRadius: cornerRadius)
    }
}

// MARK: - Refined Bevel Modifier
// Subtle single-border with a soft directional highlight — professional, not chunky.
struct PixelBevelModifier: ViewModifier {
    var raised: Bool = true
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                // Main border — warm charcoal, just 1px
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(NoirColors.charcoalDark.opacity(0.22), lineWidth: 1)

                // Subtle top-left highlight for depth
                RoundedRectangle(cornerRadius: cornerRadius - 0.5)
                    .stroke(
                        LinearGradient(
                            colors: raised
                                ? [Color.white.opacity(0.55), Color.clear]
                                : [NoirColors.charcoalDark.opacity(0.12), Color.white.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                    .padding(0.75)
            }
        )
    }
}

extension View {
    func pixelBevel(raised: Bool = true, cornerRadius: CGFloat = 6) -> some View {
        modifier(PixelBevelModifier(raised: raised, cornerRadius: cornerRadius))
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()

        GlassCard {
            VStack {
                Text("Holmes")
                    .font(NoirFonts.headline())
                    .foregroundColor(NoirColors.charcoalDark)
                Text("Zero Prompt AI")
                    .font(NoirFonts.body())
                    .foregroundColor(NoirColors.deepTeal)
            }
            .padding(40)
        }
    }
    .frame(width: 400, height: 300)
}
