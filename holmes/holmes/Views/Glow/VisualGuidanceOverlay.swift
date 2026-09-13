// Approach derived from OpenClicky (MIT, © 2025 Jason Kneen): the borderless,
// transparent, click-through overlay window (OverlayWindow.swift), the
// screenshot-pixel → screen-point coordinate mapping, and the POINT/RECT/SCRIBBLE
// visual-guidance annotation shapes (OpenClickyVisualGuidanceOverlayModels.swift,
// CompanionManager+PointTagParsing.swift). Adapted to Holmes: NoirColors palette,
// Apple-Intelligence-style glow, and reuse of WindowCapture's coordinate mapping.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import SwiftUI

// MARK: - GuidanceAnnotation

/// One thing to draw on the user's screen to point the way. Coordinates in
/// `point` (and every point in `path`) are in the model's DECLARED
/// SCREENSHOT-PIXEL space, TOP-LEFT origin — exactly what
/// `WindowCapture.captureForModel()` declared to the local model and what it returns
/// (interpreted per OllamaConfig.coordinateSpace by modelPointToGlobalAppKit).
/// `VisualGuidanceOverlay.show(_:mappedFrom:)` maps them onto the physical screen.
///
/// Per-kind meaning of `point` / `size`:
///   • circle    — `point` is the CENTER of the ring; `size` (optional) is the
///                 element's pixel box, used to size the ring around it.
///   • arrow     — `point` is the TIP (the thing being pointed AT); the tail is
///                 chosen automatically from a sensible on-screen offset.
///   • highlight — `point` is the TOP-LEFT of the region; `size` is its box.
///   • label     — `point` is the anchor the caption bubble sits beside.
///   • scribble  — `path` is the freehand stroke; `point` mirrors `path.first`.
struct GuidanceAnnotation {
    enum Kind { case circle, arrow, highlight, label, scribble }

    let kind: Kind
    /// Model screenshot-pixel coords (top-left origin).
    let point: CGPoint
    /// Optional element box in model screenshot pixels (circle diameter / highlight rect).
    var size: CGSize?
    /// Optional caption drawn near the annotation.
    var text: String?
    /// Freehand stroke (model screenshot pixels), used by `.scribble`.
    var path: [CGPoint]?

    init(kind: Kind,
         point: CGPoint,
         size: CGSize? = nil,
         text: String? = nil,
         path: [CGPoint]? = nil) {
        self.kind = kind
        self.point = point
        self.size = size
        self.text = text
        self.path = path
    }
}

// MARK: - VisualGuidanceOverlay

/// A borderless, transparent, click-through (`ignoresMouseEvents = true`),
/// non-activating overlay window at `.screenSaver` level that draws Clicky-style
/// teaching annotations directly on top of whatever the user is looking at. It
/// covers the captured display and never steals focus or swallows clicks.
@MainActor
final class VisualGuidanceOverlay {
    static let shared = VisualGuidanceOverlay()

    private let state = VisualGuidanceState()
    private var window: NSWindow?
    private var hideTimer: Timer?
    private var dismissMonitors: [Any] = []

    private init() {}

    // MARK: Public API

    /// Renders `annotations` on the display the `capture` was taken from, mapping
    /// each model screenshot-pixel coordinate onto the physical screen via
    /// `WindowCapture.modelPointToGlobalAppKit`. Auto-hides after `autoHideAfter`
    /// seconds (pass `0` to keep it up) and also hides on the next key/click.
    func show(_ annotations: [GuidanceAnnotation],
              mappedFrom capture: ComputerUseCapture,
              autoHideAfter: TimeInterval = 6) {
        let renderable = annotations.filter { annotation in
            switch annotation.kind {
            case .scribble: return (annotation.path?.count ?? 0) >= 2
            case .label:    return !(annotation.text?.isEmpty ?? true)
            default:        return true
            }
        }
        guard !renderable.isEmpty else { hide(); return }

        let screenFrame = capture.displayFrame

        // Model pixels → display points, for scaling element boxes.
        let scaleX = CGFloat(capture.displayWidthInPoints) / CGFloat(max(1, capture.screenshotWidthInPixels))
        let scaleY = CGFloat(capture.displayHeightInPoints) / CGFloat(max(1, capture.screenshotHeightInPixels))

        // A model point → this overlay's top-left-origin view coordinates:
        // reuse WindowCapture's exact pixel→global-AppKit mapping, then subtract
        // the display origin and Y-flip into the window's SwiftUI space.
        func toView(_ modelPoint: CGPoint) -> CGPoint {
            let global = WindowCapture.modelPointToGlobalAppKit(modelPoint, in: capture)
            return CGPoint(
                x: global.x - screenFrame.origin.x,
                y: (screenFrame.origin.y + screenFrame.height) - global.y
            )
        }

        let resolved: [ResolvedGuidance] = renderable.map { annotation in
            ResolvedGuidance(
                kind: annotation.kind,
                anchor: toView(annotation.point),
                size: annotation.size.map { CGSize(width: $0.width * scaleX, height: $0.height * scaleY) },
                text: annotation.text,
                path: annotation.path?.map(toView)
            )
        }

        ensureWindow(coveringScreenFrame: screenFrame)
        state.canvasSize = screenFrame.size
        state.items = resolved
        // Bump generation so the SwiftUI subtree is rebuilt and the entrance
        // animations replay even when an overlay was already on screen.
        state.generation &+= 1

        window?.alphaValue = 1
        window?.orderFrontRegardless()

        installDismissMonitors()

        hideTimer?.invalidate()
        hideTimer = nil
        if autoHideAfter > 0 {
            hideTimer = Timer.scheduledTimer(withTimeInterval: autoHideAfter, repeats: false) { _ in
                Task { @MainActor in VisualGuidanceOverlay.shared.hide() }
            }
        }
    }

    /// Briefly flashes a glowing accent RING at a GLOBAL AppKit screen point —
    /// the exact point Clicky's InputController is about to click/type at — so the
    /// user SEES where Holmes is acting before the event lands. Click-through,
    /// non-activating, auto-hides after `duration` (~0.6s). Unlike
    /// `show(_:mappedFrom:)` this takes a physical screen point directly: the
    /// ComputerUseEngine already resolved the global point via
    /// `WindowCapture.modelPointToGlobalAppKit` before handing it to
    /// InputController, so there is no ComputerUseCapture to map through here.
    ///
    /// It deliberately installs NO dismiss-on-input monitors — Clicky is about to
    /// post the very click that would otherwise dismiss the ring — and relies only
    /// on the auto-hide timer, so the ring stays visible through the click.
    func flashPointer(atGlobalPoint global: CGPoint,
                      label: String? = nil,
                      duration: TimeInterval = 0.6) {
        // The display the point lands on (nearest if it sits just off an edge), so
        // the overlay covers the right screen on a multi-display setup.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(global) })
                ?? NSScreen.screens.min(by: {
                    Self.distanceSquared($0.frame, global) < Self.distanceSquared($1.frame, global)
                })
                ?? NSScreen.main
        else { return }
        let screenFrame = screen.frame

        // Global AppKit (bottom-left origin) → overlay-window view point (top-left
        // origin) — the same flip `show(_:mappedFrom:)`'s `toView` performs.
        let anchor = CGPoint(
            x: global.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - global.y
        )

        ensureWindow(coveringScreenFrame: screenFrame)
        state.canvasSize = screenFrame.size
        let caption = (label?.isEmpty == false) ? label : nil
        state.items = [
            ResolvedGuidance(kind: .circle, anchor: anchor, size: nil, text: caption, path: nil)
        ]
        // Bump generation so the ring's entrance pop replays on every flash.
        state.generation &+= 1

        window?.alphaValue = 1
        window?.orderFrontRegardless()

        // A pointer flash must not swallow or react to the click it precedes.
        removeDismissMonitors()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, duration), repeats: false) { _ in
            Task { @MainActor in VisualGuidanceOverlay.shared.hide() }
        }
    }

    /// Squared distance from a point to the nearest edge of a rect (0 inside).
    private static func distanceSquared(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return (dx * dx) + (dy * dy)
    }

    /// Fades the overlay out and orders the window away.
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        removeDismissMonitors()

        guard let window, window.isVisible else {
            state.items = []
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.26
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                let overlay = VisualGuidanceOverlay.shared
                overlay.window?.orderOut(nil)
                overlay.window?.alphaValue = 1
                overlay.state.items = []
            }
        })
    }

    // MARK: Window lifecycle

    private func ensureWindow(coveringScreenFrame frame: CGRect) {
        if window == nil {
            let w = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true          // fully click-through
            w.level = .screenSaver               // above normal app windows
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false

            let host = NSHostingView(rootView: VisualGuidanceCanvas(state: state))
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            w.contentView = host

            window = w
        }
        if window?.frame != frame {
            window?.setFrame(frame, display: true)
        }
    }

    // MARK: Dismiss-on-input

    private func installDismissMonitors() {
        removeDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            Task { @MainActor in VisualGuidanceOverlay.shared.hide() }
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in VisualGuidanceOverlay.shared.hide() }
            return event
        }) {
            dismissMonitors.append(local)
        }
    }

    private func removeDismissMonitors() {
        for monitor in dismissMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dismissMonitors.removeAll()
    }
}

// MARK: - Overlay state (SwiftUI-observed)

/// The view-space annotations currently on screen. `generation` is used as a
/// SwiftUI identity so each `show(...)` rebuilds the subtree and replays entrances.
@MainActor
@Observable
final class VisualGuidanceState {
    var items: [ResolvedGuidance] = []
    var canvasSize: CGSize = .zero
    var generation: Int = 0
}

/// An annotation already mapped into overlay-window (top-left origin, points) space.
struct ResolvedGuidance: Identifiable {
    let id = UUID()
    let kind: GuidanceAnnotation.Kind
    let anchor: CGPoint
    let size: CGSize?
    let text: String?
    let path: [CGPoint]?
}

// MARK: - Palette

private enum GuidancePalette {
    /// Apple-Intelligence-style ice blue + violet, matching ScreenGlow's sweep.
    static let accent  = Color(red: 0.62, green: 0.87, blue: 1.00)
    static let accent2 = Color(red: 0.66, green: 0.48, blue: 1.00)
    static let ring = AngularGradient(
        gradient: Gradient(colors: [.white, accent, accent2, accent, .white]),
        center: .center
    )
}

// MARK: - Canvas

private struct VisualGuidanceCanvas: View {
    let state: VisualGuidanceState

    var body: some View {
        ZStack {
            Color.clear
            ForEach(state.items) { item in
                GuidanceItemView(item: item, canvasSize: state.canvasSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Rebuild the whole subtree per show so onAppear entrance animations replay.
        .id(state.generation)
    }
}

// MARK: - Per-annotation dispatch

private struct GuidanceItemView: View {
    let item: ResolvedGuidance
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            shape
            if let text = item.text, !text.isEmpty {
                GuidanceCaption(text: text)
                    .position(clamp(captionAnchor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var shape: some View {
        switch item.kind {
        case .circle:
            GuidanceCircleView(center: item.anchor, radius: circleRadius)
        case .highlight:
            GuidanceHighlightView(rect: highlightRect)
        case .arrow:
            GuidanceArrowView(tail: arrowTail, tip: item.anchor)
        case .label:
            GuidanceMarkerView(center: item.anchor)
        case .scribble:
            if let path = item.path {
                GuidanceScribbleView(points: path)
            }
        }
    }

    // MARK: Geometry

    private var circleRadius: CGFloat {
        if let size = item.size {
            return max(28, max(size.width, size.height) / 2 + 10)
        }
        return 46
    }

    private var highlightRect: CGRect {
        let size = item.size ?? CGSize(width: 130, height: 46)
        return CGRect(x: item.anchor.x, y: item.anchor.y, width: max(8, size.width), height: max(8, size.height))
    }

    /// The arrow flies in FROM a diagonal that keeps it on-screen: up-left by
    /// default, flipping to come from the right/below when the tip hugs an edge.
    private var arrowTail: CGPoint {
        let tip = item.anchor
        let length: CGFloat = 96
        var dx: CGFloat = -1
        var dy: CGFloat = -1
        if tip.x < 180 { dx = 1 }
        if tip.y < 180 { dy = 1 }
        let inv = 1 / 2.0.squareRoot()
        return CGPoint(x: tip.x + dx * length * inv, y: tip.y + dy * length * inv)
    }

    private var captionAnchor: CGPoint {
        switch item.kind {
        case .circle:
            return CGPoint(x: item.anchor.x, y: item.anchor.y + circleRadius + 20)
        case .highlight:
            return CGPoint(x: highlightRect.midX, y: highlightRect.minY - 18)
        case .arrow:
            return arrowTail
        case .label:
            return CGPoint(x: item.anchor.x, y: item.anchor.y + 24)
        case .scribble:
            if let mid = item.path?.midpoint {
                return CGPoint(x: mid.x, y: mid.y - 18)
            }
            return item.anchor
        }
    }

    /// Keep a caption's center inside the display with rough margins so it never
    /// clips off the edge (the bubble sizes itself; these are conservative).
    private func clamp(_ point: CGPoint) -> CGPoint {
        let marginX: CGFloat = 175
        let marginY: CGFloat = 28
        let maxX = max(marginX, canvasSize.width - marginX)
        let maxY = max(marginY, canvasSize.height - marginY)
        return CGPoint(
            x: min(max(point.x, marginX), maxX),
            y: min(max(point.y, marginY), maxY)
        )
    }
}

// MARK: - Circle (attention ring)

private struct GuidanceCircleView: View {
    let center: CGPoint
    let radius: CGFloat

    @State private var appeared = false
    @State private var breathing = false
    @State private var sonar = false

    var body: some View {
        ZStack {
            // Expanding "sonar" ping — a second ring that keeps radiating outward
            // and fading, so the spot reads as alive and draws the eye.
            Circle()
                .stroke(GuidancePalette.accent.opacity(0.8), lineWidth: 3)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(sonar ? 1.9 : 1.0)
                .opacity(sonar ? 0 : 0.65)

            // Big soft glow halo behind the ring.
            Circle()
                .stroke(GuidancePalette.accent.opacity(0.34), lineWidth: 22)
                .blur(radius: 16)
                .frame(width: radius * 2, height: radius * 2)

            // The crisp gradient ring itself.
            Circle()
                .stroke(GuidancePalette.ring, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .shadow(color: GuidancePalette.accent.opacity(0.9), radius: 11)
                .frame(width: radius * 2, height: radius * 2)

            // A bright center dot pinning the exact target.
            Circle()
                .fill(GuidancePalette.accent)
                .frame(width: 9, height: 9)
                .shadow(color: GuidancePalette.accent.opacity(0.95), radius: 6)
        }
        .scaleEffect(breathing ? 1.06 : 0.95)   // continuous breathing pulse
        .scaleEffect(appeared ? 1 : 0.35)        // entrance pop
        .opacity(appeared ? 1 : 0)
        .position(center)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { appeared = true }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) { breathing = true }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { sonar = true }
        }
    }
}

// MARK: - Arrow (points AT the target)

private struct GuidanceArrowView: View {
    let tail: CGPoint
    let tip: CGPoint

    @State private var drawn: CGFloat = 0
    @State private var appeared = false
    @State private var glow = false

    var body: some View {
        ZStack {
            // Soft under-glow stroke so the arrow reads on any background.
            GuidanceArrowShape(tail: tail, tip: tip)
                .trim(from: 0, to: drawn)
                .stroke(GuidancePalette.accent.opacity(0.35), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                .blur(radius: 6)
            // The crisp gradient arrow on top.
            GuidanceArrowShape(tail: tail, tip: tip)
                .trim(from: 0, to: drawn)
                .stroke(GuidancePalette.ring, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .shadow(color: GuidancePalette.accent.opacity(glow ? 0.95 : 0.55), radius: glow ? 11 : 6)
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
            withAnimation(.easeInOut(duration: 0.5)) { drawn = 1 }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

private struct GuidanceArrowShape: Shape {
    let tail: CGPoint
    let tip: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: tail)
        path.addLine(to: tip)

        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let headLength: CGFloat = 17
        let spread = CGFloat.pi / 7
        let left = CGPoint(
            x: tip.x - headLength * cos(angle - spread),
            y: tip.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: tip.x - headLength * cos(angle + spread),
            y: tip.y - headLength * sin(angle + spread)
        )
        path.move(to: left)
        path.addLine(to: tip)
        path.addLine(to: right)
        return path
    }
}

// MARK: - Highlight (translucent region)

private struct GuidanceHighlightView: View {
    let rect: CGRect

    @State private var appeared = false
    @State private var glowing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(GuidancePalette.accent.opacity(0.16))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GuidancePalette.accent.opacity(glowing ? 0.95 : 0.55), lineWidth: 2.6)
                .shadow(color: GuidancePalette.accent.opacity(0.55), radius: 10)
        }
        .frame(width: rect.width, height: rect.height)
        .scaleEffect(appeared ? 1 : 0.95)
        .opacity(appeared ? 1 : 0)
        .position(x: rect.midX, y: rect.midY)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glowing = true }
        }
    }
}

// MARK: - Label marker (dot beside a caption)

private struct GuidanceMarkerView: View {
    let center: CGPoint

    @State private var pulsed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(GuidancePalette.accent.opacity(0.28))
                .frame(width: 26, height: 26)
                .scaleEffect(pulsed ? 1.5 : 0.9)
                .opacity(pulsed ? 0 : 0.85)
            Circle()
                .fill(GuidancePalette.accent)
                .frame(width: 10, height: 10)
                .shadow(color: GuidancePalette.accent.opacity(0.9), radius: 6)
        }
        .position(center)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulsed = true }
        }
    }
}

// MARK: - Scribble (freehand stroke)

private struct GuidanceScribbleView: View {
    let points: [CGPoint]

    @State private var drawn: CGFloat = 0

    var body: some View {
        GuidanceScribbleShape(points: points)
            .trim(from: 0, to: drawn)
            .stroke(GuidancePalette.ring, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            .shadow(color: GuidancePalette.accent.opacity(0.75), radius: 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.75)) { drawn = 1 }
            }
    }
}

private struct GuidanceScribbleShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count >= 3 {
            // Smooth the freehand line with quad curves through segment midpoints.
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: mid, control: previous)
            }
            path.addLine(to: points[points.count - 1])
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }
}

// MARK: - Caption bubble (glass, NoirColors)

private struct GuidanceCaption: View {
    let text: String

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 6) {
            // A small glowing accent dot leads the caption, tying the bubble to
            // the annotation it belongs to.
            Circle()
                .fill(GuidancePalette.accent)
                .frame(width: 6, height: 6)
                .shadow(color: GuidancePalette.accent.opacity(0.9), radius: 4)
            Text(text)
                .font(NoirFonts.font(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(NoirColors.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.32))
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(GuidancePalette.accent.opacity(0.5), lineWidth: 1.2)
            }
        )
        .shadow(color: GuidancePalette.accent.opacity(0.35), radius: 12, x: 0, y: 3)
        .shadow(color: NoirColors.glassShadow, radius: 10, x: 0, y: 3)
        .frame(maxWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Helpers

private extension Array where Element == CGPoint {
    /// The geometric midpoint along the sampled stroke (used to place a caption).
    var midpoint: CGPoint? {
        guard !isEmpty else { return nil }
        return self[count / 2]
    }
}
