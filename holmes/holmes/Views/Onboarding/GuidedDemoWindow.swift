import AppKit
import SwiftUI

/// The same tour is used after setup and when replayed from the menu bar.
/// Closing it cancels its own request without resetting onboarding or model settings.
@MainActor
final class GuidedDemoWindowController: NSObject, NSWindowDelegate {
    static let shared = GuidedDemoWindowController()

    private var window: NSWindow?
    private var model: GuidedDemoModel?

    func showIfNeeded() {
        guard GuidedDemoModel.shouldPresent() else { return }
        show()
    }

    func show() {
        if window == nil { createWindow() }
        guard let window else { return }
        // The assistant is a floating panel; leave the tour's controls clear
        // when it is opened from the assistant header.
        MainPanelWindowController.shared.hide()
        SearchBarWindowController.shared.hide()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        // Use the available desktop area so the title and controls stay below
        // the menu bar and camera housing, including on a second display.
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(window.frame.constrained(to: screen.visibleFrame.insetBy(dx: 12, dy: 12)), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        GuidedDemoModel.markPresented()
    }

    func close() {
        model?.cancel()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
    }

    private func createWindow() {
        let model = GuidedDemoModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Try Holmes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 600)
        window.delegate = self
        window.contentView = NSHostingView(rootView: GuidedDemoView(model: model) { [weak self] in
            self?.close()
        })
        self.model = model
        self.window = window
    }
}

private extension NSRect {
    func constrained(to bounds: NSRect) -> NSRect {
        let fittedSize = NSSize(width: min(width, bounds.width), height: min(height, bounds.height))
        return NSRect(
            x: min(max(minX, bounds.minX), bounds.maxX - fittedSize.width),
            y: min(max(minY, bounds.minY), bounds.maxY - fittedSize.height),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
