// Geometry derived from boring.notch (GPL-3.0, © TheBoredTeam and contributors).
// Holmes keeps its curved island while reserving the physical camera housing
// before laying out any text or controls. See THIRD_PARTY_NOTICES.md.

import AppKit

enum NotchGeometry {
    static let shadowPadding: CGFloat = 20
    static let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) =
        (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

    /// All dimensions are points. One snapshot drives both the SwiftUI layout
    /// and its AppKit host, including displays with a nonzero/negative origin.
    struct Layout: Equatable {
        let screenFrame: CGRect
        let anchorX: CGFloat
        let hardwareHeight: CGFloat
        let closedSize: CGSize
        let contentTopInset: CGFloat
        let openSize: CGSize
        let compactSize: CGSize
        let windowSize: CGSize

        var windowFrame: CGRect {
            let x = min(max(screenFrame.minX, anchorX - windowSize.width / 2),
                        screenFrame.maxX - windowSize.width)
            return CGRect(x: x, y: screenFrame.maxY - windowSize.height,
                          width: windowSize.width, height: windowSize.height)
        }
    }

    /// Pure calculation so different display scales, cutouts and arrangements
    /// can be verified without moving a real window or requiring a notched Mac.
    static func layout(screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                       leftAreaWidth: CGFloat? = nil, rightAreaWidth: CGFloat? = nil) -> Layout {
        let hardwareHeight = max(0, safeAreaTop)
        var notchWidth: CGFloat = 185
        var anchorX = screenFrame.midX
        if hardwareHeight > 0, let left = leftAreaWidth, let right = rightAreaWidth,
           left >= 0, right >= 0, left + right < screenFrame.width {
            let gap = screenFrame.width - left - right
            notchWidth = gap + 4 // cover the seam around the camera housing
            anchorX = screenFrame.minX + left + gap / 2
        }
        let availableWidth = max(1, screenFrame.width - shadowPadding * 2)
        let openWidth = min(640, availableWidth)
        let closedHeight = hardwareHeight > 0
            ? hardwareHeight : max(24, screenFrame.maxY - visibleFrame.maxY)
        let closedSize = CGSize(width: min(notchWidth, openWidth), height: closedHeight)
        // The host reaches the screen edge; the whole hardware band stays empty.
        let contentTop = hardwareHeight > 0 ? hardwareHeight + 10 : 12
        let availableHeight = max(1, screenFrame.height - shadowPadding)
        let openSize = CGSize(width: openWidth, height: min(contentTop + 200, availableHeight))
        let compactSize = CGSize(width: min(openWidth, max(460, closedSize.width + 48)),
                                 height: min(contentTop + 64, availableHeight))
        let windowSize = CGSize(width: min(screenFrame.width, openWidth + shadowPadding * 2),
                                height: min(screenFrame.height, openSize.height + shadowPadding))
        return Layout(screenFrame: screenFrame, anchorX: anchorX, hardwareHeight: hardwareHeight,
                      closedSize: closedSize, contentTopInset: contentTop, openSize: openSize,
                      compactSize: compactSize, windowSize: windowSize)
    }

    @MainActor
    static func layout(on screen: NSScreen?) -> Layout {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return layout(screenFrame: frame, visibleFrame: screen?.visibleFrame ?? frame,
                      safeAreaTop: screen?.safeAreaInsets.top ?? 0,
                      leftAreaWidth: screen?.auxiliaryTopLeftArea?.width,
                      rightAreaWidth: screen?.auxiliaryTopRightArea?.width)
    }

    @MainActor
    static func closedNotchSize(on screen: NSScreen?) -> CGSize {
        layout(on: screen).closedSize
    }
}

struct NotchDetector {
    /// Keep the island attached to the physical notch when another display is
    /// the main screen. Without a notch, use the current primary workspace.
    @MainActor
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    @MainActor
    static var hasNotch: Bool {
        (preferredScreen?.safeAreaInsets.top ?? 0) > 0
    }

    @MainActor
    static var notchFrame: NSRect {
        guard let screen = preferredScreen else { return .zero }
        let geometry = NotchGeometry.layout(on: screen)
        return NSRect(x: geometry.anchorX - geometry.closedSize.width / 2,
                      y: screen.frame.maxY - geometry.closedSize.height,
                      width: geometry.closedSize.width, height: geometry.closedSize.height)
    }
}
