// Portions derived from OpenClicky (MIT, © 2025 Jason Kneen), which embeds a
// subset of trycua/cua-driver (MIT, © 2025 Cua AI, Inc.,
// https://github.com/trycua/cua). See THIRD_PARTY_NOTICES.md.

import AppKit
import CoreGraphics
import Foundation

// MARK: - ComputerUseCapture
// One self-consistent frame for the computer-use loop: the base64 JPEG the model
// actually sees, PLUS the coordinate bookkeeping needed to round-trip a click back
// onto the physical screen. Every field is captured together so a click can never
// be mapped through one frame's pixel dims and another frame's display geometry.
//
// Three fields form the load-bearing pair of coordinate spaces:
//   • screenshotWidthInPixels / screenshotHeightInPixels — the EXACT pixel size of
//     `jpegBase64`, and the same numbers declared to Claude as display_width_px /
//     display_height_px. The model returns coordinates in THIS space (top-left).
//   • displayWidthInPoints / displayHeightInPoints + displayFrame — the AppKit
//     (bottom-left origin) geometry of the physical display those pixels belong to,
//     used to scale + Y-flip + offset the model's coordinate back to a global point.
struct ComputerUseCapture {
    /// The screenshot the model reasons about, JPEG-encoded and base64'd. Its real
    /// pixel dimensions equal `screenshotWidthInPixels` × `screenshotHeightInPixels`
    /// (guaranteed by the retina-safe resize — never 2× on a Retina display).
    let jpegBase64: String
    /// AppKit frame of the captured display (bottom-left origin, in the coordinate
    /// space of `NSEvent.mouseLocation`). Its `.origin` is the global offset used to
    /// turn a display-local point into a global AppKit point.
    let displayFrame: CGRect
    /// Captured display width/height in POINTS (from `NSScreen.frame`).
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    /// Declared screenshot width/height in PIXELS — exactly the size the JPEG was
    /// resized to and exactly what is declared to the computer tool. The model's
    /// returned coordinates live in this space.
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

// MARK: - WindowCapture
// Coordinate-space capture + bookkeeping for the computer-use engine. It reuses
// ScreenEngine's on-demand raw CGImage grab (which already excludes Holmes' own
// windows and blank-checks the frame) but deliberately does NOT go through
// VisionEncoder — VisionEncoder downscales to a 1024 long-edge, which would NOT
// match the pixel dims declared to the model and would silently corrupt Claude's
// pixel-counting. Instead we resize to an aspect-matched, Anthropic-recommended
// resolution via the retina-safe NSBitmapImageRep exact-pixel path adapted from
// OpenClicky's ElementLocationDetector (the single biggest accuracy lever).
//
// @MainActor because it touches ScreenEngine (@MainActor) and NSScreen (main
// thread). The two pure helpers — `recommendedResolution` and
// `modelPointToGlobalAppKit` — are `nonisolated` so the engine can call them from
// any context while posting events.
@MainActor
enum WindowCapture {

    // MARK: - Declared resolution (resolved once per run, kept in sync)

    /// The current run's chosen screenshot resolution, in pixels. HolmesBrain reads
    /// these to build the `computer` tool declaration (display_width_px /
    /// display_height_px) so the tool declaration and the screenshots agree. They
    /// are (re)resolved from the captured display's aspect ratio by
    /// `resolveForCurrentRun()` and by every `captureForModel()`.
    private(set) static var declaredWidth: Int = 1280
    private(set) static var declaredHeight: Int = 800

    /// Anthropic-recommended Computer Use resolutions, paired with their aspect
    /// ratios (OpenClicky ElementLocationDetector.swift:33-37). Intentionally small:
    /// the API downsamples larger frames, which degrades coordinate precision.
    /// We pick the one whose aspect is closest to the display to avoid stretching
    /// the image Claude sees (distortion mainly wrecks X-axis accuracy).
    nonisolated private static let supportedResolutions: [(w: Int, h: Int, aspect: Double)] = [
        (1024, 768, 1024.0 / 768.0),  // 4:3    = 1.333 (legacy displays)
        (1280, 800, 1280.0 / 800.0),  // 16:10  = 1.600 (MacBook Air/Pro, most Macs)
        (1366, 768, 1366.0 / 768.0)   // ~16:9  = 1.779 (external monitors, ultrawide)
    ]

    /// Picks the recommended resolution whose aspect ratio best matches `aspect`
    /// (width / height). Pure and side-effect free, so it is safe to call from any
    /// actor. (OpenClicky ElementLocationDetector.swift:128-148.)
    nonisolated static func recommendedResolution(forAspect aspect: Double) -> (w: Int, h: Int) {
        var best = (w: 1280, h: 800)
        var smallestDifference = Double.greatestFiniteMagnitude
        for resolution in supportedResolutions {
            let difference = abs(aspect - resolution.aspect)
            if difference < smallestDifference {
                smallestDifference = difference
                best = (resolution.w, resolution.h)
            }
        }
        return best
    }

    /// Primes `declaredWidth`/`declaredHeight` from the captured display's aspect
    /// BEFORE the first capture, so HolmesBrain can declare the computer tool with
    /// the exact pixel dims `captureForModel()` will produce. Uses the identical
    /// computation as `captureForModel()`, so the two agree by construction.
    static func resolveForCurrentRun() {
        let geometry = displayGeometry(for: targetDisplayID())
        let resolution = recommendedResolution(
            forAspect: Double(geometry.widthPts) / Double(max(1, geometry.heightPts))
        )
        declaredWidth = resolution.w
        declaredHeight = resolution.h
    }

    // MARK: - Capture

    /// Grabs a fresh screenshot and packages it for the model.
    ///
    /// Returns nil (never a black frame) when capture fails or the frame is blank —
    /// `ScreenEngine.grabScreenshotForVision()` already blank-checks and returns nil
    /// on a stale Screen Recording grant, so rejecting nil here guarantees the model
    /// never reasons about — or clicks on — black pixels.
    static func captureForModel() async -> ComputerUseCapture? {
        // Target the display the user is actually looking at — the one under the
        // cursor — so a question asked (or an action taken) on a secondary monitor
        // is captured, reasoned about, and drawn on THAT screen, not the primary.
        // Both the screenshot and the geometry are pinned to this same display so
        // the coordinate mapping stays internally consistent.
        let target = targetDisplayID()

        // Reuse ScreenEngine's on-demand grab: a fresh CGImage of the target display
        // that already EXCLUDES Holmes' own windows and is verified non-blank.
        guard let cgImage = await ScreenEngine.shared.grabScreenshotForVision(targetDisplayID: target) else { return nil }

        // Geometry of the SAME display the screenshot belongs to.
        let geometry = displayGeometry(for: target)

        // Aspect-match the target resolution to the display, then LOCK it into the
        // declared dims. Recording screenshot pixels == declared dims is the invariant
        // that keeps Claude's returned coordinates interpretable.
        let resolution = recommendedResolution(
            forAspect: Double(geometry.widthPts) / Double(max(1, geometry.heightPts))
        )
        declaredWidth = resolution.w
        declaredHeight = resolution.h

        guard let base64 = retinaSafeResizedJPEGBase64(
            cgImage, toWidth: resolution.w, toHeight: resolution.h
        ) else { return nil }

        return ComputerUseCapture(
            jpegBase64: base64,
            displayFrame: geometry.frame,
            displayWidthInPoints: geometry.widthPts,
            displayHeightInPoints: geometry.heightPts,
            screenshotWidthInPixels: resolution.w,
            screenshotHeightInPixels: resolution.h
        )
    }

    // MARK: - Coordinate mapping (model pixels → global AppKit point)

    /// Maps a coordinate the model returned — in DECLARED-RESOLUTION PIXEL space,
    /// TOP-LEFT origin — into a GLOBAL AppKit point (bottom-left origin, union of
    /// all displays). The output is exactly what `InputController.Mouse.leftClick`
    /// expects; that layer then does the final per-display AppKit→Quartz conversion.
    ///
    /// Pipeline (OpenClicky ElementLocationDetector.swift:103-121 for scale + flip,
    /// plus `+ displayFrame.origin` for the multi-display global offset):
    ///   1. clamp to the screenshot's pixel bounds — Claude occasionally returns a
    ///      coordinate slightly outside the declared dims, which would otherwise map
    ///      off-screen after scaling.
    ///   2. scale from pixel space into display POINT space.
    ///   3. Y-flip: top-left origin (model / CoreGraphics) → bottom-left (AppKit).
    ///   4. offset by the display's global AppKit origin.
    /// Pure and side-effect free, so it is safe to call from any actor.
    nonisolated static func modelPointToGlobalAppKit(_ p: CGPoint, in cap: ComputerUseCapture) -> CGPoint {
        // 1. Clamp to the declared screenshot pixel bounds.
        let clampedX = max(0, min(p.x, CGFloat(cap.screenshotWidthInPixels)))
        let clampedY = max(0, min(p.y, CGFloat(cap.screenshotHeightInPixels)))

        // 2. Scale pixel space → display point space.
        let scaleX = CGFloat(cap.displayWidthInPoints) / CGFloat(max(1, cap.screenshotWidthInPixels))
        let scaleY = CGFloat(cap.displayHeightInPoints) / CGFloat(max(1, cap.screenshotHeightInPixels))
        let localX = clampedX * scaleX
        let localYFromTop = clampedY * scaleY

        // 3. Y-flip to AppKit's bottom-left origin (display-local).
        let localYFromBottom = CGFloat(cap.displayHeightInPoints) - localYFromTop

        // 4. Offset by the display's global AppKit origin.
        return CGPoint(
            x: cap.displayFrame.origin.x + localX,
            y: cap.displayFrame.origin.y + localYFromBottom
        )
    }

    // MARK: - Private helpers

    /// AppKit geometry of the primary display — the display ScreenEngine captures
    /// (`content.displays.first`). Built via the displayID→NSScreen map from
    /// OpenClicky CompanionScreenCaptureUtility.swift:106-121 so we read AppKit
    /// (bottom-left origin) frames, which share the coordinate system of
    /// `NSEvent.mouseLocation` and the AppKit→Quartz conversion InputController runs.
    /// Using the captured display's own frame (not the cursor's) keeps the mapping
    /// correct: the pixels belong to the primary display, so a click must map there.
    /// The display the user is looking at: the one whose frame contains the cursor,
    /// falling back to the main display. Capture and geometry both key off this so
    /// ask/point and click land on the screen the user actually means.
    static func targetDisplayID() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return id
        }
        return CGMainDisplayID()
    }

    private static func displayGeometry(for displayID: CGDirectDisplayID) -> (frame: CGRect, widthPts: Int, heightPts: Int) {
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }
        let screen = nsScreenByDisplayID[displayID]
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return (frame, Int(frame.width.rounded()), Int(frame.height.rounded()))
    }

    /// Resizes a CGImage to EXACT pixel dimensions and returns base64 JPEG.
    ///
    /// **Critical retina fix** (OpenClicky ElementLocationDetector.swift:279-325):
    /// draws into an `NSBitmapImageRep` created with explicit `pixelsWide/pixelsHigh`
    /// instead of `NSImage.lockFocus()`. On a 2× (Retina) display, lockFocus produces
    /// a bitmap at TWICE the requested size (e.g. 2560×1600 for a 1280×800 target),
    /// so the JPEG would be double the resolution declared to the computer tool and
    /// Claude's pixel-counting would return coordinates in the wrong scale. This path
    /// guarantees the output is exactly `targetWidth` × `targetHeight` pixels.
    private static func retinaSafeResizedJPEGBase64(
        _ cgImage: CGImage,
        toWidth targetWidth: Int,
        toHeight targetHeight: Int
    ) -> String? {
        let source = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )

        // Bitmap with EXACT pixel dimensions — bypasses NSImage's Retina-aware
        // coordinate system that would otherwise double the real pixel count.
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        // Point size == pixel size (1:1, no Retina scaling).
        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.85]
        ) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }
}
