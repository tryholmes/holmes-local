import AppKit
import CoreText
import SwiftUI

/// The typography used on try-holmes.com: LT Remark for the wordmark and
/// display headings, Geist for reading, and Geist Mono for controls and data.
/// Fonts are bundled and registered for this process, without a system install.
enum NoirFonts {
    private static let registration: Void = {
        for ext in ["otf", "ttf"] {
            let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
            for url in urls {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func registerBundledFonts() { _ = registration }

    static func font(size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        registerBundledFonts()
        if design == .serif { return brand(size: size) }
        let family = design == .monospaced ? "GeistMono" : "Geist"
        return .custom("\(family)-\(suffix(for: weight))", fixedSize: size)
    }

    static func brand(size: CGFloat) -> Font {
        registerBundledFonts()
        return .custom("LTRemark-Regular", fixedSize: size)
    }

    static func appKit(size: CGFloat, weight: NSFont.Weight = .regular,
                       monospaced: Bool = false) -> NSFont {
        registerBundledFonts()
        let suffix: String
        if weight.rawValue >= NSFont.Weight.bold.rawValue { suffix = "Bold" }
        else if weight.rawValue >= NSFont.Weight.semibold.rawValue { suffix = "SemiBold" }
        else if weight.rawValue >= NSFont.Weight.medium.rawValue { suffix = "Medium" }
        else { suffix = "Regular" }
        return NSFont(name: "\(monospaced ? "GeistMono" : "Geist")-\(suffix)", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func suffix(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "Bold"
        case .semibold: return "SemiBold"
        case .medium: return "Medium"
        default: return "Regular"
        }
    }

    static func displayLarge() -> Font { brand(size: 44) }
    static func displayMedium() -> Font { brand(size: 28) }
    static func headline() -> Font { brand(size: 22) }
    static func title() -> Font { font(size: 15, weight: .semibold) }
    static func button() -> Font { font(size: 12, weight: .medium, design: .monospaced) }
    static func mono() -> Font { font(size: 13, design: .monospaced) }
    static func body() -> Font { font(size: 13) }
    static func caption() -> Font { font(size: 12) }
    static func code() -> Font { font(size: 12, design: .monospaced) }
}
