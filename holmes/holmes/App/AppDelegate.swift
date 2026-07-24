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
            // Clicky loop: wire push-to-talk transcripts into the router and warm
            // up mic/speech permission once, so the first hold doesn't silently
            // no-op on a not-yet-determined grant.
            ClickyController.shared.start()
            await handleAuthAndLaunch()
        }
    }

    @MainActor
    private func handleAuthAndLaunch() async {
        // Auth removed — show the sign-in screen; any button just proceeds.
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

    private func startHolmesAgent() {
        Task { @MainActor in
            await HolmesAgent.shared.start()
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

        // ⌘⌥Esc — emergency stop for a computer-control run. Flips the engine's
        // session kill flag so the next primitive aborts and the loop winds down.
        // The Carbon hotkey callback is a nonisolated closure (invoked via
        // DispatchQueue.main.async in HotkeyManager), so hop onto the MainActor to
        // reach the @MainActor-isolated engine — the flag flip is trivial and the
        // next `perform` iteration reads it.
        HotkeyManager.shared.onCommandOptionEscape = {
            Task { @MainActor in
                ComputerUseEngine.shared.cancelRun()
            }
        }

        // Hold Fn (globe) — Clicky push-to-talk, true hold-to-talk. HotkeyManager
        // watches the .function modifier flag via NSEvent monitors: Fn-DOWN begins
        // listening, Fn-UP ends it and routes the transcript (ask-and-draw, or hand
        // off to the agent). The monitor callbacks are nonisolated closures (NSEvent
        // invokes them on the main thread), so hop onto the MainActor to reach the
        // @MainActor-isolated ClickyController — mirrors the ⌘⌥Esc handler.
        HotkeyManager.shared.onPushToTalkDown = {
            Task { @MainActor in
                ClickyController.shared.beginPushToTalk()
            }
        }
        HotkeyManager.shared.onPushToTalkUp = {
            Task { @MainActor in
                ClickyController.shared.endPushToTalk()
            }
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startMainApp() {
        SideIconWindowController.shared.show()
        // Install the notch HUD — it narrates WHAT Holmes is doing and the live
        // context it's doing it in. Idle bar shows on notch Macs; task/context
        // cards reveal on every Mac.
        Task { @MainActor in NotchWindowController.shared.show() }
        startHolmesAgent()
    }
}
