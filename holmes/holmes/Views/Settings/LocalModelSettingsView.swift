import SwiftUI
import AppKit

// MARK: - LocalModelSettingsView
// The "Local Model" pane: everything about the Ollama server and the model that
// drives Holmes. Two shapes share one source of truth (OllamaServer.shared, an
// @Observable @MainActor singleton), so the pane updates live while a download
// runs or the server comes up:
//   • full (Settings ▸ Local Model): status row, recommended models, models
//     installed on this Mac, and a collapsed Advanced section.
//   • compact (onboarding "Your local model" step): the status row plus the one
//     model Holmes will use, with its download button and progress.
//
// Nothing here talks to the network directly — every action goes through
// OllamaServer (startServer / pullModel / refresh) and every setting through
// OllamaConfig, whose setters re-probe the server.

@MainActor
struct LocalModelSettingsView: View {
    let compact: Bool

    // Mirrors of OllamaConfig so the controls re-render immediately; every
    // change writes straight through to OllamaConfig (UserDefaults).
    @State private var selectedModel: String = OllamaConfig.model
    @State private var hostText: String = OllamaConfig.host
    @State private var numCtx: Int = OllamaConfig.numCtx
    @State private var keepAlive: String = OllamaConfig.keepAlive
    @State private var thinking: Bool = OllamaConfig.thinkingEnabled
    @State private var autoStart: Bool = OllamaConfig.autoStartServer
    @State private var customTag: String = ""
    @State private var showAdvanced = false
    @State private var isStarting = false
    @State private var isRefreshing = false
    @FocusState private var hostFocused: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    private var server: OllamaServer { OllamaServer.shared }

    static let downloadURL = URL(string: "https://ollama.com/download")!

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .onAppear { syncFromConfig() }
        // A probe finished (or a setting changed elsewhere): re-read the config
        // mirrors so "IN USE" and the advanced controls never go stale.
        .onChange(of: server.lastProbe) { _, _ in syncFromConfig() }
    }

    private func syncFromConfig() {
        selectedModel = OllamaConfig.model
        if !hostFocused { hostText = OllamaConfig.host }
        numCtx = OllamaConfig.numCtx
        keepAlive = OllamaConfig.keepAlive
        thinking = OllamaConfig.thinkingEnabled
        autoStart = OllamaConfig.autoStartServer
    }

    // MARK: - Derived state

    /// The server answered a probe (so downloads and /api/show work), even if
    /// the chosen model is missing or unsuitable.
    private var serverReachable: Bool {
        switch server.status {
        case .ready, .modelMissing, .modelUnsuitable: return true
        case .unknown, .notInstalled, .starting, .unreachable: return false
        }
    }

    private var isNotInstalled: Bool {
        if case .notInstalled = server.status { return true }
        return false
    }

    private var isUnreachable: Bool {
        if case .unreachable = server.status { return true }
        return false
    }

    private var statusIcon: String {
        switch server.status {
        case .unknown, .starting:              return "hourglass.circle"
        case .notInstalled:                    return "arrow.down.circle"
        case .unreachable:                     return "xmark.circle.fill"
        case .modelMissing:                    return "square.and.arrow.down"
        case .modelUnsuitable:                 return "exclamationmark.triangle.fill"
        case .ready:                           return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .unknown, .starting:              return .secondary
        case .notInstalled, .modelMissing:     return .orange
        case .unreachable, .modelUnsuitable:   return .red
        case .ready:                           return .green
        }
    }

    private func isCurrent(_ name: String) -> Bool {
        OllamaServer.sameTag(name, selectedModel)
    }

    private func isPulling(_ name: String) -> Bool {
        guard let p = server.pull else { return false }
        return OllamaServer.sameTag(p.model, name)
    }

    /// Why a recommended model can't be downloaded on this machine, if anything.
    private func blocker(for choice: OllamaConfig.ModelChoice) -> String? {
        if !server.supports(choice), let v = server.serverVersion {
            return "Needs Ollama \(choice.minServerVersion) or newer (this Mac has \(v))."
        }
        let mem = OllamaConfig.physicalMemoryGB
        if mem < choice.minMemoryGB {
            return "Needs \(choice.minMemoryGB) GB of memory; this Mac has \(mem) GB."
        }
        return nil
    }

    private func sizeText(_ gb: Double) -> String {
        gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    private func percentText(_ p: OllamaServer.PullProgress) -> String {
        p.total > 0 ? "\(Int((p.fraction * 100).rounded()))%" : "…"
    }

    private func bytesText(_ p: OllamaServer.PullProgress) -> String {
        guard p.total > 0 else { return p.status }
        let done = ByteCountFormatter.string(fromByteCount: p.completed, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: p.total, countStyle: .file)
        return "\(p.status) · \(done) of \(total)"
    }

    // MARK: - Actions

    private func use(_ name: String) {
        selectedModel = name
        OllamaConfig.model = name   // setter re-probes via OllamaServer
    }

    private func download(_ name: String) {
        server.startPull(name)
    }

    private func cancelDownload() {
        server.cancelPull()
    }

    private func startServer() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await server.startServer()
            isStarting = false
        }
    }

    /// Re-check AND start the server if it is down and auto-start is on — the
    /// install instructions promise exactly that for the refresh arrow.
    private func recheck() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await server.ensureRunning()
            isRefreshing = false
        }
    }

    private func commitHost() {
        OllamaConfig.host = hostText
        hostText = OllamaConfig.host
    }

    private func openDownloadPage() {
        NSWorkspace.shared.open(Self.downloadURL)
    }

    private func revealLog() {
        let url = OllamaServer.logURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    // MARK: - Full pane (Settings ▸ Local Model)

    private var fullBody: some View {
        Form {
            statusRow

            if isNotInstalled {
                installInstructions
            }

            if let p = server.pull, !pullShownInList(p.model) {
                pullProgress(p, label: p.model)
            }

            Divider()

            Text("Recommended models")
                .font(.system(size: 12, weight: .semibold))
            Text("Every model here can see the screen and call tools. The size is the download; pick by the memory in this Mac (\(OllamaConfig.physicalMemoryGB) GB). Downloads come from ollama.com once and then run entirely on this machine.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(OllamaConfig.recommendedModels) { choice in
                recommendedRow(choice)
            }

            Divider()

            Text("Installed on this Mac")
                .font(.system(size: 12, weight: .semibold))
            if server.installedModels.isEmpty {
                Text(serverReachable
                     ? "No models downloaded yet."
                     : "Ollama has to be running before Holmes can list models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Any Ollama model can be selected. One without vision or tool calling is flagged after you pick it — Holmes needs both to see the screen and act.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(server.installedModels) { model in
                    installedRow(model)
                }
            }

            Divider()

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedSection
                    .padding(.top, 6)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .scrollContentBackground(.hidden)
        .padding()
    }

    /// True when the download in progress is for a model already shown in one
    /// of the lists (each row draws its own bar), so the status area doesn't
    /// draw a second one.
    private func pullShownInList(_ name: String) -> Bool {
        OllamaConfig.recommendedModels.contains { OllamaServer.sameTag($0.name, name) }
            || server.installedModels.contains { OllamaServer.sameTag($0.name, name) }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.status.headline)
                    .font(.system(size: 12, weight: .semibold))
                if !server.status.detail.isEmpty {
                    Text(server.status.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let warning = server.versionWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = server.pullError {
                    Text("Download failed: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            statusActions
        }
        .padding(.vertical, 2)
    }

    /// The one button that fixes the current status, plus a re-check control.
    @ViewBuilder private var statusActions: some View {
        HStack(spacing: 6) {
            switch server.status {
            case .unknown, .starting:
                ProgressView()
                    .controlSize(.small)
            case .notInstalled:
                Button("Get Ollama") { openDownloadPage() }
                    .controlSize(.small)
            case .unreachable:
                Button(isStarting ? "Starting…" : "Start Ollama") { startServer() }
                    .controlSize(.small)
                    .disabled(isStarting)
            case .modelMissing(let model):
                if !server.isPulling {
                    Button("Download") { download(model) }
                        .controlSize(.small)
                }
            case .modelUnsuitable, .ready:
                EmptyView()
            }

            Button {
                recheck()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isRefreshing)
            .help("Re-check the Ollama server and its models")
        }
    }

    private var installInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ollama is the free, open-source server that runs the model. Two minutes to set up:")
                .font(.caption)
            Text("1. Download it from ollama.com/download and open it once — or run `brew install ollama` in Terminal.\n2. Come back here and click the refresh arrow. Holmes starts the server itself from then on.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func pullProgress(_ p: OllamaServer.PullProgress, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                HStack(spacing: 8) {
                    Text("Downloading \(label)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(percentText(p))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    cancelButton
                }
            }
            ProgressView(value: p.total > 0 ? p.fraction : nil)
                .controlSize(.small)
            Text(bytesText(p))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// Stops the download in flight; Ollama keeps the partial blobs, so the
    /// next Download resumes.
    private var cancelButton: some View {
        Button("Cancel") { cancelDownload() }
            .controlSize(.small)
            .help("Stop this download. You can resume it later.")
    }

    private func badge(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func recommendedRow(_ choice: OllamaConfig.ModelChoice) -> some View {
        let installed = server.isInstalled(choice.name)
        let current = isCurrent(choice.name)
        let blocked = blocker(for: choice)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(sizeText(choice.sizeGB))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if current {
                            badge(installed ? "IN USE" : "SELECTED", tint: installed ? .green : .orange)
                        } else if installed {
                            badge("INSTALLED")
                        }
                    }
                    Text(choice.note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let blocked {
                        Text(blocked)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                modelAction(name: choice.name, installed: installed, current: current, blocked: blocked != nil)
            }
            if let p = server.pull, isPulling(choice.name) {
                pullProgress(p)
            }
        }
        .padding(.vertical, 4)
    }

    private func installedRow(_ model: OllamaServer.InstalledModel) -> some View {
        let current = isCurrent(model.name)
        let meta = [model.sizeText, model.parameterSize, model.family]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if current { badge("IN USE", tint: .green) }
                }
                Text(meta)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(current ? "In use" : "Use") { use(model.name) }
                .controlSize(.small)
                .disabled(current)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func modelAction(name: String, installed: Bool, current: Bool, blocked: Bool) -> some View {
        if let p = server.pull, isPulling(name) {
            HStack(spacing: 6) {
                Text(percentText(p))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                cancelButton
            }
        } else if installed {
            Button(current ? "In use" : "Use") { use(name) }
                .controlSize(.small)
                .disabled(current)
        } else {
            Button("Download") { download(name) }
                .controlSize(.small)
                .disabled(blocked || server.isPulling || !serverReachable)
                .help(blocked ? "This model can't run on this Mac"
                      : !serverReachable ? "Start Ollama first"
                      : server.isPulling ? "One download at a time"
                      : "Download \(name) from ollama.com")
        }
    }

    // MARK: Advanced

    private var contextOptions: [Int] {
        var options = [8192, 16384, 32768]
        if !options.contains(numCtx) { options.append(numCtx); options.sort() }
        return options
    }

    private var keepAliveOptions: [(String, String)] {
        // "Forever" must be a duration Ollama can parse ("-1m"); a bare "-1"
        // is rejected with HTTP 400 on every request. See OllamaConfig.validKeepAlive.
        var options = [("5m", "5 minutes"), ("30m", "30 minutes"), (OllamaConfig.foreverKeepAlive, "Forever")]
        if !options.contains(where: { $0.0 == keepAlive }) {
            options.append((keepAlive, "Custom (\(keepAlive))"))
        }
        return options
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Server") {
                TextField(OllamaConfig.defaultHost, text: $hostText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($hostFocused)
                    .frame(maxWidth: 240)
            }
            .onChange(of: hostFocused) { wasFocused, focused in
                if wasFocused && !focused { commitHost() }
            }
            Text("Where Ollama listens. Leave the default unless you run it on another port or another machine on your network.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Context window") {
                Picker("", selection: $numCtx) {
                    ForEach(contextOptions, id: \.self) { n in
                        Text(verbatim: "\(n) tokens").tag(n)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: numCtx) { _, value in OllamaConfig.numCtx = value }
            }
            Text("More context keeps more screenshots and history per step but uses more memory. Changing it reloads the model.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Keep model loaded") {
                Picker("", selection: $keepAlive) {
                    ForEach(keepAliveOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: keepAlive) { _, value in OllamaConfig.keepAlive = value }
            }
            Text("How long the model stays in memory after a request. Reloading costs 20–40 s, so keep it long unless memory is tight.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Let the model work in the background", isOn: Binding(

                get: { OllamaConfig.backgroundModelEnabled },

                set: { OllamaConfig.backgroundModelEnabled = $0 }

            ))

            Text("Off by default. When on, Holmes asks the local model to enrich the screen context every few seconds — a constant GPU load that makes a laptop feel sluggish. Context detection and the golden playbooks work without it.")

                .font(.caption).foregroundColor(.secondary)

            Toggle("Glow on automatic actions", isOn: Binding(

                get: { ScreenGlowController.contextGlowEnabled },

                set: { ScreenGlowController.contextGlowEnabled = $0 }

            ))

            Text("Off by default: the edge glow plays only for things you ask Holmes to do. Turn on to also glow when a playbook fires from what's on screen.")

                .font(.caption).foregroundColor(.secondary)


            Toggle("Let the model think before acting", isOn: $thinking)
                .onChange(of: thinking) { _, value in OllamaConfig.thinkingEnabled = value }
            Text("Off by default: a thinking model spends minutes per step on a laptop. Note that some tags think regardless of this switch (e.g. qwen3-vl:4b, unlike qwen3-vl:4b-instruct) — pick an instruct tag for speed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Click coordinates") {
                Picker("", selection: Binding(
                    get: { OllamaConfig.coordinateSpace },
                    // Only a user pick writes the key — mirroring the getter's
                    // model-derived default through @State used to freeze it.
                    set: { OllamaConfig.coordinateSpace = $0 }
                )) {
                    Text("Screen pixels").tag(OllamaConfig.CoordinateSpace.pixels)
                    Text("0–1000 grid").tag(OllamaConfig.CoordinateSpace.normalized1000)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            Text("How the model reports where to click. Qwen3-VL models answer on a 0–1000 grid no matter what they are told, so they default to the grid; other families default to pixels. Switch if clicks land in the wrong place in a consistent, scaled way.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Start Ollama automatically", isOn: $autoStart)
                .onChange(of: autoStart) { _, value in OllamaConfig.autoStartServer = value }
            Text("Holmes launches `ollama serve` when it isn't running. The server keeps running after Holmes quits.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Other model") {
                HStack(spacing: 6) {
                    TextField("tag, e.g. llama3.2-vision", text: $customTag)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: 200)
                        .onSubmit { downloadCustom() }
                    Button("Download") { downloadCustom() }
                        .controlSize(.small)
                        .disabled(customTag.trimmingCharacters(in: .whitespaces).isEmpty
                                  || server.isPulling || !serverReachable)
                }
            }
            if let p = server.pull, !pullShownInList(p.model) {
                pullProgress(p, label: p.model)
            }

            HStack(spacing: 8) {
                Button(isRefreshing ? "Checking…" : "Re-check") { recheck() }
                    .controlSize(.small)
                    .disabled(isRefreshing)
                if let probe = server.lastProbe {
                    Text("Last checked \(probe.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            LabeledContent("Server log") {
                HStack(spacing: 6) {
                    Text(OllamaServer.logURL().path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal") { revealLog() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func downloadCustom() {
        let tag = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !server.isPulling, serverReachable else { return }
        download(tag)
    }

    // MARK: - Compact (onboarding)

    /// The model this first-run user will end up with: the one selected in
    /// config, which defaults to the recommendation for this Mac's memory.
    private var compactChoice: OllamaConfig.ModelChoice? {
        OllamaConfig.recommendedModels.first { OllamaServer.sameTag($0.name, selectedModel) }
    }

    /// Why THIS model: the memory-based pick, a stand-in that was already
    /// installed (and what the faster recommendation is), or the user's own
    /// choice. The card must never claim a substitution was picked on purpose.
    private var compactFootnote: String {
        let recommended = OllamaConfig.recommendedModel
        if OllamaConfig.modelWasAdopted, !OllamaServer.sameTag(selectedModel, recommended) {
            return "Using \(selectedModel) because it is already installed. The recommended \(recommended) is faster for this Mac; download it in Settings ▸ Local Model and Holmes will switch to it."
        }
        if compactChoice != nil {
            return "Picked for this Mac's \(OllamaConfig.physicalMemoryGB) GB of memory. Other sizes are in Settings ▸ Local Model."
        }
        return "Chosen in Settings ▸ Local Model, where the recommended sizes for this Mac's \(OllamaConfig.physicalMemoryGB) GB of memory are listed too."
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            compactStatusCard
            compactModelCard
        }
        .frame(maxWidth: 450)
    }

    private var compactStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(server.status.isReady ? NoirColors.glassElevated : NoirColors.glassSurface)
                        .frame(width: 44, height: 44)
                        .glassBorder(cornerRadius: 6)
                    Image(systemName: statusIcon)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(server.status.isReady ? NoirColors.success : NoirColors.textPrimary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(server.status.headline)
                        .font(NoirFonts.title())
                        .foregroundColor(NoirColors.textPrimary)
                    if !server.status.detail.isEmpty {
                        Text(server.status.detail)
                            .font(NoirFonts.caption())
                            .foregroundColor(NoirColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning = server.versionWarning {
                        Text(warning)
                            .font(NoirFonts.caption())
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = server.pullError {
                        Text("Download failed: \(error)")
                            .font(NoirFonts.caption())
                            .foregroundColor(NoirColors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                compactStatusAction
            }

            if isNotInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ollama is the free, open-source server that runs the model on this Mac.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                    Text("Download it from ollama.com/download and open it once (or `brew install ollama`), then click the refresh arrow.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(NoirColors.glassSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .glassBorder(cornerRadius: 8)
    }

    @ViewBuilder private var compactStatusAction: some View {
        HStack(spacing: 6) {
            switch server.status {
            case .unknown, .starting:
                ProgressView()
                    .controlSize(.small)
            case .notInstalled:
                Button("Get Ollama") { openDownloadPage() }
                    .controlSize(.small)
            case .unreachable:
                Button(isStarting ? "Starting…" : "Start Ollama") { startServer() }
                    .controlSize(.small)
                    .disabled(isStarting)
            case .modelMissing, .modelUnsuitable, .ready:
                EmptyView()
            }
            Button {
                recheck()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isRefreshing)
            .help("Re-check")
        }
    }

    private var compactModelCard: some View {
        let name = selectedModel
        let installed = server.isInstalled(name)
        let blocked = compactChoice.flatMap { blocker(for: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(NoirColors.textPrimary)
                        if let choice = compactChoice {
                            Text(sizeText(choice.sizeGB))
                                .font(NoirFonts.caption())
                                .foregroundColor(NoirColors.textSecondary)
                        }
                        if installed {
                            badge("INSTALLED", tint: NoirColors.success)
                        }
                    }
                    Text(compactChoice?.note ?? "The model Holmes will use. Change it any time in Settings ▸ Local Model.")
                        .font(NoirFonts.caption())
                        .foregroundColor(NoirColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let blocked {
                        Text(blocked)
                            .font(NoirFonts.caption())
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let p = server.pull, isPulling(name) {
                    HStack(spacing: 6) {
                        Text(percentText(p))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(NoirColors.textSecondary)
                        cancelButton
                    }
                } else if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(NoirColors.success)
                } else {
                    Button("Download") { download(name) }
                        .controlSize(.small)
                        .disabled(blocked != nil || server.isPulling || !serverReachable)
                        .help(!serverReachable ? "Start Ollama first" : "Download \(name) from ollama.com")
                }
            }
            if let p = server.pull, isPulling(name) {
                pullProgress(p)
                    .tint(NoirColors.accent)
            }
            Text(compactFootnote)
                .font(NoirFonts.caption())
                .foregroundColor(NoirColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(NoirColors.glassSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .glassBorder(cornerRadius: 8)
    }
}

#Preview("Full") {
    LocalModelSettingsView()
        .frame(width: 640, height: 520)
}

#Preview("Compact") {
    ZStack {
        NoirColors.skyBlue.ignoresSafeArea()
        LocalModelSettingsView(compact: true)
            .padding(40)
    }
    .frame(width: 600, height: 400)
}
