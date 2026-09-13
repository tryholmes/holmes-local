import AppKit
import SwiftUI

class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    
    var isPaused: Bool = false {
        didSet {
            updateMenuItemTitles()
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
        if let pauseItem = menu?.item(withTitle: isPaused ? "Resume Holmes" : "Pause Holmes") {
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
    
    @objc private func togglePause() {
        isPaused.toggle()
        
        if isPaused {
            SideIconWindowController.shared.iconState = .dormant
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
