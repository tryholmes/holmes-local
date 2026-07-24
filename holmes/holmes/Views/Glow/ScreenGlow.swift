import SwiftUI
import AppKit

// MARK: - ScreenGlowController

/// Full-screen, click-through "Apple Intelligence"-style edge glow.
/// - `.thinking`: a continuously rotating white/ice-blue/violet sweep around the screen edges.
/// - `.ready`: rotation freezes, then a vibrating, pulsing zoom-in celebration —
///   the edge glow scales 1.0→1.06→1.0 a few times with a snappy spring while its
///   opacity pulses, synced with macOS trackpad haptics — then a quick fade out.
///   This "it's done!" beat is deliberately energetic and distinct from the calm
///   thinking sweep. The controller returns to `.off` ~2.4s after `.ready`.
/// - `.off`: the overlay window is ordered out and released.
@MainActor
@Observable
final class ScreenGlowController {
    static let shared = ScreenGlowController()

    enum GlowState {
        case off
        case thinking
        case ready
    }

    /// Current glow state, observed by the SwiftUI overlay.
    private(set) var state: GlowState = .off

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var offTimer: Timer?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    private init() {
        // Re-fit the overlay when displays are added/removed or resolution changes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ScreenGlowController.shared.handleScreenParametersChange()
            }
        }
    }

    // MARK: Public API

    func set(state newState: GlowState) {
        // Any new state cancels the pending auto-off.
        offTimer?.invalidate()
        offTimer = nil

        print("🌈 ScreenGlow: state -> \(newState)")

        switch newState {
        case .off:
            state = .off
            tearDownWindow()

        case .thinking:
            state = .thinking
            ensureWindow()
            // Buzz the trackpad the moment an actionable action starts, so the user
            // feels that Holmes caught something even before it finishes.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        case .ready:
            state = .ready
            ensureWindow()
            // Guaranteed completion buzz — a firm double-tap the user can actually
            // feel, fired here in the controller so it never depends on the overlay
            // view's animation sequence having mounted/run.
            let performer = NSHapticFeedbackManager.defaultPerformer
            performer.perform(.alignment, performanceTime: .now)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 130_000_000)
                performer.perform(.alignment, performanceTime: .now)
                try? await Task.sleep(nanoseconds: 130_000_000)
                performer.perform(.levelChange, performanceTime: .now)
            }
            scheduleAutoOff()
        }
    }

    /// Soft completion chime.
    func ding() {
        guard let sound = NSSound(named: "Glass") else {
            print("🔔 ScreenGlow: system sound 'Glass' unavailable")
            return
        }
        sound.stop()
        sound.play()
    }

    // MARK: Window lifecycle

    private func ensureWindow() {
        if window == nil {
            guard let screen = NSScreen.main else {
                print("🌈 ScreenGlow: no main screen available")
                return
            }

            let w = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true   // fully click-through
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.hasShadow = false
            w.isReleasedWhenClosed = false

            let hostingView = NSHostingView(rootView: GlowOverlayView(controller: self))
            hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
            hostingView.autoresizingMask = [.width, .height]
            w.contentView = hostingView

            window = w
        }

        refitWindow()
        window?.orderFrontRegardless()
    }

    private func tearDownWindow() {
        window?.orderOut(nil)
        window = nil
    }

    private func refitWindow() {
        guard let window, let screen = NSScreen.main else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
    }

    private func handleScreenParametersChange() {
        guard let window, window.isVisible else { return }
        refitWindow()
    }

    // MARK: Auto-off

    private func scheduleAutoOff() {
        offTimer?.invalidate()
        // The ready pulse + fade lands around ~1.8s; give it margin before teardown.
        offTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { _ in
            Task { @MainActor in
                let controller = ScreenGlowController.shared
                guard controller.state == .ready else { return }
                controller.set(state: .off)
            }
        }
    }
}

// MARK: - GlowOverlayView

/// The rotating edge-glow rendered inside the borderless overlay window.
struct GlowOverlayView: View {
    let controller: ScreenGlowController

    @State private var overlayOpacity: Double = 0
    /// Center-anchored zoom used only by the `.ready` celebration pulse.
    @State private var overlayScale: Double = 1.0
    @State private var frozenAngle: Angle = .degrees(0)
    @State private var readyTask: Task<Void, Never>?

    /// Full rotation period of the sweep, in seconds.
    private let rotationPeriod: Double = 3.0

    /// White → ice-blue → violet, wrapped so the angular gradient loops smoothly.
    private let glowColors: [Color] = [
        Color.white,
        Color(red: 0.62, green: 0.87, blue: 1.00),   // ice blue
        Color(red: 0.66, green: 0.48, blue: 1.00),   // violet
        Color(red: 0.62, green: 0.87, blue: 1.00),   // ice blue
        Color.white
    ]

    var body: some View {
        ZStack {
            switch controller.state {
            case .off:
                Color.clear

            case .thinking:
                TimelineView(.animation) { timeline in
                    glowBorder(angle: rotationAngle(at: timeline.date))
                }

            case .ready:
                glowBorder(angle: frozenAngle)
            }
        }
        .scaleEffect(overlayScale)   // center-anchored zoom for the ready pulse
        .opacity(overlayOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            apply(state: controller.state)
        }
        .onChange(of: controller.state) { _, newState in
            apply(state: newState)
        }
    }

    // MARK: Border

    private func glowBorder(angle: Angle) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: glowColors),
                    center: .center,
                    angle: angle
                ),
                lineWidth: 10
            )
            .blur(radius: 14)
            .padding(2)
            // Rasterize the stroked+blurred border once per frame on the GPU —
            // without this, the .thinking TimelineView re-runs a full-screen
            // CPU blur at display refresh for the whole run.
            .drawingGroup()
    }

    private func rotationAngle(at date: Date) -> Angle {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: rotationPeriod)
        return .degrees((t / rotationPeriod) * 360.0)
    }

    // MARK: State choreography

    private func apply(state: ScreenGlowController.GlowState) {
        readyTask?.cancel()
        readyTask = nil

        switch state {
        case .off:
            withAnimation(.easeOut(duration: 0.2)) {
                overlayOpacity = 0
            }
            overlayScale = 1.0

        case .thinking:
            // The calm sweep never zooms — keep the scale neutral.
            overlayScale = 1.0
            withAnimation(.easeIn(duration: 0.45)) {
                overlayOpacity = 1
            }

        case .ready:
            // Freeze the sweep where it currently is, then do the zoom-pulse celebration.
            frozenAngle = rotationAngle(at: Date())
            overlayScale = 1.0
            runReadySequence()
        }
    }

    /// The "it's done!" beat: a vibrating, pulsing zoom-in. The edge glow snaps
    /// out to 1.06 and back with a springy bounce a few times (~1.2s) while the
    /// opacity throbs and macOS trackpad haptics fire, then it fades out.
    private func runReadySequence() {
        readyTask = Task { @MainActor in
            // Snap to full opacity at neutral scale before the burst.
            overlayScale = 1.0
            withAnimation(.easeOut(duration: 0.12)) {
                overlayOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 90_000_000)

            let pulseCount = 4
            for i in 0..<pulseCount {
                guard !Task.isCancelled else { return }

                // Trackpad haptic on the leading beats, synced to the zoom-in.
                if i < 2 { fireHaptic() }

                // Zoom in with a snappy, low-damping spring for a vibrating punch.
                // Bigger scale = more visible "it's done!" beat.
                withAnimation(.spring(response: 0.13, dampingFraction: 0.42)) {
                    overlayScale = 1.11
                    overlayOpacity = 1.0
                }
                try? await Task.sleep(nanoseconds: 150_000_000)

                guard !Task.isCancelled else { return }

                // Settle back down, dimming slightly to give each pulse a throb.
                withAnimation(.spring(response: 0.15, dampingFraction: 0.55)) {
                    overlayScale = 1.0
                    overlayOpacity = 0.7
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.55)) {
                overlayScale = 1.0
                overlayOpacity = 0
            }
        }
    }

    /// Fire a macOS trackpad haptic (the "touchpad vibration"). Available since
    /// macOS 10.11, so it's always present on our 14+ target, but the manager is
    /// resolved defensively in case no haptic-capable device is attached.
    private func fireHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }
}
