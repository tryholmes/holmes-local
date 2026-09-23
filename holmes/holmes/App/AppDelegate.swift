import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var onboardingWindow: NSWindow?
    /// The model is preloaded once, the first time Ollama reports ready, so the
    /// first real request doesn't pay the 20-40 s cold load.
    private var warmedUpModel: String? = nil
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var extensionUpdateNeedsNotice = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NoirFonts.registerBundledFonts()
        // A write into the stdin pipe of an MCP server that has already exited
        // raises SIGPIPE, which terminates the process silently. Ignore it;
        // FileHandle.write then throws EPIPE, which MCPClient already handles.
        signal(SIGPIPE, SIG_IGN)

        // Fire and forget: the service sends once per install, then at most
        // once a day, and never blocks launch.
        HolmesCloud.sendInstallPing()

        do {
            if let folder = try ExtensionInstaller.refreshInstalledIfNeeded() {
                extensionUpdateNeedsNotice = true
                print("[Holmes] Updated unpacked extension at \(folder.path) — reload Holmes on chrome://extensions, then refresh Gmail")
            }
        } catch {
            print("[Holmes] Extension refresh skipped: \(error.localizedDescription)")
        }

        setupApp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MenuBarManager.shared.stopAllWork()
            GuidedDemoWindowController.shared.close()
        }
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        lifecycleObservers.removeAll()
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
        setupWorkLifecycle()

        Task { @MainActor in
            // Local model: readiness = "Ollama answers AND the chosen model is
            // pulled". Every flip re-labels the backend in the main panel; the
            // first .ready also preloads the model. Wire the hook BEFORE the
            // monitor starts so the first probe can't slip past it.
            startLocalModel()

            // Wire voice routing without opening the microphone. Permissions
            // and capture begin only in response to a physical Fn hold.
            ClickyController.shared.start()
            await handleAuthAndLaunch()
        }
    }

    /// Probe Ollama, auto-start it if allowed, and keep monitoring (every 30 s
    /// and after any settings change). Runs from the very start of launch so
    /// the server is usually up by the time onboarding or the first request
    /// needs it.
    @MainActor
    private func startLocalModel() {
        OllamaConfig.onStatusChanged = { [weak self] in
            Task { @MainActor in
                HolmesBrain.shared.updateBackendLabel()
                // Warm + prime once PER MODEL: a switch in Settings must not
                // leave the new model cold with the old prefix primed.
                let model = OllamaConfig.model
                guard let self, OllamaConfig.isConfigured, self.warmedUpModel != model else { return }
                self.warmedUpModel = model
                await OllamaServer.shared.warmUp()
                await HolmesBrain.shared.primeLocalModel()
            }
        }
        OllamaServer.shared.start()
    }

    @MainActor
    private func handleAuthAndLaunch() async {
        // Every cold launch opens with the brand intro. The first run plays it
        // inside onboarding; later launches play it on its own while the
        // session restores, and the app starts once it ends.
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let intro = hasCompletedOnboarding ? Task { await LaunchIntroWindowController.shared.play() } : nil
        // Holmes requires an account. The SDK keeps the session between
        // launches, so this only asks when no valid session exists.
        let signedIn = await AuthService.shared.restoreSession()
        await intro?.value
        observeSignOut()
        if !hasCompletedOnboarding {
            showOnboarding(requiresSignIn: !signedIn)
        } else if signedIn {
            startMainAppOnce()
        } else {
            // Finished onboarding before accounts existed, or signed out.
            SignInWindowController.shared.show { [weak self] in
                self?.startMainAppOnce()
            }
        }
    }

    private var signOutObserver: NSObjectProtocol?

    private func observeSignOut() {
        guard signOutObserver == nil else { return }
        signOutObserver = NotificationCenter.default.addObserver(
            forName: .holmesDidSignOut, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true {
                    window.close()
                }
                SignInWindowController.shared.show {
                    self?.startMainAppOnce()
                }
            }
        }
    }

    private func startHolmesAgent() {
        Task { @MainActor in
            guard !MenuBarManager.shared.isPaused, !MenuBarManager.shared.isSystemSuspended else { return }
            await HolmesAgent.shared.start()
        }
    }

    private func setupWorkLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarManager.shared.suspendForSystemEvent() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarManager.shared.resumeAfterSystemEvent() }
            })
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
                AutonomousActionRunner.shared.cancelCurrentRun()
                WorkActivityCenter.shared.cancelSelected()
            }
        }

        // Hold Fn (globe) — Clicky push-to-talk, true hold-to-talk. HotkeyManager
        // watches the .function modifier flag via NSEvent monitors: Fn-DOWN begins
        // listening, Fn-UP ends it and routes the transcript (ask-and-draw, or hand
        // off to the agent). The monitor callbacks are nonisolated closures (NSEvent
        // invokes them on the main thread), so hop onto the MainActor to reach the
        // @MainActor-isolated ClickyController — mirrors the ⌘⌥Esc handler.
        HotkeyManager.shared.onPushToTalkDown = { holdID in
            Task { @MainActor in
                ClickyController.shared.beginPushToTalk(holdID: holdID)
            }
        }
        HotkeyManager.shared.onPushToTalkUp = { holdID in
            Task { @MainActor in
                ClickyController.shared.endPushToTalk(holdID: holdID)
            }
        }
        HotkeyManager.shared.onPushToTalkCancel = { holdID in
            // Lifecycle notifications and monitor teardown arrive on the main
            // thread. Cancel before returning: a queued nil-ID cancellation
            // could otherwise discard a new hold started immediately after wake.
            MainActor.assumeIsolated {
                ClickyController.shared.cancelPushToTalk(holdID: holdID)
            }
        }

        HotkeyManager.shared.registerHotkeys()
    }

    private func showOnboarding(requiresSignIn: Bool) {
        let onboardingView = OnboardingFlow(requiresSignIn: requiresSignIn) {
            DispatchQueue.main.async { [weak self] in
                self?.finishOnboarding()
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
        // A programmatically created NSWindow defaults to releasing ITSELF on
        // close(). We also hold it in `onboardingWindow`, so close() followed by
        // `= nil` released it twice — a main-thread EXC_BAD_ACCESS in
        // objc_release. Own it explicitly instead.
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        // The red traffic light is a second way out of onboarding. Without this
        // the window vanished and nothing started the main app — a menu-bar app
        // with no menu bar item. Treat it like "finish": the flag stays unset,
        // so onboarding simply shows again next launch.
        onboardingCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.finishOnboarding() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onboardingCloseObserver: NSObjectProtocol?
    private var mainAppStarted = false

    /// Idempotent: reached from the Ready screen's button AND from the window's
    /// own close button.
    private func finishOnboarding() {
        if let obs = onboardingCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            onboardingCloseObserver = nil
        }
        if let window = onboardingWindow {
            onboardingWindow = nil
            if window.isVisible { window.close() }
        }
        guard AuthService.shared.isSignedIn else {
            // Closed before signing in. Sign in is required, so quit;
            // onboarding shows again next launch.
            NSApp.terminate(nil)
            return
        }
        startMainAppOnce()
    }

    private func startMainAppOnce() {
        guard !mainAppStarted else { return }
        mainAppStarted = true
        startMainApp()
    }

    private func startMainApp() {
        SideIconWindowController.shared.show()
        // Install the notch HUD — it narrates WHAT Holmes is doing and the live
        // context it's doing it in. Idle bar shows on notch Macs; task/context
        // cards reveal on every Mac.
        Task { @MainActor in
            NotchWindowController.shared.show()
            if extensionUpdateNeedsNotice {
                extensionUpdateNeedsNotice = false
                let notice = "Browser extension updated. Reload Holmes at chrome://extensions, then refresh Gmail."
                let activity = WorkActivityCenter.shared.begin(title: "Browser extension updated")
                WorkActivityCenter.shared.finish(activity, outcome: .success, summary: notice)
                NotchWindowController.shared.viewModel.showSneakPeek(
                    title: "Browser extension updated",
                    subtitle: "Reload Holmes at chrome://extensions, then refresh Gmail.",
                    symbol: "puzzlepiece.extension", duration: 12)
            }
            GuidedDemoWindowController.shared.showIfNeeded()
        }
        startHolmesAgent()
    }
}
