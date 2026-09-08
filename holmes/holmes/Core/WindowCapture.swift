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
//     `jpegBase64`, and the same numbers declared to the model as the screenshot
//     size in the `computer` tool's description and the system prompt. The model
//     returns coordinates in THIS space (top-left) — or, when
//     OllamaConfig.coordinateSpace is .normalized1000, in a 0-1000 grid that
//     `modelPointToScreenshotPixels` maps onto this space first.
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
// match the pixel dims declared to the model and would silently corrupt the
// model's pixel-counting. Instead we resize to an aspect-matched resolution from
// the small set below via the retina-safe NSBitmapImageRep exact-pixel path
// adapted from OpenClicky's ElementLocationDetector (the single biggest accuracy
// lever).
//
// @MainActor because it touches ScreenEngine (@MainActor) and NSScreen (main
// thread). The two pure helpers — `recommendedResolution` and
// `modelPointToGlobalAppKit` — are `nonisolated` so the engine can call them from
// any context while posting events.
@MainActor
enum WindowCapture {

    // MARK: - Declared resolution (resolved once per run, kept in sync)

    /// The current run's chosen screenshot resolution, in pixels. HolmesBrain reads
    /// these to state the pixel space in the `computer` tool's description and
    /// the system prompt, so the tool declaration and the screenshots agree. They
    /// are (re)resolved from the captured display's aspect ratio by
    /// `resolveForCurrentRun()` and by every `captureForModel()`.
    private(set) static var declaredWidth: Int = 1280
    private(set) static var declaredHeight: Int = 800

    /// Computer-use capture resolutions, paired with their aspect ratios.
    ///
    /// 1280-CLASS, ON PURPOSE. The hosted build used 1080p-class frames because a
    /// frontier vision model accepts them at full detail. A LOCAL vision model
    /// (qwen3-vl and friends) spends roughly one token per 32×32 block, so a
    /// 1920×1200 frame costs ~2.2k tokens of a 16k context — and every turn of a
    /// computer session carries one or two frames. 1280×800 is ~1k tokens, which
    /// keeps a multi-step session inside the window and roughly halves per-turn
    /// latency on a laptop, while UI text is still legible for the model. Small
    /// targets get `zoom_screen` (a magnified crop) rather than a bigger frame.
    ///
    /// We still pick the aspect closest to the display so the image the model sees
    /// is never stretched (distortion mainly wrecks X-axis accuracy).
    nonisolated private static let supportedResolutions: [(w: Int, h: Int, aspect: Double)] = [
        (1024, 768, 1024.0 / 768.0),    // 4:3   = 1.333 (legacy displays)
        (1280, 800, 1280.0 / 800.0),    // 16:10 = 1.600 (MacBook Air/Pro, most Macs)
        (1280, 720, 1280.0 / 720.0)     // 16:9  = 1.778 (external monitors, ultrawide)
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
        // that keeps the model's returned coordinates interpretable.
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

    // MARK: - Zoom (read-only magnification of one region)

    /// Crops a region of the CURRENT screen — expressed in the model's screenshot
    /// pixel space (top-left origin, the same space clicks use) — and returns it
    /// magnified so fine text and small controls are legible.
    ///
    /// READ-ONLY BY CONSTRUCTION: it deliberately does NOT touch `declaredWidth` /
    /// `declaredHeight` or the run's `lastCapture`, so click coordinates keep
    /// referring to the full-frame screenshot. Letting the model actually LOOK
    /// closer at a control beats making it reason harder about a blurry one, but
    /// only if the coordinate space it clicks in never moves underneath it.
    ///
    /// Returns nil when capture fails or the requested region is degenerate.
    static func captureRegionBase64(x: Int, y: Int, width: Int, height: Int) async -> (base64: String, w: Int, h: Int)? {
        guard width > 0, height > 0 else { return nil }
        guard let cgImage = await ScreenEngine.shared.grabScreenshotForVision(targetDisplayID: targetDisplayID())
        else { return nil }

        // Model pixel space → raw capture pixels. The raw frame is the display's
        // native (retina) size, so this scale is normally > 1 — which is exactly
        // where the extra detail comes from.
        let scaleX = Double(cgImage.width) / Double(max(1, declaredWidth))
        let scaleY = Double(cgImage.height) / Double(max(1, declaredHeight))

        // Clamp into the frame. CGImage.cropping uses a top-left origin, matching
        // the model's coordinate space, so no Y-flip belongs here.
        let rawX = max(0, min(Double(x) * scaleX, Double(cgImage.width) - 1))
        let rawY = max(0, min(Double(y) * scaleY, Double(cgImage.height) - 1))
        let rawW = max(1, min(Double(width) * scaleX, Double(cgImage.width) - rawX))
        let rawH = max(1, min(Double(height) * scaleY, Double(cgImage.height) - rawY))
        guard let cropped = cgImage.cropping(to: CGRect(x: rawX, y: rawY, width: rawW, height: rawH))
        else { return nil }

        // Magnify so small text is readable, but cap it: one zoom must not
        // dominate the context window (long edge ≤ 1512px, never beyond 3× native).
        let longEdge = Double(max(cropped.width, cropped.height))
        let scale = min(3.0, max(1.0, 1512.0 / max(1.0, longEdge)))
        let outW = Int((Double(cropped.width) * scale).rounded())
        let outH = Int((Double(cropped.height) * scale).rounded())
        guard let base64 = retinaSafeResizedJPEGBase64(cropped, toWidth: outW, toHeight: outH)
        else { return nil }
        return (base64, outW, outH)
    }

    // MARK: - Model coordinate space (pixels vs. a normalized 0-1000 grid)

    /// THE ONE PLACE the model's coordinate convention is interpreted. Holmes asks
    /// for pixels of the declared screenshot, but some local vision models are
    /// trained to answer in a normalized 0-1000 grid regardless of what the prompt
    /// says; OllamaConfig.coordinateSpace lets the user flip that at runtime.
    /// Converts a point as the model gave it into DECLARED-RESOLUTION PIXELS
    /// (top-left origin). Identity in `.pixels` mode. Linear with a zero origin,
    /// so it also converts a SIZE (w,h) when handed one as a point.
    nonisolated static func modelPointToScreenshotPixels(_ p: CGPoint, width: Int, height: Int) -> CGPoint {
        switch OllamaConfig.coordinateSpace {
        case .pixels:
            return p
        case .normalized1000:
            return CGPoint(x: p.x / 1000.0 * CGFloat(max(1, width)),
                           y: p.y / 1000.0 * CGFloat(max(1, height)))
        }
    }

    nonisolated static func modelPointToScreenshotPixels(_ p: CGPoint, in cap: ComputerUseCapture) -> CGPoint {
        modelPointToScreenshotPixels(p, width: cap.screenshotWidthInPixels, height: cap.screenshotHeightInPixels)
    }

    /// Inverse of `modelPointToScreenshotPixels`: declared pixels → the model's
    /// own convention. Used when Holmes REPORTS a coordinate to the model
    /// (`cursor_position`) so the number it reads back is in the space it speaks.
    nonisolated static func screenshotPixelsToModelPoint(_ p: CGPoint, width: Int, height: Int) -> CGPoint {
        switch OllamaConfig.coordinateSpace {
        case .pixels:
            return p
        case .normalized1000:
            return CGPoint(x: p.x * 1000.0 / CGFloat(max(1, width)),
                           y: p.y * 1000.0 / CGFloat(max(1, height)))
        }
    }

    /// The valid range of a model coordinate in the model's own convention:
    /// (W, H) in pixel mode, (1000, 1000) in normalized mode. For clamping
    /// values that stay in model space (VisualGuidance annotations).
    nonisolated static func modelCoordinateBounds(width: Int, height: Int) -> CGSize {
        switch OllamaConfig.coordinateSpace {
        case .pixels:         return CGSize(width: width, height: height)
        case .normalized1000: return CGSize(width: 1000, height: 1000)
        }
    }

    /// One sentence, reused verbatim by every prompt and tool description that
    /// tells the model how to express a coordinate, so they can never disagree.
    nonisolated static func coordinateSpaceDescription(width: Int, height: Int) -> String {
        switch OllamaConfig.coordinateSpace {
        case .pixels:
            return "Coordinates are pixels of the last screenshot, which is \(width)×\(height) (width × height), origin top-left: x runs 0…\(width) left to right, y runs 0…\(height) top to bottom."
        case .normalized1000:
            return "Coordinates are on a 0-1000 grid laid over the last screenshot (which is \(width)×\(height) pixels), origin top-left: x runs 0 (left edge) to 1000 (right edge), y runs 0 (top edge) to 1000 (bottom edge). Do NOT answer in pixels."
        }
    }

    // MARK: - Coordinate mapping (model pixels → global AppKit point)

    /// Maps a coordinate the model returned — in DECLARED-RESOLUTION PIXEL space,
    /// TOP-LEFT origin (or the normalized grid, see `modelPointToScreenshotPixels`)
    /// — into a GLOBAL AppKit point (bottom-left origin, union of all displays).
    /// The output is exactly what `InputController.Mouse.leftClick` expects; that
    /// layer then does the final per-display AppKit→Quartz conversion.
    ///
    /// Pipeline (OpenClicky ElementLocationDetector.swift:103-121 for scale + flip,
    /// plus `+ displayFrame.origin` for the multi-display global offset):
    ///   0. interpret the model's coordinate convention (pixels or 0-1000 grid).
    ///   1. clamp to the screenshot's pixel bounds — a model occasionally returns a
    ///      coordinate slightly outside the declared dims, which would otherwise map
    ///      off-screen after scaling.
    ///   2. scale from pixel space into display POINT space.
    ///   3. Y-flip: top-left origin (model / CoreGraphics) → bottom-left (AppKit).
    ///   4. offset by the display's global AppKit origin.
    /// Pure and side-effect free, so it is safe to call from any actor.
    nonisolated static func modelPointToGlobalAppKit(_ p: CGPoint, in cap: ComputerUseCapture) -> CGPoint {
        // 0. Model convention → declared screenshot pixels (identity in pixel mode).
        let pixel = modelPointToScreenshotPixels(p, in: cap)

        // 1. Clamp to the declared screenshot pixel bounds.
        let clampedX = max(0, min(pixel.x, CGFloat(cap.screenshotWidthInPixels)))
        let clampedY = max(0, min(pixel.y, CGFloat(cap.screenshotHeightInPixels)))

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
    /// the model's pixel-counting would return coordinates in the wrong scale. This
    /// path guarantees the output is exactly `targetWidth` × `targetHeight` pixels.
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

        // 0.8: a local model gets no benefit from a heavier JPEG (its vision
        // encoder resamples to a token grid anyway), and the smaller base64 is
        // fewer bytes to ship to the server on every turn.
        guard let jpegData = bitmapRep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }
}
