import AppKit
import SwiftUI

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var resumeTask: Task<Void, Never>?
    private var resumeRevision: UInt64 = 0
    private(set) var isSystemSuspended = false
    
    var isPaused: Bool = false {
        didSet {
            guard oldValue != isPaused else { return }
            updateMenuItemTitles()
            if isPaused {
                stopAllWork()
                SideIconWindowController.shared.iconState = .dormant
            } else if !isSystemSuspended {
                resumeObservation()
            }
        }
    }
    
    override private init() {
        super.init()
    }
    
    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            // Use SF Symbol for clean, polished Apple look
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let symbolImage = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Holmes")?
                .withSymbolConfiguration(config) {
                button.image = symbolImage
                button.image?.isTemplate = true
            }
            
            // Add click action for toggle behavior
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        setupMenu()
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Right click shows menu
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // Left click toggles search bar
            SearchBarWindowController.shared.toggle()
        }
    }
    
    private func setupMenu() {
        menu = NSMenu()
        
        let statusItem = NSMenuItem(title: "Holmes is running", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu?.addItem(statusItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let searchItem = NSMenuItem(title: "Open Search", action: #selector(openSearch), keyEquivalent: " ")
        searchItem.keyEquivalentModifierMask = .control
        searchItem.target = self
        menu?.addItem(searchItem)
        
        let panelItem = NSMenuItem(title: "Open Assistant", action: #selector(openPanel), keyEquivalent: " ")
        panelItem.keyEquivalentModifierMask = .option
        panelItem.target = self
        menu?.addItem(panelItem)

        let demoItem = NSMenuItem(title: "Try Holmes…", action: #selector(openDemo), keyEquivalent: "")
        demoItem.target = self
        menu?.addItem(demoItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let pauseItem = NSMenuItem(title: "Pause Holmes", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = .command
        pauseItem.target = self
        menu?.addItem(pauseItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu?.addItem(settingsItem)
        
        let aboutItem = NSMenuItem(title: "About Holmes", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu?.addItem(aboutItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Holmes", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)
        
        self.statusItem?.menu = menu
    }
    
    private func updateMenuItemTitles() {
        if let pauseItem = menu?.items.first(where: { $0.action == #selector(togglePause) }) {
            pauseItem.title = isPaused ? "Resume Holmes" : "Pause Holmes"
        }
        
        if let statusItem = menu?.items.first {
            statusItem.title = isPaused ? "Holmes is paused" : "Holmes is running"
        }
        
        if let button = statusItem?.button {
            // Named images are cached and shared with the mascot views. Resize
            // a private copy uniformly so resuming cannot distort their artwork.
            if !isPaused, let img = NSImage(named: "NoirCharacter")?.copy() as? NSImage,
               img.size.width > 0, img.size.height > 0 {
                let scale = 18 / max(img.size.width, img.size.height)
                img.size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
                img.isTemplate = true
                button.image = img
            } else {
                button.image = NSImage(
                    systemSymbolName: isPaused ? "pause.circle" : "magnifyingglass",
                    accessibilityDescription: "Holmes"
                )
                button.image?.isTemplate = true
            }
        }
    }
    
    @objc private func openSearch() {
        SearchBarWindowController.shared.show()
    }
    
    @objc private func openPanel() {
        SideIconWindowController.shared.show()
        MainPanelWindowController.shared.show()
    }

    @objc private func openDemo() {
        Task { @MainActor in GuidedDemoWindowController.shared.show() }
    }
    
    @objc private func togglePause() {
        isPaused.toggle()
    }

    /// Shared teardown for Pause, sleep/lock and termination. Invalidation is
    /// synchronous so a response arriving after wake cannot revive old UI.
    func stopAllWork() {
        resumeRevision &+= 1
        resumeTask?.cancel()
        resumeTask = nil
        ClickyController.shared.cancelPushToTalk()
        EmailDraftCoordinator.shared.stop()
        AutonomousActionRunner.shared.cancelCurrentRun()
        ComputerUseEngine.shared.cancelRun()
        WorkActivityCenter.shared.invalidateAll()
        HolmesAgent.shared.stop()
        SpeechSynthesizer.shared.stop()
        VisualGuidanceOverlay.shared.hide()
        ScreenGlowController.shared.set(state: .off)
    }

    func suspendForSystemEvent() {
        guard !isSystemSuspended else { return }
        isSystemSuspended = true
        stopAllWork()
    }

    func resumeAfterSystemEvent() {
        guard isSystemSuspended else { return }
        isSystemSuspended = false
        guard !isPaused else { return }
        resumeObservation()
    }

    private func resumeObservation() {
        resumeRevision &+= 1
        let revision = resumeRevision
        resumeTask?.cancel()
        EmailDraftCoordinator.shared.start()
        resumeTask = Task { @MainActor [weak self] in
            guard let self, !self.isPaused, !self.isSystemSuspended, !Task.isCancelled else { return }
            await HolmesAgent.shared.start()
            guard self.resumeRevision == revision else { return }
            self.resumeTask = nil
        }
    }
    
    @objc private func openSettings() {
        // The SwiftUI Settings scene's showSettingsWindow: selector is unreliable
        // for LSUIElement apps (opens behind everything / no-ops). Use a dedicated
        // NSWindow controller that activates and fronts deterministically.
        SettingsWindowController.shared.show()
    }
    
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
