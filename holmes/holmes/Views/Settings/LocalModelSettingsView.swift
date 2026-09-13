import SwiftUI
import AppKit

/// Settings and onboarding share the same server state and model actions.
/// The full pane scrolls as one surface, including expanded advanced controls.
@MainActor
struct LocalModelSettingsView: View {
    let compact: Bool

    @State private var selectedModel = OllamaConfig.model
    @State private var hostText = OllamaConfig.host
    @State private var savedHost = OllamaConfig.host
    @State private var hostError: String?
    @State private var numCtx = OllamaConfig.numCtx
    @State private var keepAlive = OllamaConfig.keepAlive
    @State private var thinking = OllamaConfig.thinkingEnabled
    @State private var autoStart = OllamaConfig.autoStartServer
    @State private var backgroundModel = OllamaConfig.backgroundModelEnabled
    @State private var automaticGlow = ScreenGlowController.contextGlowEnabled
    @State private var coordinateChoice = UserDefaults.standard.string(forKey: "ollama.coordinateSpace") ?? "automatic"
    @State private var customTag = ""
    @State private var showAdvanced = false
    @State private var isStarting = false
    @State private var isRefreshing = false
    @FocusState private var hostFocused: Bool

    init(compact: Bool = false) { self.compact = compact }

    private var server: OllamaServer { OllamaServer.shared }
    static let downloadURL = URL(string: "https://ollama.com/download")!

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 12) {
                    statusCard
                    currentModelCard
                    downloadFeedback
                }
                .frame(maxWidth: 450)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        currentModelCard
                        downloadFeedback
                        installedSection
                        advancedCard
                        recommendedSection
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
            }
        }
        .font(NoirFonts.font(size: 12, weight: .regular))
        .foregroundStyle(NoirColors.textPrimary)
        .tint(NoirColors.accent)
        .buttonStyle(LocalModelButtonStyle())
        .onAppear { syncFromConfig() }
        // Refresh mirrors on probe completion and automatic model adoption.
        .onChange(of: server.status) { _, _ in syncFromConfig() }
        .onChange(of: server.lastProbe) { _, _ in syncFromConfig() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            syncFromConfig()
        }
    }

    private func syncFromConfig() {
        selectedModel = OllamaConfig.model
        // A background probe must not erase a server address being edited.
        if !hostFocused && hostText == savedHost { hostText = OllamaConfig.host }
        savedHost = OllamaConfig.host
        numCtx = OllamaConfig.numCtx
        keepAlive = OllamaConfig.keepAlive
        thinking = OllamaConfig.thinkingEnabled
        autoStart = OllamaConfig.autoStartServer
        backgroundModel = OllamaConfig.backgroundModelEnabled
        automaticGlow = ScreenGlowController.contextGlowEnabled
        coordinateChoice = UserDefaults.standard.string(forKey: "ollama.coordinateSpace") ?? "automatic"
    }

    private var serverReachable: Bool {
        switch server.status {
        case .ready, .modelMissing, .modelUnsuitable: return true
        default: return false
        }
    }

    private var currentChoice: OllamaConfig.ModelChoice? {
        OllamaConfig.recommendedModels.first { OllamaServer.sameTag($0.name, selectedModel) }
    }

    private var statusTitle: String {
        switch server.status {
        case .unknown: return "Checking Ollama"
        case .starting: return "Starting Ollama"
        case .notInstalled: return "Install Ollama to begin"
        case .unreachable: return "Server unavailable"
        case .modelMissing: return "Choose or download a model"
        case .modelUnsuitable: return "Choose a compatible model"
        case .ready: return "Ready to help"
        }
    }

    private var statusDetail: String {
        switch server.status {
        case .unknown: return "Checking the server and selected model."
        case .starting: return "Waiting for the local server to answer."
        case .notInstalled: return "Open Ollama once after installing, then check the connection."
        case .unreachable(let reason): return reason
        case .modelMissing: return "The server is connected. Your selected model still needs to be downloaded."
        case .modelUnsuitable(_, let reason): return reason
        case .ready: return "One model handles vision and tools for Holmes."
        }
    }

    private var statusIcon: String {
        switch server.status {
        case .unknown, .starting: return "hourglass"
        case .notInstalled: return "arrow.down.to.line"
        case .unreachable: return "wifi.slash"
        case .modelMissing: return "square.and.arrow.down"
        case .modelUnsuitable: return "exclamationmark.triangle"
        case .ready: return "checkmark"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .ready: return NoirColors.success
        case .unreachable, .modelUnsuitable: return NoirColors.error
        case .notInstalled, .modelMissing: return .orange
        default: return NoirColors.textSecondary
        }
    }

    private var statusCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 38, height: 38)
                    .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle).font(NoirFonts.font(size: 16, weight: .semibold))
                    detail(statusDetail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: recheck) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(isRefreshing || isStarting)
                .accessibilityLabel(isRefreshing ? "Checking connection" : "Check connection")
                .help("Check the server and available models")
            }

            HStack(spacing: 8) {
                Text(OllamaServer.isLocalHost ? "ON THIS MAC" : "REMOTE SERVER")
                    .font(NoirFonts.font(size: 9, weight: .semibold))
                    .tracking(1)
                if let version = server.serverVersion, serverReachable {
                    Text("Ollama \(version)")
                        .font(NoirFonts.font(size: 11, weight: .regular))
                }
                Spacer(minLength: 0)
                statusAction
            }
            .foregroundStyle(NoirColors.textSecondary)

            if let warning = server.versionWarning, serverReachable {
                detail(warning, color: .orange)
            }
        }
    }

    @ViewBuilder private var statusAction: some View {
        switch server.status {
        case .notInstalled:
            Button("Get Ollama") { NSWorkspace.shared.open(Self.downloadURL) }
        case .unreachable where OllamaServer.isLocalHost:
            Button(isStarting ? "Starting…" : "Start Ollama", action: startServer)
                .disabled(isStarting)
        case .unknown, .starting:
            ProgressView().controlSize(.small)
        default:
            if isRefreshing { Text("Checking…").font(NoirFonts.font(size: 11, weight: .regular)) }
        }
    }

    private var currentModelCard: some View {
        card {
            sectionLabel("Selected model")
            Text(selectedModel)
                .font(NoirFonts.font(size: compact ? 14 : 18, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentModelState)
                        .font(NoirFonts.font(size: 11, weight: .medium))
                        .foregroundStyle(server.status.isReady ? NoirColors.success : NoirColors.textSecondary)
                    Text("\(numCtx.formatted()) token context")
                        .font(NoirFonts.font(size: 11, weight: .regular))
                        .foregroundStyle(NoirColors.textSecondary)
                }
                Spacer(minLength: 0)
                if !server.isInstalled(selectedModel) {
                    modelAction(name: selectedModel, blocked: currentChoice.flatMap(blocker))
                }
            }

            if let blocked = currentChoice.flatMap(blocker), !server.isInstalled(selectedModel) {
                detail(blocked, color: .orange)
            }
            if compact { detail(compactFootnote) }
        }
    }

    private var currentModelState: String {
        if server.status.isReady { return "In use · vision + tools" }
        if case .modelUnsuitable = server.status { return "Missing required capabilities" }
        if !serverReachable { return "Waiting for server" }
        return server.isInstalled(selectedModel) ? "Checking capabilities" : "Not downloaded"
    }

    @ViewBuilder private var downloadFeedback: some View {
        if let progress = server.pull {
            card {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    sectionLabel("Model download")
                    Spacer()
                    if progress.total > 0 {
                        Text("\(Int((min(1, max(0, progress.fraction)) * 100).rounded()))%")
                            .font(NoirFonts.font(size: 12, weight: .semibold))
                    }
                    Button(progress.status == "Cancelling…" ? "Cancelling…" : "Cancel") { server.cancelPull() }
                        .disabled(progress.status == "Cancelling…")
                }
                Text(progress.model)
                    .font(NoirFonts.font(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress.total > 0 ? min(1, max(0, progress.fraction)) : nil)
                    .controlSize(.small)
                detail(progressText(progress))
            }
        } else if let error = server.pullError {
            card {
                sectionLabel(error.hasPrefix("Download paused") ? "Download paused" : "Download needs attention")
                detail(error, color: error.hasPrefix("Download paused") ? NoirColors.textSecondary : NoirColors.error)
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel(OllamaServer.isLocalHost ? "Installed on this Mac" : "Installed on server")
                Spacer()
                Text("\(server.installedModels.count)")
                    .font(NoirFonts.font(size: 11, weight: .medium))
                    .foregroundStyle(NoirColors.textSecondary)
            }
            card {
                if server.installedModels.isEmpty {
                    detail(serverReachable ? "No models yet. Download a recommended model below." : "Connect to Ollama to see installed models.")
                } else {
                    ForEach(server.installedModels) { model in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name)
                                    .font(NoirFonts.font(size: 12, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                detail([model.sizeText, model.parameterSize, model.family].filter { !$0.isEmpty }.joined(separator: " · "))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            modelAction(name: model.name)
                        }
                        if model.id != server.installedModels.last?.id { divider }
                    }
                }
            }
            if !server.installedModels.isEmpty {
                detail("Holmes checks vision and tool support when you select a model.")
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Recommended models")
            detail(OllamaServer.isLocalHost
                   ? "Sized for this Mac’s \(OllamaConfig.physicalMemoryGB) GB memory. Download a model, then choose Use."
                   : "Downloads are stored on your Ollama server. Choose a size that fits that machine’s memory.")
            card {
                ForEach(OllamaConfig.recommendedModels) { choice in
                    recommendedRow(choice)
                    if choice.id != OllamaConfig.recommendedModels.last?.id { divider }
                }
            }
        }
    }

    private func recommendedRow(_ choice: OllamaConfig.ModelChoice) -> some View {
        let blocked = blocker(choice)
        return VStack(alignment: .leading, spacing: 7) {
            if OllamaServer.isLocalHost && OllamaServer.sameTag(choice.name, OllamaConfig.recommendedModel) {
                Text("SUGGESTED FOR THIS MAC")
                    .font(NoirFonts.font(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(NoirColors.accent)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.name)
                        .font(NoirFonts.font(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    detail("\(sizeText(choice.sizeGB)) download · \(choice.minMemoryGB) GB+ memory")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                modelAction(name: choice.name, blocked: blocked)
            }
            detail(choice.note)
            if let blocked { detail(blocked, color: .orange) }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func modelAction(name: String, blocked: String? = nil) -> some View {
        if server.isInstalled(name) {
            let selected = OllamaServer.sameTag(name, selectedModel)
            Button(selected ? "Selected" : "Use") {
                selectedModel = name
                OllamaConfig.model = name
            }
            .disabled(selected || !serverReachable)
        } else {
            Button(isPulling(name) ? "Downloading…" : "Download") { download(name) }
                .disabled(blocked != nil || server.isPulling || !serverReachable)
                .help(blocked ?? (!serverReachable ? "Connect to Ollama first" : server.isPulling ? "Wait for the current download" : "Download \(name)"))
        }
    }

    // MARK: Advanced settings

    private var advancedCard: some View {
        card {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Advanced").font(NoirFonts.font(size: 14, weight: .medium))
                        detail("Server, memory and model behavior")
                    }
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
            if showAdvanced {
                divider
                advancedControls
            }
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Server address")
                HStack(spacing: 8) {
                    TextField(OllamaConfig.defaultHost, text: $hostText)
                        .textFieldStyle(.plain)
                        .font(NoirFonts.font(size: 12, weight: .regular))
                        .padding(9)
                        .background(NoirColors.glassInput, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(NoirColors.glassBorder, lineWidth: 1))
                        .focused($hostFocused)
                        .onSubmit(commitHost)
                        .accessibilityLabel("Ollama server address")
                    Button("Apply", action: commitHost)
                        .disabled(hostText == savedHost || server.isPulling)
                }
                if let hostError { detail(hostError, color: NoirColors.error) }
                detail("A remote server receives Holmes’s screen context and screenshots. Changing servers is unavailable during a download.")
                Button("Use local default") {
                    hostText = OllamaConfig.defaultHost
                    commitHost()
                }
                .disabled(savedHost == OllamaConfig.defaultHost || server.isPulling)
            }

            divider
            settingRow("Context window", explanation: "More history uses more memory. Changing this reloads the model.") {
                Picker("Context window", selection: binding($numCtx) { OllamaConfig.numCtx = $0 }) {
                    ForEach(contextOptions, id: \.self) { Text("\($0.formatted()) tokens").tag($0) }
                }
            }
            settingRow("Keep model loaded", explanation: "Keep it in memory between requests to avoid a cold start.") {
                Picker("Keep model loaded", selection: binding($keepAlive) { OllamaConfig.keepAlive = $0 }) {
                    ForEach(keepAliveOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            settingRow("Click coordinates", explanation: "Automatic follows the selected model. Change this if clicks are consistently scaled incorrectly.") {
                Picker("Click coordinates", selection: binding($coordinateChoice, write: setCoordinates)) {
                    Text("Automatic").tag("automatic")
                    Text("Screen pixels").tag(OllamaConfig.CoordinateSpace.pixels.rawValue)
                    Text("0–1000 grid").tag(OllamaConfig.CoordinateSpace.normalized1000.rawValue)
                }
            }

            divider
            toggleRow("Start Ollama automatically", explanation: "Starts the local server when needed. It keeps running after Holmes quits.", value: binding($autoStart) { OllamaConfig.autoStartServer = $0 })
            toggleRow("Background model work", explanation: "Enriches screen context between tasks and uses more GPU time. Off by default.", value: binding($backgroundModel) { OllamaConfig.backgroundModelEnabled = $0 })
            toggleRow("Glow on automatic actions", explanation: "Also show the screen glow when a playbook starts on its own.", value: binding($automaticGlow) { ScreenGlowController.contextGlowEnabled = $0 })
            toggleRow("Think before acting", explanation: "Can make each step much slower. An instruct model is usually faster.", value: binding($thinking) { OllamaConfig.thinkingEnabled = $0 })

            divider
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Download another model")
                HStack(spacing: 8) {
                    TextField("Ollama model tag", text: $customTag)
                        .textFieldStyle(.plain)
                        .font(NoirFonts.font(size: 12, weight: .regular))
                        .padding(9)
                        .background(NoirColors.glassInput, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(NoirColors.glassBorder, lineWidth: 1))
                        .onSubmit(downloadCustom)
                    Button("Download", action: downloadCustom)
                        .disabled(customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || server.isPulling || !serverReachable)
                }
                detail("Use a tag with both vision and tools. After downloading, select it from the installed list.")
            }
            HStack(spacing: 10) {
                Button("Show server log", action: revealLog)
                Spacer(minLength: 0)
                if let probe = server.lastProbe {
                    Text("Last check \(probe.formatted(date: .omitted, time: .shortened))")
                        .font(NoirFonts.font(size: 10, weight: .regular))
                        .foregroundStyle(NoirColors.textSecondary)
                }
            }
        }
    }

    // MARK: Reusable pane elements

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(compact ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoirColors.glassSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NoirColors.glassBorder, lineWidth: 0.75))
    }

    private var divider: some View { Rectangle().fill(NoirColors.glassDivider).frame(height: 1).padding(.vertical, 3) }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(NoirFonts.font(size: 10, weight: .medium, design: .monospaced))
            .tracking(1)
            .foregroundStyle(NoirColors.textSecondary)
    }

    private func detail(_ text: String, color: Color = NoirColors.textSecondary) -> some View {
        Text(text)
            .font(NoirFonts.font(size: 11, weight: .regular))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingRow<Control: View>(_ title: String, explanation: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(NoirFonts.font(size: 12, weight: .medium))
                Spacer(minLength: 12)
                control()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 160)
            }
            detail(explanation)
        }
    }

    private func toggleRow(_ title: String, explanation: String, value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: value)
                .font(NoirFonts.font(size: 12, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.small)
            detail(explanation)
        }
    }

    /// Only user interaction writes config. Synchronizing @State must not freeze
    /// an automatically adopted model/default or start redundant probes.
    private func binding<Value>(_ state: Binding<Value>, write: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { state.wrappedValue }, set: { state.wrappedValue = $0; write($0) })
    }

    private var contextOptions: [Int] { Array(Set([8192, 16384, 32768, numCtx])).sorted() }

    private var keepAliveOptions: [(String, String)] {
        var options = [("0", "Unload after use"), ("5m", "5 minutes"), ("10m", "10 minutes"), ("30m", "30 minutes"), (OllamaConfig.foreverKeepAlive, "Forever")]
        if !options.contains(where: { $0.0 == keepAlive }) { options.append((keepAlive, keepAlive)) }
        return options
    }

    private var compactFootnote: String {
        if OllamaConfig.modelWasAdopted {
            return "Using a compatible model already installed. You can choose another in Settings."
        }
        if !OllamaConfig.userChoseModel && OllamaServer.isLocalHost {
            return "Recommended for this Mac’s \(OllamaConfig.physicalMemoryGB) GB of memory."
        }
        return "Your selected model. Change it any time in Settings → Local Model."
    }

    private func blocker(_ choice: OllamaConfig.ModelChoice) -> String? {
        if serverReachable, !server.supports(choice), let version = server.serverVersion {
            return "Requires Ollama \(choice.minServerVersion)+. Your server has \(version)."
        }
        if OllamaServer.isLocalHost && OllamaConfig.physicalMemoryGB < choice.minMemoryGB {
            return "Requires at least \(choice.minMemoryGB) GB of memory. This Mac has \(OllamaConfig.physicalMemoryGB) GB."
        }
        return nil
    }

    private func isPulling(_ name: String) -> Bool {
        guard let progress = server.pull else { return false }
        return OllamaServer.sameTag(progress.model, name) || progress.model == "\(name) (via Hugging Face)"
    }

    private func sizeText(_ gb: Double) -> String { String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }

    private func progressText(_ progress: OllamaServer.PullProgress) -> String {
        guard progress.total > 0 else { return progress.status }
        return "\(progress.status) · \(ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))"
    }

    // MARK: Actions

    private func download(_ name: String) {
        guard serverReachable, !server.isPulling else { return }
        if let choice = OllamaConfig.recommendedModels.first(where: { OllamaServer.sameTag($0.name, name) }), blocker(choice) != nil { return }
        server.startPull(name)
    }

    private func downloadCustom() {
        let tag = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        download(tag)
    }

    private func startServer() {
        guard !isStarting, OllamaServer.isLocalHost else { return }
        isStarting = true
        Task {
            _ = await server.startServer()
            isStarting = false
            syncFromConfig()
        }
    }

    private func recheck() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await server.ensureRunning()
            isRefreshing = false
            syncFromConfig()
        }
    }

    private func commitHost() {
        guard !server.isPulling else { return }
        var candidate = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { candidate = OllamaConfig.defaultHost }
        if !candidate.contains("://") { candidate = "http://" + candidate }
        guard let url = URLComponents(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            hostError = "Enter a server address such as http://127.0.0.1:11434, without a path or credentials."
            return
        }
        hostError = nil
        OllamaConfig.host = candidate
        savedHost = OllamaConfig.host
        hostText = savedHost
        hostFocused = false
        recheck()
    }

    private func setCoordinates(_ raw: String) {
        if let value = OllamaConfig.CoordinateSpace(rawValue: raw) {
            OllamaConfig.coordinateSpace = value
        } else {
            UserDefaults.standard.removeObject(forKey: "ollama.coordinateSpace")
        }
    }

    private func revealLog() {
        let url = OllamaServer.logURL()
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()])
    }
}

private struct LocalModelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NoirFonts.font(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(NoirColors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? NoirColors.glassElevated : NoirColors.glassChrome, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(NoirColors.glassBorder, lineWidth: 0.75))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

#Preview("Full") {
    LocalModelSettingsView().frame(width: 640, height: 420)
        .background(Color.black)
}

#Preview("Compact") {
    LocalModelSettingsView(compact: true).padding(30)
        .frame(width: 540).background(Color.black)
}
