import AppKit
import SwiftUI

@MainActor
final class ConfirmationWindowController: NSObject {
    static let shared = ConfirmationWindowController()
    private var window: NSWindow?
    private override init() {}

    func show() {
        if window == nil { createWindow() }
        guard let window, let screen = NSScreen.main else { return }

        // Bottom-right corner, above dock. Draft review cards get a wider, much
        // taller panel so the editable body (up to 200pt) and the
        // Copy/Insert/Dismiss row are both fully visible without clipping.
        // The auto-drafted reply card is taller again: it carries the quoted
        // message and the GROUNDED IN strip on top of the editable body, and
        // the receipts are the point — they must not be the thing that clips.
        let isReply = ConfirmationBus.shared.isShowingReply
        let isDraft = ConfirmationBus.shared.pendingDraft != nil
        let w: CGFloat = (isReply || isDraft) ? 380 : 360
        let h: CGFloat = isReply ? 520 : (isDraft ? 440 : 280)
        let margin: CGFloat = 20
        let x = screen.visibleFrame.maxX - w - margin
        let y = screen.visibleFrame.minY + margin

        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
        }
    }

    private func createWindow() {
        let w = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        w.contentView = NSHostingView(rootView: ConfirmationView())
        self.window = w
    }
}
