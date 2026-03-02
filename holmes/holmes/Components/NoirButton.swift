import SwiftUI

struct NoirButton: View {
    let title: String
    let icon: String?
    let style: ButtonStyle
    let action: () -> Void

    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    enum ButtonStyle {
        case primary    // teal fill, cream text
        case secondary  // cream fill, teal text
        case ghost      // transparent, dark border
    }

    init(_ title: String, icon: String? = nil, style: ButtonStyle = .primary, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                Text(title)
                    .font(NoirFonts.button())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .pixelBevel(raised: !isPressed, cornerRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NoirColors.goldAccent, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.08), value: isPressed)
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:   return NoirColors.deepTeal
        case .secondary: return NoirColors.creamWhite
        case .ghost:     return Color.clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:   return NoirColors.creamWhite
        case .secondary: return NoirColors.deepTeal
        case .ghost:     return NoirColors.charcoalDark
        }
    }
}

struct NoirIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: { action() }) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.deepTeal)
                .frame(width: 30, height: 30)
                .background(NoirColors.warmWhite)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pixelBevel(cornerRadius: 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()

        VStack(spacing: 16) {
            NoirButton("Get Started", icon: "arrow.right") {}
            NoirButton("Continue", style: .secondary) {}
            NoirButton("Learn More", style: .ghost) {}
        }
        .padding()
    }
    .frame(width: 300, height: 300)
}
