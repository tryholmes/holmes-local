import SwiftUI

@main
struct holmesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @State private var launchAtLogin = false
    @State private var showNotchAnimation = true
    @State private var selectedTab: SettingsTab = .automations

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case voice = "Voice"
        case automations = "Automations"
        case hotkeys = "Hotkeys"
        case privacy = "Privacy"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .voice: return "waveform"
            case .automations: return "wand.and.stars"
            case .hotkeys: return "keyboard"
            case .privacy: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        ZStack {
            // Apple-glass full-window background, matching the Holmes login/panel look.
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(NoirColors.textPrimary)
                        .rotationEffect(.degrees(-45))
                    Text("HOLMES")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(NoirColors.textPrimary)
                        .tracking(4)
                    Text("SETTINGS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(NoirColors.goldAccent)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                // Custom glass tab selector
                HStack(spacing: 3) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .padding(3)
                .background(NoirColors.glassChrome)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .glassBorder(cornerRadius: 8)
                .padding(.horizontal, 20)

                // Content
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)
            }
        }
        .frame(width: 540, height: 460)
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(launchAtLogin: $launchAtLogin, showNotchAnimation: $showNotchAnimation)
        case .voice:
            VoiceSettingsView()
        case .automations:
            AutomationsSettingsView()
        case .hotkeys:
            HotkeysSettingsView()
        case .privacy:
            PrivacySettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.rawValue).font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(selectedTab == tab ? Color.black.opacity(0.8) : NoirColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == tab ? NoirColors.goldAccent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Automations (proactive playbooks)

struct AutomationsSettingsView: View {
    // Local mirror so the Toggle re-renders; writes straight through to the
    // single source of truth (AutonomyPolicy.shared, default OFF).
    @State private var masterEnabled: Bool

    @MainActor init() {
        _masterEnabled = State(initialValue: AutonomyPolicy.shared.masterEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Global master switch — nothing acts autonomously until this is on.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $masterEnabled) {
                    Text("Autonomous actions")
                        .font(.system(size: 12, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: masterEnabled) { _, newValue in
                    AutonomyPolicy.shared.masterEnabled = newValue
                }
                Text("Auto does reversible work itself and still asks before it sends or deletes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(DefaultPlaybooks.all) { playbook in
                        PlaybookToggleRow(playbook: playbook)
                        if playbook.id != DefaultPlaybooks.all.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Divider()
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(mcpStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("With Autonomous actions off, every playbook stays draft-only — Holmes prepares drafts for your review and never sends, posts, or publishes on its own.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    @MainActor private var mcpStatusText: String {
        let client = MCPClient.shared
        guard !client.transports.isEmpty else {
            return "MCP: \(client.status)"
        }
        let servers = client.transports.map { transport in
            let count = client.tools.filter { $0.serverName == transport.serverName }.count
            return "\(transport.serverName) (\(count) tool\(count == 1 ? "" : "s"))"
        }
        return "MCP connected: " + servers.joined(separator: ", ")
    }
}

struct PlaybookToggleRow: View {
    let playbook: Playbook
    // The per-playbook autonomy dial. Observe == the old "off"; setLevel mirrors
    // the legacy enabled key so PlaybookEngine.isEnabled stays in agreement.
    @State private var level: AutonomyLevel

    @MainActor init(playbook: Playbook) {
        self.playbook = playbook
        _level = State(initialValue: AutonomyPolicy.shared.level(for: playbook.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: playbook.icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(playbook.name)
                        .font(.system(size: 12, weight: .semibold))
                    if !playbook.autoTriggers {
                        Text("MANUAL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(playbook.summary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Manual-only playbooks (MANUAL badge) need a user-facing trigger —
            // without this button nothing in the UI can ever run them.
            if !playbook.autoTriggers {
                Button("Run now") { runNow() }
                    .controlSize(.small)
                    .disabled(level == .observe)
                    .help("Run this playbook once, right now")
            }

            Picker("", selection: $level) {
                ForEach(AutonomyLevel.allCases, id: \.self) { lvl in
                    Text(lvl.displayName).tag(lvl)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help(level.blurb)
            .onChange(of: level) { _, newValue in
                AutonomyPolicy.shared.setLevel(newValue, for: playbook.id)
            }
        }
        .padding(.vertical, 5)
    }

    /// Screen-grounded playbooks run against the latest snapshot so "the thing
    /// on screen" is real. (Scheduled playbooks were removed in the 154→5 purge.)
    @MainActor private func runNow() {
        switch playbook.id {
        default:
            let ctx: PlaybookContext
            if let snapshot = HolmesAgent.shared.lastSnapshot {
                let classified = ContextEngine.shared.classify(snapshot: snapshot)
                ctx = PlaybookContext(
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    contextType: classified.type.rawValue,
                    screenText: snapshot.ocrText,
                    entities: classified.entities
                )
            } else {
                ctx = PlaybookContext(
                    appName: "Holmes",
                    windowTitle: playbook.name,
                    contextType: "manual",
                    screenText: "",
                    entities: [:]
                )
            }
            PlaybookEngine.shared.runManually(playbookId: playbook.id, context: ctx)
        }
    }
}

struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var showNotchAnimation: Bool
    
    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
            
            if NotchDetector.hasNotch {
                Toggle("Show Notch Animation", isOn: $showNotchAnimation)
            }
            
            Divider()
            
            LabeledContent("Side Icon Position") {
                Button("Reset to Default") {
                    UserDefaults.standard.removeObject(forKey: "SideIconPosition")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .padding()
    }
}

// MARK: - Voice & Guidance (the Clicky experience)

struct VoiceSettingsView: View {
    // Seeded from nonisolated config/UserDefaults so the initializer touches no
    // @MainActor state; the live permission + voice-id override are read in onAppear.
    @State private var elevenLabsKey: String = ElevenLabsConfig.apiKey ?? ""
    @State private var voiceID: String = ""
    @State private var isConfigured: Bool = ElevenLabsConfig.isConfigured
    @State private var permissionGranted = false
    @State private var drawGuidance = UserDefaults.standard.object(forKey: ClickyController.Defaults.drawGuidance) as? Bool ?? true
    @State private var speakAnswers = UserDefaults.standard.object(forKey: ClickyController.Defaults.speakAnswers) as? Bool ?? true
    @State private var showPointer = UserDefaults.standard.object(forKey: ClickyController.Defaults.showPointer) as? Bool ?? true
    @State private var narrateActions = UserDefaults.standard.object(forKey: ClickyController.Defaults.narrateActions) as? Bool ?? true
    @State private var isTesting = false
    // What the last "Test voice" actually did — which backend spoke and, on a
    // fallback, why ElevenLabs didn't. Makes a silent Apple fallback visible.
    @State private var testResult: String?

    private enum Field: Hashable { case key, voice }
    @FocusState private var focused: Field?

    var body: some View {
        Form {
            LabeledContent("Push to Talk") {
                Text("Hold Fn to talk")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("Hold the Fn key and speak; release to send. Ask about your screen out loud — Holmes answers and points on screen. Say \u{201C}agent…\u{201D} (or \u{201C}click…\u{201D}, \u{201C}book…\u{201D}, \u{201C}do this…\u{201D}) and it does the task instead.")
                .font(.caption)
                .foregroundColor(.secondary)

            LabeledContent("Microphone & Speech") {
                HStack(spacing: 8) {
                    Image(systemName: permissionGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(permissionGranted ? .green : .orange)
                    if !permissionGranted {
                        Button("Enable") {
                            Task { @MainActor in
                                permissionGranted = await ClickyController.shared.requestVoicePermission()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text("On-device transcription (Apple Speech). Your voice is never sent to a server for recognition.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            SecureField("ElevenLabs API key", text: $elevenLabsKey)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .key)
                .onSubmit { commitKey() }

            TextField("Voice ID", text: $voiceID, prompt: Text(ElevenLabsConfig.defaultVoiceID))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .voice)
                .onSubmit { commitVoiceID() }

            HStack(spacing: 8) {
                Image(systemName: isConfigured ? "waveform.circle.fill" : "speaker.wave.2.fill")
                    .foregroundColor(isConfigured ? .green : .secondary)
                Text(isConfigured
                     ? "Natural voice (ElevenLabs)."
                     : "System voice — add an ElevenLabs key for a natural voice.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(isTesting ? "Testing…" : "Test voice") {
                    Task { @MainActor in
                        // Persist whatever is currently typed/pasted BEFORE testing.
                        // Clicking a button on macOS does not always resign the text
                        // field's first responder, so `.onChange(of: focused)` may not
                        // have fired yet — without this, a freshly-pasted key/voice
                        // would be tested (and saved) as if it were never entered.
                        commitKey()
                        commitVoiceID()

                        isTesting = true
                        testResult = nil
                        // Same speak() path real answers use, so the test reflects reality.
                        await SpeechSynthesizer.shared.speak("Holmes, at your service.")
                        isTesting = false

                        switch SpeechSynthesizer.shared.activeBackend {
                        case .elevenLabs:
                            testResult = "Played via ElevenLabs."
                        case .apple:
                            if let reason = SpeechSynthesizer.shared.lastError {
                                testResult = "System voice (ElevenLabs failed): \(reason)"
                            } else {
                                testResult = "Played via system voice (no ElevenLabs key)."
                            }
                        case .none:
                            testResult = "Nothing played."
                        }
                    }
                }
                .controlSize(.small)
                .disabled(isTesting)
            }

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundColor(testResult.hasPrefix("Played via ElevenLabs") ? .green : .secondary)
                    .textSelection(.enabled)
            }

            Divider()

            Toggle("Draw guidance on screen", isOn: $drawGuidance)
                .onChange(of: drawGuidance) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: ClickyController.Defaults.drawGuidance)
                }
            Text("When Holmes answers a question about your screen, it points the way with on-screen circles, arrows, and highlights.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Speak answers", isOn: $speakAnswers)
                .onChange(of: speakAnswers) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: ClickyController.Defaults.speakAnswers)
                }

            Divider()

            Toggle("Show Holmes on screen", isOn: $showPointer)
                .onChange(of: showPointer) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: ClickyController.Defaults.showPointer)
                }
            Text("When Holmes acts for you, it draws a glowing ring at each spot it clicks or types — so you can watch it work.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Holmes narrates actions", isOn: $narrateActions)
                .onChange(of: narrateActions) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: ClickyController.Defaults.narrateActions)
                }
            Text("Holmes speaks a short line as it works — \u{201C}Opening Finder\u{201D}, \u{201C}Moving the files\u{201D} — and asks out loud before anything it can\u{2019}t undo.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .scrollContentBackground(.hidden)
        .padding()
        .onChange(of: focused) { oldValue, _ in
            // Commit whichever field just lost focus (click-away or tab), so a key
            // typed without pressing Return still saves.
            if oldValue == .key { commitKey() }
            if oldValue == .voice { commitVoiceID() }
        }
        .onAppear {
            permissionGranted = ClickyController.shared.voicePermissionGranted
            isConfigured = ElevenLabsConfig.isConfigured
            let stored = ElevenLabsConfig.voiceID
            voiceID = (stored == ElevenLabsConfig.defaultVoiceID) ? "" : stored
        }
    }

    private func commitKey() {
        ElevenLabsConfig.setAPIKey(elevenLabsKey)
        isConfigured = ElevenLabsConfig.isConfigured
    }

    private func commitVoiceID() {
        ElevenLabsConfig.setVoiceID(voiceID)
    }
}

struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Open Search") {
                Text("Control + Space")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            LabeledContent("Open Assistant") {
                Text("Option + Space")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            LabeledContent("Toggle Side Icon") {
                Text("Command + \\")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            LabeledContent("Push to Talk") {
                Text("Hold Fn to talk")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            LabeledContent("Stop Computer Control") {
                Text("Command + Option + Esc")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .padding()
    }
}

struct PrivacySettingsView: View {
    @State private var mcpServerEnabled = MCPServer.isEnabledByUser
    @State private var bridge = BrowserBridge.shared
    @State private var copiedToken = false
    // Read straight from the backing default (a plain `static let` key, not the
    // @MainActor engine) so the initializer touches no isolated state.
    @State private var computerUseEnabled = UserDefaults.standard.bool(forKey: ComputerUseEngine.enabledDefaultsKey)
    // "Test Clicky" self-test: isolates the drawing, speech, and CGEvent layers so
    // "I see no drawing" / "Accessibility doesn't work" each get a definite answer.
    @State private var isTestingClicky = false
    @State private var clickyTestResult: String?

    var body: some View {
        Form {
            LabeledContent("Screen Recording") {
                HStack {
                    Image(systemName: PermissionManager.checkScreenRecordingPermission() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(PermissionManager.checkScreenRecordingPermission() ? .green : .red)

                    Button("Open Settings") {
                        PermissionManager.openScreenRecordingSettings()
                    }
                }
            }

            LabeledContent("Accessibility") {
                HStack {
                    Image(systemName: PermissionManager.checkAccessibilityPermission() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(PermissionManager.checkAccessibilityPermission() ? .green : .red)

                    Button("Open Settings") {
                        PermissionManager.openAccessibilitySettings()
                    }
                }
            }

            LabeledContent("Calendar") {
                HStack {
                    Image(systemName: PermissionManager.checkCalendarPermission() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(PermissionManager.checkCalendarPermission() ? .green : .orange)

                    Button("Open Settings") {
                        PermissionManager.openCalendarSettings()
                    }
                }
            }

            Divider()

            // Computer control (OpenClicky-derived pixel mouse/keyboard). Off by
            // default; only reachable on user-initiated runs, never playbooks.
            Toggle("Computer control", isOn: $computerUseEnabled)
                .onChange(of: computerUseEnabled) { _, newValue in
                    ComputerUseEngine.shared.isEnabled = newValue
                }
            Text("Lets Holmes click and type on your Mac when you ask it to. Off by default. Irreversible actions like Send/Delete still ask first. Stop any run instantly with ⌘⌥Esc.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Stale-grant banner: macOS evaluates Accessibility trust when a
            // process LAUNCHES, so a grant made while Holmes is running is not
            // seen by this process until it relaunches — the #1 cause of "I
            // granted it but clicks do nothing". `computerUseEnabled` (the
            // @State) is in the condition so flipping the toggle re-renders
            // this immediately; the helper re-probes AXIsProcessTrusted().
            if computerUseEnabled && PermissionManager.needsRelaunchForAccessibility() {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You granted Accessibility, but macOS applies it only on relaunch — click Relaunch and Holmes will come back able to click and type. (If you haven't granted it yet, do that first via Open Settings above.)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Relaunch Holmes") {
                            PermissionManager.relaunchApp()
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            // Clicky self-test — proves each layer independently: it flashes the
            // on-screen pointer ring (drawing), speaks a line (voice), and posts one
            // harmless real keystroke via ComputerUseEngine (Accessibility/CGEvent),
            // then reports exactly which layers worked and why any didn't.
            HStack(spacing: 8) {
                Button(isTestingClicky ? "Testing…" : "Test Holmes") {
                    Task { @MainActor in
                        isTestingClicky = true
                        clickyTestResult = nil
                        clickyTestResult = await runClickyTest()
                        isTestingClicky = false
                    }
                }
                .controlSize(.small)
                .disabled(isTestingClicky)
                Text("Flashes the pointer ring, speaks a line, and posts one harmless keystroke.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let clickyTestResult {
                Text(clickyTestResult)
                    .font(.caption)
                    .foregroundColor(clickyTestResult.hasPrefix("\u{2713}") ? .green : .orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Share screen context with local MCP clients", isOn: $mcpServerEnabled)
                .onChange(of: mcpServerEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: MCPServer.enabledDefaultsKey)
                    if newValue {
                        MCPServer.shared.start()
                    } else {
                        MCPServer.shared.stop()
                    }
                }
            Text("Off by default. When on, any process on this Mac can read what's on your screen through Holmes's MCP server at 127.0.0.1:5767 — enable only if you use a local MCP client like Claude Desktop.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // The browser bridge carries the full contents of every page the
            // extension reads, so its state is privacy state — the user should
            // never have to guess whether something is connected to this port.
            LabeledContent("Browser bridge") {
                HStack(spacing: 6) {
                    Image(systemName: bridgeIcon)
                        .foregroundColor(bridgeColor)
                    Text(bridgeStatus)
                        .font(.caption)
                }
            }
            Text(bridgeDetail)
                .font(.caption)
                .foregroundColor(.secondary)
            // Pairing is a deliberate act. The extension mints its own secret, and
            // Holmes will not adopt one on its own initiative — a loopback port is
            // reachable by every process on this Mac, so "whoever posts first" is
            // not an authorization. This button is the authorization.
            HStack(spacing: 8) {
                if bridge.isPairing {
                    Button("Cancel pairing") { bridge.cancelPairing() }
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(bridge.pairedToken == nil ? "Pair browser extension" : "Re-pair browser extension") {
                        bridge.beginPairing()
                    }
                }
                Button(copiedToken ? "Copied" : "Copy token") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BrowserBridge.shared.token, forType: .string)
                    copiedToken = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedToken = false }
                }
                Text(BrowserBridge.tokenFileURL.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            Text("Screen context stays on this Mac. Text you act on — a command you run, a reply Holmes drafts, the goal behind the current screen — is sent to Anthropic's API (claude-opus-4-8) to produce that result, and only then.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .scrollContentBackground(.hidden)
        .padding()
    }

    // MARK: Clicky self-test

    /// Exercises each Clicky layer in isolation and returns a one-line verdict.
    ///   1. draws the pointer ring at screen center (no permission needed),
    ///   2. speaks "Holmes is working" via the real TTS path (no permission needed),
    ///   3. posts one harmless keystroke (a brief Shift hold — types nothing)
    ///      through ComputerUseEngine so the master switch + Accessibility +
    ///      CGEvent posting are all genuinely exercised.
    /// Drawing and speech always run so the user SEES/HEARS them even when
    /// computer control is off; the returned text names the exact blocker.
    @MainActor
    private func runClickyTest() async -> String {
        // 1. Drawing — flash the ring at the center of the main display.
        if let screen = NSScreen.main {
            let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            VisualGuidanceOverlay.shared.flashPointer(
                atGlobalPoint: center, label: "Holmes", duration: 1.4)
        }
        // 2. Speech — fire-and-forget so the verdict isn't gated on playback.
        Task { @MainActor in await SpeechSynthesizer.shared.speak("Holmes is working.") }

        // 3. CGEvent — one harmless keystroke through the gated engine.
        let engine = ComputerUseEngine.shared
        guard engine.isEnabled else {
            return "Drawing + speech OK. Computer control is OFF — turn on \u{201C}Computer control\u{201D} above to let Holmes click and type."
        }
        guard PermissionManager.checkAccessibilityPermission() else {
            return "Drawing + speech OK. Accessibility isn\u{2019}t granted (or is stale) — grant it via Open Settings above, then click Relaunch Holmes."
        }
        engine.beginRun() // clear any stale kill flag so the test event can post
        let outcome = await engine.perform(action: "hold_key", input: ["text": "shift", "duration": 0.05])
        if outcome.isRefused {
            return "Drawing + speech OK. Computer control is OFF — turn it on above."
        }
        if outcome.isError {
            return "Drawing + speech OK, but the test keystroke didn\u{2019}t post: \(outcome.text)"
        }
        return "\u{2713} Holmes clicked — drawing, speech, and Accessibility all work."
    }

    // MARK: Bridge status

    private var bridgeIcon: String {
        if bridge.lastError != nil { return "exclamationmark.triangle.fill" }
        return bridge.isExtensionConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var bridgeColor: Color {
        if bridge.lastError != nil { return .red }
        return bridge.isExtensionConnected ? .green : .orange
    }

    private var bridgeStatus: String {
        if bridge.lastError != nil { return "Not listening" }
        if bridge.isPairing { return "Pairing — waiting for the extension" }
        if bridge.isExtensionConnected { return "Extension connected" }
        // Not connected: name WHICH failure it is, so the short line is actionable
        // instead of an ambiguous "Waiting…". A token being rejected outranks
        // "never paired", because a mismatch is the case the user most needs to act on.
        if bridge.unauthorizedRequests > 0 { return "Token mismatch — re-pair the extension" }
        if bridge.pairedToken == nil { return "Not paired" }
        return "Paired — waiting for the browser"
    }

    /// Says exactly which of the four shapes is happening: the port never opened,
    /// pairing is armed, something is connecting with a secret Holmes doesn't
    /// know, or everything is fine. Those look identical from the outside otherwise.
    private var bridgeDetail: String {
        if let error = bridge.lastError {
            return "\(error) — Holmes can't read pages until this is resolved."
        }
        if bridge.isPairing {
            return "Pairing is open for the next couple of minutes: the next extension to post to 127.0.0.1:\(BrowserBridge.port) is adopted and remembered. A web page can't take it — only an extension origin (or a local client you point at the token) may pair."
        }
        if bridge.unauthorizedRequests > 0 {
            return "\(bridge.unauthorizedRequests) request\(bridge.unauthorizedRequests == 1 ? "" : "s") rejected: something is posting to 127.0.0.1:\(BrowserBridge.port) with a token Holmes doesn't know. If that's your extension, click Pair browser extension — Holmes never adopts a secret on its own, because every process on this Mac can reach a loopback port."
        }
        if bridge.isExtensionConnected {
            let paired = bridge.pairedToken == nil ? "" : " Paired with the extension's own token."
            return "Listening on 127.0.0.1:\(BrowserBridge.port), loopback only.\(paired)"
        }
        // Listening, nothing rejected, but no traffic. Distinguish "never paired" from
        // "paired, extension just isn't posting right now" — different fixes: the first
        // needs a pairing, the second needs the browser open (or is simply the worker
        // between beats, which now clears itself within ~90s).
        if bridge.pairedToken != nil {
            return "Listening on 127.0.0.1:\(BrowserBridge.port), loopback only. Paired with the extension, but nothing has posted lately — open your browser (with the Holmes extension loaded) and this reconnects on the next beat. If it never does, the extension may have minted a new token; click Re-pair browser extension."
        }
        return "Listening on 127.0.0.1:\(BrowserBridge.port), loopback only. No extension is paired yet. Load the Holmes extension in your browser, then click Pair browser extension to authorize it once."
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundStyle(NoirColors.goldAccent)
                .rotationEffect(.degrees(-45))

            Text("HOLMES")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(NoirColors.textPrimary)
                .tracking(4)

            Text("Zero Prompt AI for macOS")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(NoirColors.textSecondary)

            Text("Version 1.0.0")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(NoirColors.textTertiary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
