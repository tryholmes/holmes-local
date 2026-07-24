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
        // MUCH WIDER to extend from sides of notch
        let window = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.hasShadow = false
        
        let hostingView = NSHostingView(rootView: NotchHostView(controller: self))
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        
        window.contentView = hostingView
        
        self.window = window
    }
    
    private func positionWindow() {
        guard let window = window, let screen = NSScreen.main else { return }
        
        let screenFrame = screen.frame
        let windowWidth = window.frame.width
        let windowHeight = window.frame.height
        
        // Simply position at the TOP CENTER of the screen
        // This overlays the MacBook notch area
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight
        
        window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }
    
    func updateForState() {
        guard let window = window else { return }
        
        switch viewModel.state {
        case .idle:
            let width: CGFloat = 600
            let height: CGFloat = viewModel.isHovered ? 80 : 32
            window.setContentSize(NSSize(width: width, height: height))
        case .active:
            window.setContentSize(NSSize(width: 600, height: 90))
        case .notification:
            window.setContentSize(NSSize(width: 600, height: 64))
        case .expanded:
            window.setContentSize(NSSize(width: 600, height: 160))
        }

        positionWindow()
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
        VStack {
            Spacer()
            
            NotchView(viewModel: controller.viewModel) {
                NotchHaptics.shared.medium()
                MainPanelWindowController.shared.toggle()
            }
        }
        .onChange(of: controller.viewModel.isHovered) { _, hovered in
            if hovered {
                NotchHaptics.shared.light()
            }
        }
        .onChange(of: controller.viewModel.state) { _, _ in
            controller.updateForState()
        }
        .onChange(of: controller.viewModel.isHovered) { _, _ in
            controller.updateForState()
        }
    }
}
