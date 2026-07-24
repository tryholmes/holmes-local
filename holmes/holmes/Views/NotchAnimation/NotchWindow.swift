import SwiftUI
import AppKit

final class NotchHaptics {
    static let shared = NotchHaptics()

    private init() {}

    func light() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func medium() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

@MainActor
class NotchWindowController: NSObject, ObservableObject {
    static let shared = NotchWindowController()

    private var window: NSWindow?
    @Published var viewModel = NotchViewModel()
    @Published var isVisible: Bool = false
    private var screenObserver: NSObjectProtocol?

    override private init() {
        super.init()
    }

    var hasNotch: Bool {
        NotchDetector.hasNotch
    }

    /// Install the HUD window on ANY Mac (not only notch models). The idle
    /// breathing bar only makes sense hugging a real notch, so on a notchless Mac
    /// the window stays ordered-out while idle and reveals only for task/context
    /// cards — `applyVisibility()` enforces that.
    func show() {
        guard !isVisible else { return }

        if window == nil {
            createWindow()
        }

        positionWindow()
        isVisible = true
        viewModel.startIdleAnimation()
        applyVisibility()

        // Re-hug the notch when displays change (monitor plugged/unplugged,
        // resolution change, moving between a notch and a notchless screen).
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleScreenChange() }
                }
        }
    }

    func hide() {
        viewModel.stopIdleAnimation()
        window?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Driver API (called by the runner, agent, and computer-use engine)

    /// A task run has begun — show the active card seeded with the current live
    /// context as its second line ("what context Holmes is acting in").
    func beginTask(_ title: String) {
        let ctx = HolmesAgent.shared.currentContext.description
        viewModel.startTask(name: title, context: ctx)
        applyVisibility()
    }

    /// Advance the active card. `step` replaces the top line with the current
    /// action ("Opening Finder"); `fraction` drives the progress bar.
    func stepProgress(_ step: String, fraction: Double) {
        viewModel.updateProgress(min(1, max(0, fraction)), step: step)
        applyVisibility()
    }

    /// A task run finished — flash a short result banner, then the notification
    /// timer returns the notch to idle on its own.
    func endTask(success: Bool, summary: String) {
        viewModel.showNotification(
            title: success ? "Holmes finished" : "Holmes stopped",
            subtitle: summary,
            symbol: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            duration: 3.5)
        applyVisibility()
    }

    /// The live context changed — always keep the idle bar's line current. On a
    /// notch Mac, also briefly reveal a context banner so the user SEES what Holmes
    /// sees; on a notchless Mac we stay silent (a banner over the menu bar on every
    /// app switch would be noise) and only surface for deliberate task events.
    func flashContext(_ headline: String, icon: String, activity: String) {
        viewModel.setContextLine(headline)
        guard hasNotch else { return }          // ambient banners are notch-only
        if case .active = viewModel.state { return }   // never stomp an in-flight task card
        viewModel.showNotification(title: activity, subtitle: headline, symbol: icon, duration: 4)
        applyVisibility()
    }

    /// A one-off action banner (e.g. "Opening Finder") that isn't a full run.
    func flashAction(_ title: String, subtitle: String, symbol: String) {
        if case .active = viewModel.state { return }
        viewModel.showNotification(title: title, subtitle: subtitle, symbol: symbol, duration: 2.5)
        applyVisibility()
    }

    /// Idle bar only paints on real-notch Macs; task/context/notification cards
    /// paint everywhere. Ordering the window out while idle on a notchless Mac
    /// keeps the HUD from sitting permanently over the menu bar.
    private func applyVisibility() {
        guard let window = window else { return }
        let shouldShow: Bool
        switch viewModel.state {
        case .idle:  shouldShow = hasNotch
        default:     shouldShow = true
        }
        if shouldShow {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }
    
    private func createWindow() {
        // A FIXED, top-flush panel that stays put; the CONTENT inside it grows
        // and shrinks and stays glued to the notch (notchify's model). Big enough
        // to hold the widest expanded card.
        let size = NotchDetector.panelSize
        let window = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        // Above the menu bar so the HUD overlays the notch region correctly
        // (notchify uses .mainMenu + 3).
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Mouse-transparent ALWAYS: a big top-center overlay must never swallow
        // clicks meant for the menu bar or the app behind it. The HUD is
        // display-only; interaction lives in the menu bar / hotkeys.
        window.ignoresMouseEvents = true
        window.hasShadow = false

        let hostingView = NSHostingView(rootView: NotchHostView(controller: self))
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        self.window = window
    }

    /// The screen the notch belongs to — the one under the mouse, else main.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionWindow() {
        guard let window = window, let screen = targetScreen() else { return }
        viewModel.refreshNotchSize(for: screen)
        let frame = screen.frame
        let size = window.frame.size
        // Top-flush, centered — the window's TOP edge sits on the screen top so
        // the content hangs straight out of the notch.
        let target = NSRect(
            x: (frame.midX - size.width / 2).rounded(),
            y: (frame.maxY - size.height).rounded(),
            width: size.width,
            height: size.height)
        window.setFrame(target, display: true, animate: false)
    }

    /// Reposition + refresh notch geometry when displays change (unplugged
    /// monitor, resolution change, moving to a non-notch external).
    func handleScreenChange() {
        positionWindow()
        applyVisibility()
    }

    func updateForState() {
        // The window stays a fixed size; only the SwiftUI content resizes, so
        // there's nothing to resize here — just keep visibility in sync.
        applyVisibility()
    }
}

class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct NotchHostView: View {
    @ObservedObject var controller: NotchWindowController

    var body: some View {
        // Content is pinned to the TOP of the window (the notch) and grows down.
        NotchView(viewModel: controller.viewModel) {
            NotchHaptics.shared.medium()
            MainPanelWindowController.shared.toggle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: controller.viewModel.state) { _, _ in
            controller.updateForState()
        }
    }
}
