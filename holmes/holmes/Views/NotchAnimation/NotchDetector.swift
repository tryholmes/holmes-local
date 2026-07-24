// Notch geometry adapted from notchify (MIT, © 2026 fr0sty):
// https://github.com/fr0sty1122/notchify — `NotchMetrics.closedNotchSize(on:)`
// derives the REAL physical notch bounds from `auxiliaryTopLeftArea` /
// `auxiliaryTopRightArea` (macOS 12+) instead of a hardcoded width, so the HUD
// hugs the notch instead of floating in a "weird place." See THIRD_PARTY_NOTICES.md.

import AppKit

struct NotchDetector {
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }

        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }

        return false
    }

    /// The REAL closed-notch size on `screen`, computed from the areas macOS
    /// reports on either side of the notch. Falls back to sensible defaults on a
    /// notchless display (a slim menu-bar-height pill).
    static func closedNotchSize(on screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 210, height: 32) }

        var width: CGFloat = 210
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // +4 closes the sub-pixel seam between the notch sides and our fill.
            let computed = screen.frame.width - left.width - right.width + 4
            if computed.isFinite, computed > 120 {
                width = computed
            }
        }

        let safeTop = screen.safeAreaInsets.top
        let menuHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let rawHeight = safeTop > 0 ? safeTop : max(30, min(menuHeight, 36))
        // Round to whole pixels so the bar's bottom edge lands exactly on the
        // notch edge instead of a blurry sub-pixel offset.
        let height = (max(28, min(rawHeight, 42))).rounded()
        return CGSize(width: max(170, min(width, 260)).rounded(), height: height)
    }

    /// The fixed panel size the HUD window uses. Big enough to hold the widest
    /// expanded card; the transparent panel stays put while the CONTENT inside it
    /// grows/shrinks and stays pinned to the top (the notch).
    static let panelSize = CGSize(width: 640, height: 240)

    static var notchWidth: CGFloat { closedNotchSize(on: NSScreen.main).width }

    static var notchHeight: CGFloat { closedNotchSize(on: NSScreen.main).height }

    static var notchFrame: NSRect {
        guard hasNotch, let screen = NSScreen.main else { return .zero }
        let size = closedNotchSize(on: screen)
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
    }

    static var physicalNotchFrame: NSRect { notchFrame }
}
