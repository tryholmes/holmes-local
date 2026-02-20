import SwiftUI
import AppKit

class SearchBarWindowController: NSObject {
    static let shared = SearchBarWindowController()
    
    private var window: NSWindow?
    private var isVisible = false
    private var isResizing = false
    
    override private init() {
        super.init()
    }
    
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    func resize(to height: CGFloat, animated: Bool = true) {
        guard let window, !isResizing else { return }
        
        isResizing = true
        
        let currentFrame = window.frame
        let newHeight = height
        let yOffset = currentFrame.height - newHeight
        
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + yOffset,
            width: currentFrame.width,
            height: newHeight
        )
        
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true, animate: true)
            }, completionHandler: { [weak self] in
                self?.isResizing = false
            })
        } else {
            window.setFrame(newFrame, display: true, animate: false)
            isResizing = false
        }
    }
    
    func show() {
        guard !isVisible else { return }

        if window == nil {
            createWindow()
        }

        guard let window, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowWidth: CGFloat = 900
        let windowHeight: CGFloat = 140
        let topOffset: CGFloat = 100

        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.origin.y + screenFrame.height - windowHeight - topOffset

        window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        
        // Ensure no shadow is rendered
        window.hasShadow = false
        window.invalidateShadow()

        // Start invisible then fade + spring in
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        isVisible = true
    }

    func hide() {
        guard isVisible, let window else { return }
        isVisible = false
        
        // Reset to default size before hiding
        let currentFrame = window.frame
        let defaultHeight: CGFloat = 140
        let yOffset = currentFrame.height - defaultHeight
        
        let resetFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + yOffset,
            width: currentFrame.width,
            height: defaultHeight
        )
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(resetFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
    
    private func createWindow() {
        let window = SearchBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hasShadow = false
        window.invalidateShadow()
        
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.shadowOpacity = 0
            contentView.shadow = nil
        }
        
        let hostingView = NSHostingView(rootView: SearchBarHostView(onDismiss: { [weak self] in
            self?.hide()
        }))
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.shadowOpacity = 0
        hostingView.shadow = nil
        
        window.contentView = hostingView
        
        self.window = window
    }
}

class SearchBarPanel: NSPanel {
    private var isDragging = false
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        super.mouseUp(with: event)
    }
    
    override func resignKey() {
        if !isDragging {
            super.resignKey()
            SearchBarWindowController.shared.hide()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            SearchBarWindowController.shared.hide()
            return
        }
        super.keyDown(with: event)
    }
}

struct SearchBarHostView: View {
    let onDismiss: () -> Void
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.clear

            SearchBarView(isVisible: $isVisible)
                .onChange(of: isVisible) { _, newValue in
                    if !newValue {
                        onDismiss()
                    }
                }
        }
        .onAppear {
            // Slight delay lets the NSWindow finish its initial alpha animation
            // so the two animations layer nicely without fighting each other
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                isVisible = true
            }
        }
    }
}
