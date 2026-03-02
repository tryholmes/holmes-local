import SwiftUI
import AppKit


class SearchBarWindowController: NSObject {
    static let shared = SearchBarWindowController()
    
    private var window: NSWindow?
    private var isVisible = false
    private var isResizing = false
    private var fixedTopY: CGFloat = 0  // Store the fixed top position
    
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
        
        // Use the stored fixed top position - this ensures NO movement
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: fixedTopY - newHeight,
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
        let windowWidth: CGFloat = 860
        let windowHeight: CGFloat = 120
        let topOffset: CGFloat = 100

        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let topY = screenFrame.origin.y + screenFrame.height - topOffset
        let y = topY - windowHeight

        fixedTopY = topY

        // Set alpha to 0 and set frame without displaying — content must not be
        // visible until SwiftUI has had a chance to render at the correct size.
        window.alphaValue = 0
        window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: false)
        window.hasShadow = false

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wait one runloop pass so SwiftUI renders at the correct 130px height
        // before we start the fade-in.
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }

        isVisible = true
    }

    func hide() {
        guard isVisible, let window else { return }
        isVisible = false
        isResizing = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            window?.orderOut(nil)
            window?.close()
            self?.window = nil  // destroy — next show() creates a fresh window with clean SwiftUI state
        }
    }
    
    private func createWindow() {
        let window = SearchBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 120),
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
