// Ported from boring.notch (GPL-3.0, © TheBoredTeam and contributors):
// https://github.com/TheBoredTeam/boring.notch —
// components/Notch/BoringNotchWindow.swift (the floating non-activating HUD
// panel: style mask, .mainMenu+3 level, collection behavior, no shadow) and
// boringNotchApp.swift's createBoringNotchWindow/positionWindow (fixed
// windowSize frame, top-center setFrameOrigin, orderFrontRegardless, reposition
// on screen-parameter changes). The driver API (beginTask/stepProgress/endTask/
// flashContext/flashAction) is Holmes's own, feeding the ported UI.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import SwiftUI

/// BoringNotchWindow, verbatim.
final class HolmesNotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
class NotchWindowController: NSObject, ObservableObject {
    static let shared = NotchWindowController()

    private var window: NSWindow?
    @Published var viewModel = NotchViewModel()
    private var screenObserver: NSObjectProtocol?

    override private init() {
        super.init()
    }

    var hasNotch: Bool {
        NotchDetector.hasNotch
    }

    func show() {
        if window == nil {
            createWindow()
        }
        positionWindow()
        window?.orderFrontRegardless()

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleScreenChange() }
                }
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func createWindow() {
        let rect = NSRect(
            x: 0, y: 0,
            width: NotchGeometry.windowSize.width,
            height: NotchGeometry.windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        let window = HolmesNotchWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)

        window.contentView = NSHostingView(rootView: NotchView(vm: viewModel))
        window.orderFrontRegardless()

        self.window = window
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func positionWindow() {
        guard let window, let screen = targetScreen() else { return }
        viewModel.refreshNotchSize(for: screen)
        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
    }

    func handleScreenChange() {
        positionWindow()
    }

    // MARK: - Driver API (called by the runner, agent, and computer-use engine)

    /// A task run has begun — light the closed-notch wings and announce the goal.
    func beginTask(_ title: String) {
        viewModel.contextLine = HolmesAgent.shared.currentContext.description
        viewModel.taskName = title
        viewModel.taskStep = title
        viewModel.taskProgress = 0
        withAnimation(.smooth) { viewModel.taskActive = true }
        viewModel.showSneakPeek(title: "On it", subtitle: title, symbol: "bolt.fill", duration: 2.5)
    }

    /// Advance the task: the current step's text + progress fraction.
    func stepProgress(_ step: String, fraction: Double) {
        viewModel.taskStep = step
        viewModel.taskProgress = min(1, max(0, fraction))
    }

    /// The run finished — drop the wings, flash the result.
    func endTask(success: Bool, summary: String) {
        withAnimation(.smooth) { viewModel.taskActive = false }
        viewModel.taskProgress = 0
        viewModel.lastResult = (success ? "Done — " : "Stopped — ") + summary
        viewModel.showSneakPeek(
            title: success ? "Holmes finished" : "Holmes stopped",
            subtitle: summary,
            symbol: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            duration: 3.5)
    }

    /// The live context changed — keep the panel's context line current and,
    /// when nothing else is showing, reveal it briefly on the closed notch.
    func flashContext(_ headline: String, icon: String, activity: String) {
        viewModel.contextLine = headline
        viewModel.contextSymbol = icon
        guard viewModel.notchState == .closed, !viewModel.taskActive else { return }
        viewModel.showSneakPeek(title: activity, subtitle: headline, symbol: icon, duration: 3.0)
    }

    /// A one-off action banner (e.g. "Opening Finder") outside a full run.
    func flashAction(_ title: String, subtitle: String, symbol: String) {
        guard !viewModel.taskActive else { return }
        viewModel.showSneakPeek(title: title, subtitle: subtitle, symbol: symbol, duration: 2.5)
    }
}
