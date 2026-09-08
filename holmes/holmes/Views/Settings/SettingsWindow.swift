import AppKit
import SwiftUI

/// Robust Settings window for this LSUIElement (menu-bar) app.
///
/// The SwiftUI `Settings { … }` scene is unreliable for accessory apps —
/// `showSettingsWindow:` often no-ops or opens the panel behind everything.
/// This controller mirrors the MainPanelWindowController
/// idiom: a plain titled NSWindow hosting the existing `SettingsView`, brought
/// front deterministically with `NSApp.activate(ignoringOtherApps:)`.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    override private init() {
        super.init()
    }

    /// Brings the Settings window to the front, creating it on first use.
    func show() {
        if window == nil {
            createWindow()
        }

        guard let window else { return }

        // A menu-bar app must become active first, or the window opens behind
        // whatever the user was looking at (or not at all).
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        // SettingsView pins itself to 640×520 (room for the seven tabs and the
        // Local Model pane); match it. Transparent titlebar + full-size content
        // so the glass background runs edge to edge like the Holmes login/panel
        // windows.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Holmes Local Settings"
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.center()

        // We hold a strong reference to `window`; without this, clicking the red
        // close button would over-release the window and crash on next open.
        w.isReleasedWhenClosed = false

        w.contentView = NSHostingView(rootView: SettingsView())
        self.window = w
    }
}
