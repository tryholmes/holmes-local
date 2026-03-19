import SwiftUI

// Apple-glass frosted card
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    var raised: Bool = true
    let content: Content

    init(cornerRadius: CGFloat = 12, raised: Bool = true, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.raised = raised
        self.content = content()
    }

    var body: some View {
        content
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    NoirColors.glassSurface
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .glassBorder(cornerRadius: cornerRadius)
            .shadow(color: NoirColors.glassShadow, radius: 12, x: 0, y: 4)
    }
}

// True NSVisualEffectView blur — shows desktop/windows behind the panel
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

// Full-panel glass background for floating windows
struct AppleGlassBackground: View {
    var cornerRadius: CGFloat = 16
    var material: NSVisualEffectView.Material = .hudWindow

    var body: some View {
        ZStack {
            VisualEffectBlur(material: material, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(0.06))
        }
    }
}

struct HeavyGlassBackground: View {
    var cornerRadius: CGFloat = 4

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(NoirColors.glassElevated)
        }
        .glassBorder(cornerRadius: cornerRadius)
    }
}

// MARK: - Glass Border Modifier

struct GlassBorderModifier: ViewModifier {
    var cornerRadius: CGFloat = 12
    var lineWidth: CGFloat = 0.75

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(NoirColors.glassBorder, lineWidth: lineWidth)

                // Inner top-left highlight — classic Apple glass shimmer
                RoundedRectangle(cornerRadius: cornerRadius - 0.5)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
                    .padding(lineWidth / 2)
            }
        )
    }
}

// Legacy modifier kept for callers that use .pixelBevel(...)
struct PixelBevelModifier: ViewModifier {
    var raised: Bool = true
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(NoirColors.glassBorder, lineWidth: 0.75)

                RoundedRectangle(cornerRadius: cornerRadius - 0.5)
                    .stroke(
                        LinearGradient(
                            colors: raised
                                ? [Color.white.opacity(0.45), Color.clear]
                                : [Color.clear, Color.white.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
                    .padding(0.5)
            }
        )
    }
}

extension View {
    func pixelBevel(raised: Bool = true, cornerRadius: CGFloat = 12) -> some View {
        modifier(PixelBevelModifier(raised: raised, cornerRadius: cornerRadius))
    }

    func glassBorder(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 0.75) -> some View {
        modifier(GlassBorderModifier(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()

        GlassCard {
            VStack {
                Text("Holmes")
                    .font(NoirFonts.headline())
                    .foregroundColor(NoirColors.textPrimary)
                Text("Zero Prompt AI")
                    .font(NoirFonts.body())
                    .foregroundColor(NoirColors.textSecondary)
            }
            .padding(40)
        }
    }
    .frame(width: 400, height: 300)
}
