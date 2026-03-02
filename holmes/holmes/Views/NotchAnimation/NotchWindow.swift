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
    
    func show() {
        guard hasNotch, !isVisible else { return }
        
        if window == nil {
            createWindow()
        }
        
        positionWindow()
        window?.orderFront(nil)
        isVisible = true
        viewModel.startIdleAnimation()
    }
    
    func hide() {
        viewModel.stopIdleAnimation()
        window?.orderOut(nil)
        isVisible = false
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
