import AppKit
import SwiftUI

class LoginWindowController: NSObject {
    static let shared = LoginWindowController()

    private var window: NSWindow?
    var onLoginSuccess: (() -> Void)?

    override private init() {
        super.init()
    }

    func show(onSuccess: @escaping () -> Void) {
        onLoginSuccess = onSuccess

        if window == nil {
            createWindow()
        }

        guard let window else { return }
        window.center()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
        }
    }

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = NSHostingView(rootView: LoginView(onProceed: { [weak self] in
            self?.hide()
            self?.onLoginSuccess?()
        }))
        self.window = w
    }
}
