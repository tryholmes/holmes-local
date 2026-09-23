import AVFoundation
import AppKit
import SwiftUI

// MARK: - Launch intro
// Plays the transparent brand intro (HEVC with alpha plus the launch sting)
// once over the onboarding glass, before the Welcome step. The video ends on a
// fully transparent frame, so the Welcome screen can simply take over.
struct LaunchIntroView: NSViewRepresentable {
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        guard let url = Bundle.main.url(forResource: "holmes-launch-intro", withExtension: "mov") else {
            // A missing resource must never strand the user before onboarding.
            DispatchQueue.main.async { context.coordinator.finish() }
            return view
        }

        let player = AVPlayer(url: url)
        view.playerLayer.player = player
        context.coordinator.start(player)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
        nsView.playerLayer.player?.pause()
        nsView.playerLayer.player = nil
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private let onFinish: () -> Void
        private var observers: [NSObjectProtocol] = []
        private var didFinish = false

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func start(_ player: AVPlayer) {
            let names: [Notification.Name] = [
                AVPlayerItem.didPlayToEndTimeNotification,
                AVPlayerItem.failedToPlayToEndTimeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: player.currentItem, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
            }
            // The clip is six seconds; if playback never starts (a codec or
            // resource failure that posts nothing), still move on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.finish()
            }
            player.play()
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            stop()
            onFinish()
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

// MARK: - Launch intro window
// Returning launches have no onboarding window to play the intro over, so it
// plays on its own in a borderless, transparent window centered on the screen.
// The first run still plays it inside onboarding. Reduce Motion skips it.
@MainActor
final class LaunchIntroWindowController {
    static let shared = LaunchIntroWindowController()

    private var window: NSWindow?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Returns once the intro ends or is clicked away.
    func play() async {
        guard window == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    private func show() {
        let root = LaunchIntroView(onFinish: { [weak self] in self?.finish() })
            .overlay {
                // Click anywhere to skip.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { [weak self] in self?.finish() }
            }

        // The clip is 16:9 with a transparent background.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil)
        // Dropping the hosting view dismantles the player, which stops playback.
        window?.contentView = nil
        window = nil
        continuation.resume()
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        // BGRA output keeps the video's alpha channel through composition.
        playerLayer.pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    // Let clicks reach SwiftUI so a tap can skip the intro.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
