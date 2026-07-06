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
        case automations = "Automations"
        case hotkeys = "Hotkeys"
        case privacy = "Privacy"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                Text("Proactive mode is draft-only — Holmes prepares drafts for your review and never sends, posts, or publishes anything.")
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
    @State private var isOn: Bool

    @MainActor init(playbook: Playbook) {
        self.playbook = playbook
        _isOn = State(initialValue: PlaybookEngine.isEnabled(playbook.id))
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
                    .disabled(!isOn)
                    .help("Run this playbook once, right now")
            }

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isOn) { _, newValue in
                    PlaybookEngine.setEnabled(newValue, playbookId: playbook.id)
                }
        }
        .padding(.vertical, 5)
    }

    /// Scheduled playbooks reuse Autopilot's fire path (which keeps its
    /// once-per-day bookkeeping); screen-grounded ones (ai-research) run
    /// against the latest snapshot so "the question on screen" is real.
    @MainActor private func runNow() {
        switch playbook.id {
        case "morning-brief", "email-triage",
             "follow-up-chaser", "pr-radar", "schedule-guard", "evening-wrapup":
            Autopilot.shared.fireNow(playbook.id)
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
        }
        .scrollContentBackground(.hidden)
        .padding()
    }
}

struct PrivacySettingsView: View {
    @State private var mcpServerEnabled = MCPServer.isEnabledByUser

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

            Text("Holmes processes all data locally on your device. No data is sent to external servers.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .scrollContentBackground(.hidden)
        .padding()
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
