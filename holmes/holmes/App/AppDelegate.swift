import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupApp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregisterHotkeys()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainPanelWindowController.shared.show()
        }
        return true
    }

    private func setupApp() {
        MenuBarManager.shared.setup()
        setupHotkeys()

        Task { @MainActor in
            await handleAuthAndLaunch()
        }
    }

    @MainActor
    private func handleAuthAndLaunch() async {
        let auth = ClerkAuthManager.shared

        // If a session token exists in Keychain, validate it
        if KeychainManager.load(
            service: ClerkConfig.keychainService,
            account: ClerkConfig.sessionTokenAccount
        ) != nil {
            let valid = await auth.validateStoredSession()
            if valid {
                launchAfterAuth()
                return
            }
        }

        // No valid session — show login
        LoginWindowController.shared.show { [weak self] in
            self?.launchAfterAuth()
        }
    }

    private func launchAfterAuth() {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if hasCompletedOnboarding {
            startMainApp()
        } else {
            showOnboarding()
        }
    }

    private func setupHotkeys() {
        HotkeyManager.shared.onControlSpace = {
            SearchBarWindowController.shared.toggle()
        }

        HotkeyManager.shared.onOptionSpace = {
            if !SideIconWindowController.shared.isVisible {
                SideIconWindowController.shared.show()
            }
            MainPanelWindowController.shared.toggle()
        }

        HotkeyManager.shared.onCommandBackslash = {
            SideIconWindowController.shared.toggle()
        }

        HotkeyManager.shared.registerHotkeys()
    }

    private func showOnboarding() {
        let onboardingView = OnboardingFlow {
            DispatchQueue.main.async { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.startMainApp()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startMainApp() {
        SideIconWindowController.shared.show()

        if NotchDetector.hasNotch {
            NotchWindowController.shared.show()
        }
    }
}
