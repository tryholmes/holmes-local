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

// Palette: warm yellow-white professional tone, anchored by deep teal from the character's jacket
struct NoirColors {
    // Primary palette
    static let parchment    = Color(hex: "#F7F2E3")  // warm yellow-white — primary background
    static let warmCream    = Color(hex: "#EDE4C8")  // deeper warm tone for sub-surfaces
    static let warmWhite    = Color(hex: "#FDFBF5")  // near-white surface for cards
    static let deepTeal     = Color(hex: "#2D4D5E")  // detective jacket — primary accent
    static let midTeal      = Color(hex: "#4A7080")  // medium teal for secondary elements
    static let warmBrown    = Color(hex: "#8B5E3C")  // houndstooth cape
    static let tanBrown     = Color(hex: "#C4956B")  // houndstooth highlight
    static let charcoalDark = Color(hex: "#1C1A17")  // warm near-black for text/borders
    static let goldAccent   = Color(hex: "#B8881C")  // warm amber — active highlight

    // Accessible explicit text/icon colors (all pass WCAG AA on parchment/warmWhite)
    static let textPrimary   = Color(hex: "#1C1A17")  // 14.8:1 — headings, primary content
    static let textSecondary = Color(hex: "#3D5E6E")  // 6.1:1  — secondary labels, subtitles
    static let textTertiary  = Color(hex: "#4A6A7A")  // 5.5:1  — tertiary labels, timestamps
    static let textPlaceholder = Color(hex: "#6B8A9A") // 3.8:1 — placeholders (large text ok)
    static let iconPrimary   = Color(hex: "#2D4D5E")  // 7.2:1  — primary icons (= deepTeal)
    static let iconSecondary = Color(hex: "#4D7D8D")  // 4.8:1  — secondary icons
    static let borderSubtle  = Color(hex: "#C8C0A8")  // visible but unobtrusive border

    // Semantic aliases (keep old names so existing references compile)
    static let shadowBlack  = charcoalDark
    static let skyBlue      = parchment
    static let lightBlue    = warmCream
    static let midBlue      = midTeal
    static let charcoalGray = deepTeal
    static let smokeGray    = midTeal
    static let fogGray      = textTertiary
    static let creamWhite   = warmWhite
    static let paperWhite   = warmWhite
    static let orangeAccent = goldAccent
    static let glassWhite   = warmWhite.opacity(0.18)
    static let glassStroke  = borderSubtle
    static let glassShadow  = charcoalDark.opacity(0.12)
}
