import Foundation
import AppKit

// MARK: - OllamaServer
// Lifecycle + health of the local Ollama server, published for the Settings pane
// and folded into OllamaConfig.isConfigured for every gate in the app.
//
//  • Probe: GET /api/version → GET /api/tags → POST /api/show (capabilities of
//    the chosen model). Runs at launch, every 30 s, and after any settings change.
//    A READY server is only demoted after two consecutive failed probes — one
//    slow answer while the GPU is generating must not flip every gate in the app.
//  • Start: when the server is down and `autoStartServer` is on, spawn
//    `ollama serve` detached (it outlives Holmes; the next launch just probes)
//    and poll until /api/version answers. The monitor respawns it if it dies
//    later (at most one attempt per `autoStartBackoff`), and the pane's
//    re-check button goes through the same path. If no `ollama` binary exists
//    anywhere, status is `.notInstalled` and the pane shows install instructions.
//  • Pull: streams POST /api/pull progress for the model picker.
//  • Warm: preloads the model with keep_alive so the first real request doesn't
//    pay the cold load.

@Observable
@MainActor
final class OllamaServer {
    static let shared = OllamaServer()

    enum Status: Equatable {
        case unknown
        case notInstalled
        case starting
        case unreachable(String)
        case modelMissing(model: String)
        case modelUnsuitable(model: String, reason: String)
        case ready(version: String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }

        var headline: String {
            switch self {
            case .unknown:                        return "Checking Ollama…"
            case .notInstalled:                   return "Ollama is not installed"
            case .starting:                       return "Starting Ollama…"
            case .unreachable:                    return "Ollama isn't running"
            case .modelMissing(let m):            return "Model \(m) isn't downloaded"
            case .modelUnsuitable(let m, _):      return "\(m) can't drive Holmes"
            case .ready(let v):                   return "Ollama \(v) · ready"
            }
        }

        var detail: String {
            switch self {
            case .unknown:                        return ""
            case .notInstalled:                   return "Install it from ollama.com (or `brew install ollama`), then come back here."
            case .starting:                       return "Waiting for the server to answer on \(OllamaConfig.host)."
            case .unreachable(let why):           return why
            case .modelMissing(let m):            return "Download it below (\(m)). Everything stays on this Mac."
            case .modelUnsuitable(_, let reason): return reason
            case .ready:                          return "\(OllamaConfig.model) · \(OllamaConfig.numCtx) token context"
            }
        }
    }

    struct InstalledModel: Identifiable, Equatable {
        let name: String
        let sizeBytes: Int64
        let family: String
        let parameterSize: String
        var id: String { name }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    }

    struct PullProgress: Equatable {
        let model: String
        var status: String
        var completed: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    private(set) var status: Status = .unknown
    private(set) var serverVersion: String?
    private(set) var installedModels: [InstalledModel] = []
    private(set) var pull: PullProgress?
    private(set) var pullError: String?
    private(set) var lastProbe: Date?
    /// Set when the server binary was found but is older than the models we
    /// recommend need; the pane shows an "update Ollama" hint.
    private(set) var versionWarning: String?

    private var monitor: Task<Void, Never>?
    private var serveProcess: Process?
    private var pullTask: Task<Void, Never>?
    /// Failed probes in a row. `.ready` survives the first one (hysteresis).
    private var consecutiveFailures = 0
    private var lastAutoStartAttempt: Date?
    /// Minimum spacing between automatic `ollama serve` spawns from the
    /// monitor, so a permanently broken install isn't relaunched every 30 s.
    private static let autoStartBackoff: TimeInterval = 300
    private let session: URLSession
    /// Used while an agent session is generating: the server is alive but may
    /// take a while to answer even /api/version on a swapping laptop.
    private let patientSession: URLSession
    private var probeSession: URLSession

    /// An injected session lets transport/state regressions run without a live
    /// Ollama installation. The app uses the default ephemeral sessions.
    init(session injectedSession: URLSession? = nil) {
        let normal = URLSessionConfiguration.ephemeral
        normal.timeoutIntervalForRequest = 8
        let patient = URLSessionConfiguration.ephemeral
        patient.timeoutIntervalForRequest = 30
        session = injectedSession ?? URLSession(configuration: normal)
        patientSession = injectedSession ?? URLSession(configuration: patient)
        probeSession = session
        OllamaConfig.onSettingsChanged = { [weak self] in
            // Settings controls call on the main thread: close the readiness
            // gate in that same turn, before an old probe can publish success.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.configurationDidChange() }
            } else {
                Task { @MainActor in self?.configurationDidChange() }
            }
        }
        // A model request that timed out or lost its connection re-probes the
        // server immediately, so the status and readiness gates catch up now.
        OllamaConfig.onModelTransportFailure = { [weak self] in
            Task { @MainActor in await self?.refreshAfterFailure() }
        }
    }

    // MARK: - Lifecycle

    /// Called once from app launch: probe, auto-start if needed, then keep probing.
    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            await self?.ensureRunning()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.monitorTick()
            }
        }
    }

    /// One monitor cycle: probe, and respawn a server that DIED (it was ready
    /// a moment ago) or has stayed down past the backoff window.
    private func monitorTick() async {
        let wasReady = status.isReady
        await refresh()
        guard case .unreachable = status, OllamaConfig.autoStartServer, Self.isLocalHost else { return }
        let backoffElapsed = lastAutoStartAttempt.map { Date().timeIntervalSince($0) >= Self.autoStartBackoff } ?? true
        if wasReady || backoffElapsed {
            lastAutoStartAttempt = Date()
            _ = await startServer()
        }
    }

    /// Probe; if unreachable and allowed, spawn the server and probe again.
    /// The pane's re-check goes through here too, so "click the refresh arrow"
    /// after installing Ollama really does start it.
    func ensureRunning() async {
        await refresh()
        if case .unreachable = status, OllamaConfig.autoStartServer, Self.isLocalHost {
            lastAutoStartAttempt = Date()
            _ = await startServer()
        }
    }

    /// Called by a caller whose request just failed with "unreachable" /
    /// "model missing": the probe is forced to believe a failure immediately
    /// (no hysteresis) so the status and every gate catch up now, not in 30 s.
    func refreshAfterFailure() async {
        consecutiveFailures = max(consecutiveFailures, 1)
        await refresh()
    }

    // MARK: - Probe

    private var probeInFlight = false
    private var configurationGeneration: UInt64 = 0
    private var reprobeRequested = false
    private var capabilitiesNeedReset = false
    private var configuredHost = OllamaConfig.host

    private func configurationDidChange() {
        configurationGeneration &+= 1
        reprobeRequested = true
        capabilitiesNeedReset = true
        consecutiveFailures = 0
        lastProbe = nil
        if configuredHost != OllamaConfig.host {
            configuredHost = OllamaConfig.host
            serverVersion = nil
            versionWarning = nil
            installedModels = []
            pullError = nil
        }
        set(.unknown, problem: "Checking Ollama…")
        Task { await refresh() }
    }

    func refresh() async {
        // Keep probes serial, but coalesce settings changes into another pass.
        // Returning from an overlapping refresh must never lose a changed host
        // or model until the next 30-second monitor tick.
        if probeInFlight { return }
        probeInFlight = true
        defer { probeInFlight = false }
        repeat {
            reprobeRequested = false
            let generation = configurationGeneration
            if capabilitiesNeedReset {
                capabilitiesNeedReset = false
                // Wait for the old probe to finish before clearing its cache.
                await OllamaClient.shared.forgetCapabilities()
                guard generation == configurationGeneration else { continue }
            }
            await probe(generation: generation)
        } while reprobeRequested
    }

    private func probe(generation: UInt64) async {
        defer {
            if generation == configurationGeneration { lastProbe = Date() }
        }
        probeSession = await OllamaClient.shared.isAgentSessionActive ? patientSession : session
        guard generation == configurationGeneration else { return }
        // 1. Server up?
        let fetchedVersion = await fetchVersion()
        guard generation == configurationGeneration else { return }
        guard let version = fetchedVersion else {
            consecutiveFailures += 1
            if case .starting = status {
                // keep "starting" while a spawn is in flight
                publish()
            } else if status.isReady, consecutiveFailures < 2 {
                // Hysteresis: one slow /api/version while the GPU is busy is not
                // a dead server. Keep every gate open until a second miss. This
                // applies even when no binary is visible to findBinary(): a
                // server that WAS answering is running from somewhere.
                print("[Holmes] OllamaServer: probe timed out once; keeping ready until a second miss")
            } else if Self.isLocalHost, Self.findBinary() == nil {
                installedModels = []
                set(.notInstalled, problem: "Ollama is not installed")
            } else {
                installedModels = []
                set(.unreachable("Nothing is answering on \(OllamaConfig.host)."),
                    problem: "Ollama isn't running")
            }
            return
        }
        consecutiveFailures = 0
        serverVersion = version
        versionWarning = OllamaConfig.version(version, isAtLeast: OllamaConfig.minimumServerVersion)
            ? nil
            : "Ollama \(version) is older than \(OllamaConfig.minimumServerVersion); update it for reliable tool calling."

        // 2. Models. A transport failure on /api/tags (nil) is NOT "no models":
        // apply the same hysteresis as /api/version instead of flipping every
        // gate to "model missing" because the GPU was busy for one probe.
        let fetchedModels = await fetchInstalledModels()
        guard generation == configurationGeneration else { return }
        guard let fetched = fetchedModels else {
            consecutiveFailures += 1
            if status.isReady, consecutiveFailures < 2 {
                print("[Holmes] OllamaServer: /api/tags failed once; keeping ready until a second miss")
                return
            }
            installedModels = []
            set(.unreachable("Ollama answered /api/version but not /api/tags."), problem: "Ollama isn't answering")
            return
        }
        installedModels = fetched
        if OllamaConfig.modelWasAdopted, !OllamaConfig.userChoseModel,
           installedModels.contains(where: { Self.sameTag($0.name, OllamaConfig.recommendedModel) }) {
            // The recommended model has arrived since a stand-in was adopted:
            // the adoption was never a choice, so the recommendation wins.
            OllamaConfig.clearAdoptedModel()
            await OllamaClient.shared.forgetCapabilities()
            guard generation == configurationGeneration else { return }
        }
        var wanted = OllamaConfig.model
        var isInstalled = installedModels.contains { Self.sameTag($0.name, wanted) }
        if isInstalled, pull == nil {
            // A stale "Download failed" line must not sit under a green status.
            pullError = nil
        }
        if !isInstalled, !OllamaConfig.userChoseModel {
            // Nobody picked a model yet and the recommended one isn't here: use
            // any installed model that can see AND act, instead of demanding a
            // multi-GB download the user may not need.
            let usable = await firstUsableInstalledModel(generation: generation)
            guard generation == configurationGeneration else { return }
            if let usable {
                OllamaConfig.adoptModelSilently(usable)
                wanted = usable
                isInstalled = true
            }
        }
        guard isInstalled else {
            set(.modelMissing(model: wanted), problem: "Model \(wanted) isn't downloaded")
            return
        }

        // 3. Capabilities of the chosen model
        do {
            let caps = try await OllamaClient.shared.capabilities(for: wanted)
            guard generation == configurationGeneration else { return }
            var missing: [String] = []
            if !caps.tools { missing.append("tool calling") }
            if !caps.vision { missing.append("vision") }
            if !missing.isEmpty {
                let reason = "\(wanted) has no \(missing.joined(separator: " or ")). Holmes needs both to see the screen and act — pick a recommended model."
                set(.modelUnsuitable(model: wanted, reason: reason), problem: "\(wanted) can't drive Holmes")
                return
            }
        } catch {
            guard generation == configurationGeneration else { return }
            consecutiveFailures += 1
            if status.isReady, consecutiveFailures < 2 {
                print("[Holmes] OllamaServer: /api/show failed once (\(error.localizedDescription)); keeping ready until a second miss")
                return
            }
            set(.unreachable(error.localizedDescription), problem: "Ollama isn't answering")
            return
        }

        consecutiveFailures = 0
        set(.ready(version: version), problem: nil)
    }

    private func set(_ new: Status, problem: String?) {
        status = new
        OllamaConfig.updateReadiness(ready: new.isReady, problem: problem)
    }

    private func publish() {
        OllamaConfig.updateReadiness(ready: status.isReady,
                                     problem: status.isReady ? nil : status.headline)
    }

    private func fetchVersion() async -> String? {
        guard let url = URL(string: "/api/version", relativeTo: OllamaConfig.baseURL) else { return nil }
        guard let (data, resp) = try? await probeSession.data(from: url.absoluteURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// nil = the request failed (timeout / non-200 / bad JSON); [] = the server
    /// answered and genuinely has no models.
    private func fetchInstalledModels() async -> [InstalledModel]? {
        guard let url = URL(string: "/api/tags", relativeTo: OllamaConfig.baseURL) else { return nil }
        guard let (data, resp) = try? await probeSession.data(from: url.absoluteURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let details = (m["details"] as? [String: Any]) ?? [:]
            return InstalledModel(name: name,
                                  sizeBytes: (m["size"] as? NSNumber)?.int64Value ?? 0,
                                  family: (details["family"] as? String) ?? "",
                                  parameterSize: (details["parameter_size"] as? String) ?? "")
        }
        .sorted { $0.name < $1.name }
    }

    /// First installed model advertising both `tools` and `vision`, preferring
    /// non-thinking ("instruct") tags, then smaller downloads.
    private func firstUsableInstalledModel(generation: UInt64) async -> String? {
        let ordered = installedModels.sorted {
            let a = $0.name.lowercased().contains("instruct"), b = $1.name.lowercased().contains("instruct")
            if a != b { return a }
            return $0.sizeBytes < $1.sizeBytes
        }
        for m in ordered.prefix(8) {
            let capabilities = try? await OllamaClient.shared.capabilities(for: m.name)
            guard generation == configurationGeneration else { return nil }
            if let caps = capabilities, caps.tools, caps.vision {
                return m.name
            }
        }
        return nil
    }

    /// "qwen3-vl:4b" == "qwen3-vl:4b"; "llama3.2" == "llama3.2:latest".
    nonisolated static func sameTag(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.contains(":") ? s : s + ":latest" }
        return norm(a) == norm(b)
    }

    nonisolated static var isLocalHost: Bool {
        let h = OllamaConfig.baseURL.host?.lowercased() ?? ""
        // 0.0.0.0 is deliberately NOT here: auto-starting a server bound to every
        // interface would expose an unauthenticated model endpoint to the LAN.
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    // MARK: - Start the server

    /// Well-known install locations, in preference order.
    nonisolated static func findBinary() -> String? {
        // The desktop app first: when it is installed it owns port 11434, and a
        // second `ollama serve` from a Homebrew binary would fight it for the port.
        let candidates = [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            NSHomeDirectory() + "/Applications/Ollama.app/Contents/Resources/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/opt/local/bin/ollama"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        // PATH lookup as a last resort (Holmes is launched from Finder with a
        // minimal PATH, so this rarely hits, but a custom install may be there).
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let p = String(dir) + "/ollama"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Spawns `ollama serve` detached and waits (up to ~20 s) for it to answer.
    private var serverStartInFlight = false

    @discardableResult
    func startServer() async -> Bool {
        guard Self.isLocalHost else { return false }
        // The launch monitor, the onboarding step and the pane's button can all
        // ask at once; a second `ollama serve` would just fail on the port.
        if serverStartInFlight { return false }
        serverStartInFlight = true
        defer { serverStartInFlight = false }
        let generation = configurationGeneration
        let version = await fetchVersion()
        guard generation == configurationGeneration else { return false }
        if version != nil { await refresh(); return true }
        guard let binary = Self.findBinary() else {
            set(.notInstalled, problem: "Ollama is not installed")
            return false
        }
        // The desktop Ollama.app, when present, owns port 11434 itself: launching
        // it is the right move (a second `ollama serve` would fail with
        // "address already in use").
        if binary.contains("Ollama.app") {
            let appURL = URL(fileURLWithPath: binary).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.open(appURL)
        } else {
            let log = Self.logURL()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            // nohup + & : the server must outlive Holmes (and Holmes must not
            // block on it). Output goes to a log the user can inspect.
            proc.arguments = ["-c", "nohup \"\(binary)\" serve >> \"\(log.path)\" 2>&1 &"]
            var env = ProcessInfo.processInfo.environment
            // Flash attention + 8-bit KV cache: same quality, roughly half the
            // context memory — what keeps a 16 GB Mac out of swap.
            env["OLLAMA_FLASH_ATTENTION"] = "1"
            env["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
            if let host = OllamaConfig.baseURL.host {
                // No explicit port means the URL's default (80/443), and the
                // server must listen where the probe will look.
                let port = OllamaConfig.baseURL.port ?? (OllamaConfig.baseURL.scheme == "https" ? 443 : 80)
                if !(host == "127.0.0.1" && port == 11434) {
                    env["OLLAMA_HOST"] = "\(host):\(port)"
                }
            }
            proc.environment = env
            do { try proc.run() } catch {
                set(.unreachable("Couldn't launch \(binary): \(error.localizedDescription)"),
                    problem: "Ollama couldn't start")
                return false
            }
            serveProcess = proc
        }
        set(.starting, problem: "Starting Ollama…")
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard generation == configurationGeneration, !Task.isCancelled else { return false }
            let version = await fetchVersion()
            guard generation == configurationGeneration else { return false }
            if version != nil {
                await refresh()
                return status.isReady || !isUnreachable(status)
            }
        }
        set(.unreachable("Started `ollama serve` but it never answered on \(OllamaConfig.host). See \(Self.logURL().path)."),
            problem: "Ollama didn't start")
        return false
    }

    private func isUnreachable(_ s: Status) -> Bool {
        if case .unreachable = s { return true }
        return false
    }

    nonisolated static func logURL() -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Holmes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ollama-serve.log")
    }

    // MARK: - Pull a model

    var isPulling: Bool { pull != nil }

    /// Starts a download in a task the pane can cancel (`cancelPull`). Ollama
    /// keeps the partial blobs, so a later Download resumes where it stopped.
    func startPull(_ name: String) {
        guard pull == nil else { return }
        // A cancelled download is still unwinding for a moment; queue behind it
        // instead of silently dropping the click.
        let previous = pullTask
        pullTask = Task { [weak self] in
            _ = await previous?.value
            await self?.pullModel(name)
            self?.pullTask = nil
        }
    }

    /// Stops the download in flight. No error is shown: the user asked.
    func cancelPull() {
        pullTask?.cancel()
        if pull != nil { pull?.status = "Cancelling…" }
    }

    /// Ollama's Go-flavoured registry errors, translated for the pane.
    nonisolated static func friendlyPullError(_ raw: String) -> String {
        let m = raw.lowercased()
        if m.contains("no such host") || m.contains("i/o timeout") || m.contains("dial tcp")
            || m.contains("connection refused") || m.contains("tls handshake") || m.contains("network is unreachable") {
            return "Couldn't reach ollama.com. Check your internet connection and try again."
        }
        if m.contains("manifest") && (m.contains("not found") || m.contains("500") || m.contains("unknown")) {
            return "That model tag doesn't exist on ollama.com. Check the spelling (e.g. qwen3-vl:4b-instruct)."
        }
        if m.contains("no space left") || m.contains("disk") {
            return "Not enough disk space to finish the download."
        }
        if m.contains("cancelled") || m.contains("canceled") {
            return "Download paused. Click Download again to resume."
        }
        return raw
    }

    /// Streams /api/pull, publishing progress. On success re-probes (which
    /// flips readiness if this was the chosen model).
    func pullModel(_ name: String) async {
        guard pull == nil else { return }
        pullError = nil
        let ok = await pullOnce(name)
        if !ok, let error = pullError, Self.isNetworkFailure(error),
           let mirror = OllamaConfig.mirror(for: name),
           let v = serverVersion, OllamaConfig.version(v, isAtLeast: OllamaConfig.mirrorMinimumServerVersion),
           !Task.isCancelled {
            // registry.ollama.ai down but the Mac is online: fetch the same
            // weights from Hugging Face, then register them under the expected
            // tag with the native renderer so tools + vision are advertised.
            pullError = nil
            if await pullOnce(mirror.hfTag, displayName: "\(name) (via Hugging Face)") {
                await createDerivedModel(name, from: mirror.hfTag, renderer: mirror.renderer)
            }
        }
        if pullError == nil {
            await OllamaClient.shared.forgetCapabilities()
            pull = nil
            await refresh()
        }
    }

    nonisolated static func isNetworkFailure(_ friendly: String) -> Bool {
        friendly.hasPrefix("Couldn't reach ollama.com")
    }

    /// POST /api/create: `name` = `from` + renderer/parser + sampling defaults.
    private func createDerivedModel(_ name: String, from source: String, renderer: String) async {
        pull = PullProgress(model: name, status: "Registering model…", completed: 1, total: 1)
        do {
            _ = try await OllamaClient.shared.request(
                path: "/api/create",
                body: ["model": name, "from": source, "renderer": renderer, "parser": renderer,
                       "parameters": ["temperature": 0.7, "top_k": 20, "top_p": 0.8], "stream": false],
                timeout: 600)
        } catch {
            pullError = "Downloaded from Hugging Face, but registering it as \(name) failed: \(error.localizedDescription)"
            // Clear the progress row on failure too, or every Download button
            // stays disabled ("Registering model…") until the app restarts.
            pull = nil
        }
    }

    /// One /api/pull attempt. Returns true on success; on failure `pullError`
    /// holds the friendly reason.
    private func pullOnce(_ name: String, displayName: String? = nil) async -> Bool {
        let shown = displayName ?? name
        pull = PullProgress(model: shown, status: "Starting download…", completed: 0, total: 0)
        defer { pull = nil }

        guard let url = URL(string: "/api/pull", relativeTo: OllamaConfig.baseURL)?.absoluteURL else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                var data = Data()
                for try await b in bytes { data.append(b) }
                let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                pullError = msg.map(Self.friendlyPullError) ?? "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
                return false
            }
            // Progress is per layer; track the largest layer's counters so the
            // bar reflects the bulk of the download, and show the status text.
            var layerTotals: [String: (Int64, Int64)] = [:]
            for try await line in bytes.lines {
                if Task.isCancelled { pullError = Self.friendlyPullError("cancelled"); return false }
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { pullError = Self.friendlyPullError(err); return false }
                var statusText = (obj["status"] as? String) ?? ""
                // "pulling 7a2b3c4d…" is a layer digest, not news for a person.
                if statusText.hasPrefix("pulling ") { statusText = "Downloading" }
                if let digest = obj["digest"] as? String {
                    let total = (obj["total"] as? NSNumber)?.int64Value ?? 0
                    let completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
                    layerTotals[digest] = (completed, total)
                }
                let sumCompleted = layerTotals.values.reduce(0) { $0 + $1.0 }
                let sumTotal = layerTotals.values.reduce(0) { $0 + $1.1 }
                pull = PullProgress(model: shown,
                                    status: statusText.isEmpty ? "Downloading…" : statusText,
                                    completed: sumCompleted, total: sumTotal)
            }
        } catch {
            pullError = Task.isCancelled || error is CancellationError
                ? Self.friendlyPullError("cancelled")
                : Self.friendlyPullError(error.localizedDescription)
            return false
        }
        return true
    }

    // MARK: - Warm-up

    /// Preload the chosen model so the first real request skips the cold load.
    func warmUp() async {
        guard status.isReady else { return }
        _ = try? await OllamaClient.shared.request(
            path: "/api/chat",
            body: ["model": OllamaConfig.model, "messages": [], "keep_alive": OllamaConfig.keepAlive,
                   // Same num_ctx as every real request — a different value would
                   // make the first real request reload the model anyway.
                   "options": ["num_ctx": OllamaConfig.numCtx]],
            timeout: 300)
    }

    /// Whether `choice` can run on the detected server version.
    func supports(_ choice: OllamaConfig.ModelChoice) -> Bool {
        guard let v = serverVersion else { return true }
        return OllamaConfig.version(v, isAtLeast: choice.minServerVersion)
    }

    func isInstalled(_ name: String) -> Bool {
        installedModels.contains { Self.sameTag($0.name, name) }
    }
}
