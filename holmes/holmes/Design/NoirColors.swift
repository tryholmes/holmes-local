import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// Shared native palette sampled from try-holmes.com.
struct NoirColors {
    static let canvas          = Color(hex: "060606")
    static let panelBackground = Color(hex: "121212")
    static let surface         = Color(hex: "1E1E1E")
    static let cream           = Color(hex: "EBE2D1")
    // Glass surface layers (layered over NSVisualEffectView blur)
    static let glassSurface    = Color.white.opacity(0.035)
    static let glassElevated   = Color.white.opacity(0.07)
    static let glassChrome     = Color.white.opacity(0.05)
    static let glassInput      = Color.white.opacity(0.07)

    // Borders
    static let glassBorder     = Color.white.opacity(0.12)
    static let glassDivider    = Color.white.opacity(0.10)
    static let glassStroke     = Color.white.opacity(0.16)
    static let glassInner      = Color.white.opacity(0.06)

    // Text
    static let textPrimary     = Color(hex: "F6F0E9")
    static let textSecondary   = Color.white.opacity(0.65)
    static let textTertiary    = Color.white.opacity(0.48)
    static let textPlaceholder = Color.white.opacity(0.38)

    // Icons
    static let iconPrimary     = cream
    static let iconSecondary   = Color.white.opacity(0.45)

    // Warm neutral accent, matching the website's labels and controls.
    static let accent          = cream
    static let accentDim       = Color.white.opacity(0.10)

    static let ctaBackground   = Color(hex: "2B1717")
    static let ctaForeground   = cream

    // Semantic
    static let success         = Color(hex: "8FA661")
    static let error           = Color(hex: "FF5E5E")
    static let calendarBlue    = Color(hex: "5EB5FF")

    // Shadows
    static let glassShadow     = Color.black.opacity(0.28)
    static let panelShadow     = Color.black.opacity(0.42)

    // Legacy aliases — all map to new glass tokens
    static let goldAccent      = accent
    static let accentBlack     = ctaBackground
    static let parchment       = glassSurface
    static let warmCream       = glassElevated
    static let warmWhite       = glassSurface
    static let deepTeal        = accent
    static let midTeal         = textSecondary
    static let warmBrown       = accent
    static let tanBrown        = accent
    static let charcoalDark    = textPrimary
    static let orangeAccent    = accent
    static let skyBlue         = Color.black.opacity(0.55)
    static let lightBlue       = glassSurface
    static let midBlue         = textSecondary
    static let charcoalGray    = glassSurface
    static let smokeGray       = textTertiary
    static let fogGray         = textTertiary
    static let creamWhite      = textPrimary
    static let paperWhite      = textPrimary
    static let shadowBlack     = Color.black.opacity(0.35)
    static let glassWhite      = glassSurface
    static let borderSubtle    = glassBorder
}
