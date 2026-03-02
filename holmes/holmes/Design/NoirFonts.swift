import SwiftUI

// Typography scale for Holmes:
// Monospaced for brand identity (headers, labels, buttons, data).
// SF Pro for prose/descriptions where readability matters.
struct NoirFonts {
    // Monospaced — brand, labels, structural chrome
    static func displayLarge() -> Font {
        .system(size: 44, weight: .bold, design: .monospaced)
    }

    static func displayMedium() -> Font {
        .system(size: 28, weight: .bold, design: .monospaced)
    }

    static func headline() -> Font {
        .system(size: 18, weight: .bold, design: .monospaced)
    }

    static func title() -> Font {
        .system(size: 15, weight: .semibold, design: .monospaced)
    }

    static func button() -> Font {
        .system(size: 13, weight: .bold, design: .monospaced)
    }

    static func mono() -> Font {
        .system(size: 13, weight: .regular, design: .monospaced)
    }

    // SF Pro — prose, descriptions, conversational content
    static func body() -> Font {
        .system(size: 13, weight: .regular, design: .default)
    }

    static func caption() -> Font {
        .system(size: 12, weight: .regular, design: .default)
    }

    // Explicit code style for technical output
    static func code() -> Font {
        .system(size: 12, weight: .regular, design: .monospaced)
    }
}
