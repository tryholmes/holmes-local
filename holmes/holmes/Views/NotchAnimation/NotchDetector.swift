// Ported from boring.notch (GPL-3.0, © TheBoredTeam and contributors):
// https://github.com/TheBoredTeam/boring.notch — sizing/matters.swift
// (openNotchSize / windowSize / cornerRadiusInsets constants and the
// getClosedNotchSize real-notch measurement from auxiliaryTopLeftArea /
// auxiliaryTopRightArea). Text/content adapted for Holmes; UI geometry kept
// identical. See THIRD_PARTY_NOTICES.md for license details.

import AppKit

/// boring.notch's exact geometry constants.
enum NotchGeometry {
    static let shadowPadding: CGFloat = 20
    static let openSize = CGSize(width: 640, height: 190)
    static let windowSize = CGSize(width: openSize.width, height: openSize.height + shadowPadding)
    static let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) =
        (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

    /// The REAL closed-notch size for `screen` — width measured from the areas
    /// macOS reports on either side of the physical notch (+4 to close the
    /// sub-pixel seam), height from the safe-area inset on notch Macs, or the
    /// menu-bar height on displays without one (drawing a "fake notch" island
    /// there, exactly like boring.notch does).
    @MainActor
    static func closedNotchSize(on screen: NSScreen?) -> CGSize {
        var notchHeight: CGFloat = 32
        var notchWidth: CGFloat = 185

        if let screen {
            if let topLeftPadding = screen.auxiliaryTopLeftArea?.width,
               let topRightPadding = screen.auxiliaryTopRightArea?.width {
                notchWidth = screen.frame.width - topLeftPadding - topRightPadding + 4
            }

            if screen.safeAreaInsets.top > 0 {
                notchHeight = screen.safeAreaInsets.top
            } else {
                notchHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            }
        }

        return CGSize(width: notchWidth, height: notchHeight)
    }
}

/// Compatibility shim — callers outside the notch module ask only this.
struct NotchDetector {
    @MainActor
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    @MainActor
    static var notchFrame: NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let size = NotchGeometry.closedNotchSize(on: screen)
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
    }
}
