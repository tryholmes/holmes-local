import Foundation

// MARK: - OllamaConfig
// Configuration for the ONE model Holmes Local uses: an open-weights model served
// by Ollama on this Mac (http://127.0.0.1:11434 by default).
//   • Perception is model-free — LiveContext computes the headline deterministically
//     from DOM/Accessibility data, so nothing Holmes claims to see comes from a model.
//   • The local model runs the multi-step tool-calling loop that takes actions, and
//     enriches an already-correct context with the goal/intent behind the headline.
//
// There is no API key and nothing leaves the machine. Instead of "is a key set?",
// readiness means "is the Ollama server reachable AND is the chosen model pulled?".
// OllamaServer probes that and publishes it here; every caller that used to gate on
// an API key gates on `isConfigured` exactly as before.
//
// Settings live in UserDefaults (they are not secrets).

enum OllamaConfig {
    private enum Key {
        static let host       = "ollama.host"
        static let model      = "ollama.model"
        static let numCtx     = "ollama.numCtx"
        static let keepAlive  = "ollama.keepAlive"
        static let thinking   = "ollama.thinkingEnabled"
        static let autoStart  = "ollama.autoStartServer"
        static let userChose  = "ollama.userChoseModel"
        static let adopted    = "ollama.modelAdopted"
    }

    // MARK: Server

    static let defaultHost = "http://127.0.0.1:11434"

    /// Base URL of the Ollama server (no trailing slash).
    static var host: String {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.host)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? defaultHost : Self.normalized(raw)
        }
        set {
            let trimmed = Self.normalized(newValue)
            if trimmed.isEmpty || trimmed == defaultHost {
                UserDefaults.standard.removeObject(forKey: Key.host)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Key.host)
            }
            onSettingsChanged?()
        }
    }

    private static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty, !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    static var baseURL: URL { URL(string: host) ?? URL(string: defaultHost)! }

    /// Whether Holmes may spawn `ollama serve` itself when the server is down.
    static var autoStartServer: Bool {
        get { UserDefaults.standard.object(forKey: Key.autoStart) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoStart) }
    }

    // MARK: Model

    /// The model tag for every request. Must support `tools` AND `vision` — Holmes
    /// drives the screen from screenshots and acts through tool calls in the same
    /// loop, and Ollama has no way to split those across two models without
    /// reloading (a 20 s+ swap on every alternation).
    static var model: String {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.model)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? recommendedModel : raw
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaults = UserDefaults.standard
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.model)
                defaults.removeObject(forKey: Key.userChose)
            } else {
                defaults.set(trimmed, forKey: Key.model)
                defaults.set(true, forKey: Key.userChose)
            }
            defaults.removeObject(forKey: Key.adopted)
            onSettingsChanged?()
        }
    }

    /// True once the user (or onboarding) explicitly picked a model. Until then
    /// OllamaServer may silently adopt any installed model that can do the job,
    /// and reconsiders that adoption on every probe. A model key written before
    /// the flag existed counts as a choice unless it was recorded as adopted.
    static var userChoseModel: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: Key.userChose) { return true }
        return d.string(forKey: Key.model) != nil && !modelWasAdopted
    }

    /// True while the model in use was picked by OllamaServer because the
    /// recommended one wasn't installed — not by the user.
    static var modelWasAdopted: Bool { UserDefaults.standard.bool(forKey: Key.adopted) }

    /// Set the model WITHOUT firing onSettingsChanged (used by OllamaServer when
    /// it adopts an already-installed model during a probe). Recorded as an
    /// adoption, not a choice, so a later install of the recommended tag wins.
    static func adoptModelSilently(_ name: String) {
        UserDefaults.standard.set(name, forKey: Key.model)
        UserDefaults.standard.set(true, forKey: Key.adopted)
    }

    /// Undo a silent adoption (the recommended model showed up): back to the
    /// memory-based default, still without firing onSettingsChanged.
    static func clearAdoptedModel() {
        UserDefaults.standard.removeObject(forKey: Key.model)
        UserDefaults.standard.removeObject(forKey: Key.adopted)
    }

    /// A model Holmes knows how to recommend, by machine tier.
    struct ModelChoice: Identifiable, Equatable {
        let name: String
        let sizeGB: Double
        /// Minimum unified memory this is comfortable on.
        let minMemoryGB: Int
        /// Minimum Ollama server version that can run it.
        let minServerVersion: String
        let note: String
        var id: String { name }
    }

    /// Curated list: every entry supports tools + vision. Non-thinking ("instruct")
    /// variants are preferred — on a laptop a thinking model spends minutes per
    /// step deliberating, which is unusable for a screenshot → act loop.
    static let recommendedModels: [ModelChoice] = [
        ModelChoice(name: "qwen3-vl:2b-instruct", sizeGB: 1.9, minMemoryGB: 8, minServerVersion: "0.12.7",
                    note: "Smallest. For 8 GB Macs. Sees the screen and calls tools; expect misclicks on dense UIs."),
        ModelChoice(name: "qwen3-vl:4b-instruct", sizeGB: 3.3, minMemoryGB: 16, minServerVersion: "0.12.7",
                    note: "Default for 16 GB Macs. Trained for GUI agents; good balance of speed and accuracy."),
        ModelChoice(name: "qwen3-vl:8b-instruct", sizeGB: 6.1, minMemoryGB: 16, minServerVersion: "0.12.7",
                    note: "More accurate; tight on 16 GB alongside a browser, comfortable on 24 GB+."),
        ModelChoice(name: "qwen3.5:9b", sizeGB: 6.6, minMemoryGB: 24, minServerVersion: "0.17.3",
                    note: "Newer unified vision model. Thinks by default; Holmes turns thinking off per request."),
        ModelChoice(name: "qwen3-vl:30b-a3b-instruct", sizeGB: 20, minMemoryGB: 32, minServerVersion: "0.12.7",
                    note: "Mixture-of-experts: fast per step for its size. Needs 32 GB+."),
        ModelChoice(name: "gemma4:12b", sizeGB: 7.6, minMemoryGB: 16, minServerVersion: "0.20.0",
                    note: "Google's current family. Requires Ollama 0.20 or newer.")
    ]

    /// Hugging Face mirrors for the recommended tags, used when registry.ollama.ai
    /// is unreachable (it was, for a whole evening, while huggingface.co was fine).
    /// The GGUF is the same weights; Ollama then needs the native renderer/parser
    /// to advertise tool calling, which `OllamaServer` sets via /api/create.
    struct Mirror { let hfTag: String; let renderer: String }
    static func mirror(for tag: String) -> Mirror? {
        switch tag {
        case "qwen3-vl:2b-instruct": return Mirror(hfTag: "hf.co/unsloth/Qwen3-VL-2B-Instruct-GGUF:Q4_K_M", renderer: "qwen3-vl-instruct")
        case "qwen3-vl:4b-instruct": return Mirror(hfTag: "hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M", renderer: "qwen3-vl-instruct")
        case "qwen3-vl:8b-instruct": return Mirror(hfTag: "hf.co/unsloth/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M", renderer: "qwen3-vl-instruct")
        default: return nil
        }
    }
    /// Imports from Hugging Face only run on Ollama's native engine from about
    /// this version; older servers crash in the legacy CLIP loader.
    static let mirrorMinimumServerVersion = "0.30.0"

    static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
    }

    /// Picked by unified memory so the default never swaps the machine to death.
    static var recommendedModel: String {
        switch physicalMemoryGB {
        case ..<12:  return "qwen3-vl:2b-instruct"
        case ..<32:  return "qwen3-vl:4b-instruct"
        case ..<64:  return "qwen3-vl:8b-instruct"
        default:     return "qwen3-vl:30b-a3b-instruct"
        }
    }

    // MARK: Generation knobs

    /// Context window for EVERY request. Ollama's default on a <24 GiB GPU is
    /// 4096, which the first turn of a computer session already overflows (system
    /// prompt + tool schemas + one screenshot). Changing this between requests
    /// reloads the model, so it is one value for the whole app, never per call.
    static var numCtx: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Key.numCtx)
            return v >= 2048 ? v : recommendedNumCtx
        }
        set {
            UserDefaults.standard.set(max(2048, newValue), forKey: Key.numCtx)
            onSettingsChanged?()
        }
    }

    static var recommendedNumCtx: Int {
        switch physicalMemoryGB {
        case ..<12: return 8192
        case ..<32: return 16384
        default:    return 32768
        }
    }

    /// How long the server keeps the model resident after a request. Holmes is an
    /// always-on agent that fires every few seconds, so a short keep-alive would
    /// pay a cold load (20-40 s) constantly. Users on tight RAM can shorten it.
    static var keepAlive: String {
        get { Self.validKeepAlive(UserDefaults.standard.string(forKey: Key.keepAlive)) }
        set { UserDefaults.standard.set(Self.validKeepAlive(newValue), forKey: Key.keepAlive); onSettingsChanged?() }
    }

    static let defaultKeepAlive = "10m"
    /// "Keep forever". Ollama decodes a STRING keep_alive with Go's
    /// time.ParseDuration, which rejects a bare "-1" ("missing unit"); any
    /// negative duration means forever, so this is the spelling that works.
    static let foreverKeepAlive = "-1m"

    /// Maps whatever is stored to something Ollama accepts: a Go duration
    /// ("5m", "1h30m", "0"), a bare negative number → forever, anything else →
    /// the default. A bad value here 400s EVERY request while the status stays
    /// green, so it is healed on read rather than trusted.
    static func validKeepAlive(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultKeepAlive }
        if s == "0" { return s }
        if let n = Double(s) { return n < 0 ? foreverKeepAlive : defaultKeepAlive }
        let goDuration = "^-?([0-9]+(\\.[0-9]*)?(ns|us|µs|ms|s|m|h))+$"
        return s.range(of: goDuration, options: .regularExpression) != nil ? s : defaultKeepAlive
    }

    /// Let a thinking-capable model think before answering. Off by default: on a
    /// laptop it multiplies per-step latency by 5-10× for the agent loop.
    static var thinkingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.thinking) }
        set { UserDefaults.standard.set(newValue, forKey: Key.thinking); onSettingsChanged?() }
    }

    /// Output cap for one agentic turn (a tool call plus a sentence or two).
    static let agentNumPredict = 2048
    /// Smallest output cap a one-shot completion will be given, regardless of the
    /// caller's `maxTokens` — local models pad JSON and small caps truncate it.
    static let quickNumPredictFloor = 512

    /// Sampling. The hosted model never took a temperature; Ollama defaults to 0.8, which
    /// is far too loose for tool arguments and JSON. Near-greedy for actions,
    /// greedy for schema output.
    static let agentTemperature: Double = 0.1
    static let jsonTemperature: Double = 0.0

    /// Image-bearing user messages kept in the conversation (a turn can carry a
    /// screenshot AND a zoom). Each frame costs on the order of a thousand
    /// tokens of context; older ones are replaced with a placeholder. Three lets
    /// the model compare before/after around one zoom.
    static let maxImagesInHistory = 3

    /// Safety bound on the agentic loop (model → tool → result → model …).
    static let maxIterations = 10

    /// Per-request URLSession timeout. Ollama has no server-side timeout; a cold
    /// load plus a long screenshot prompt on a laptop can take a couple of minutes
    /// before the first byte arrives.
    static let requestTimeout: TimeInterval = 600

    /// Oldest server that returns tool-call ids (needed to pair results).
    static let minimumServerVersion = "0.12.10"


    // MARK: Background model work

    /// Let the local model run in the background on its own (context
    /// enrichment every few seconds, ambiguous-screen confirmation). Off by
    /// default: on a laptop that is a permanent GPU load and the thing that
    /// makes the whole Mac feel sluggish. Deterministic context detection —
    /// the headline, the matchers, the golden playbooks — never needed a model.
    static var backgroundModelEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ollama.backgroundModelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.backgroundModelEnabled") }
    }

    // MARK: Coordinate space

    /// How the model reports screen coordinates. Holmes declares an explicit
    /// pixel space (the screenshot's W×H) and asks for pixels; some vision
    /// models are trained to answer in a normalized 0-1000 grid instead. The
    /// engine converts in ONE place (WindowCapture.modelPointToGlobalAppKit), so
    /// flipping this is safe at runtime.
    enum CoordinateSpace: String { case pixels, normalized1000 }

    /// Explicit user choice, or the model-family default when unset.
    static var coordinateSpace: CoordinateSpace {
        get {
            if let raw = UserDefaults.standard.string(forKey: "ollama.coordinateSpace"),
               let explicit = CoordinateSpace(rawValue: raw) { return explicit }
            return defaultCoordinateSpace(for: model)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ollama.coordinateSpace") }
    }

    /// Measured on 2026-08-28 with qwen3-vl:4b on Ollama 0.17.4: told a 1280×800
    /// pixel space, it still answered a button at (950,626) with [730,775] and
    /// one at (730,626) with [565,779] — the Qwen3-VL family grounds on a 0-1000
    /// grid whatever the prompt says. Other families default to pixels until
    /// measured; the Settings pane lets the user override either way.
    static func defaultCoordinateSpace(for model: String) -> CoordinateSpace {
        // Match anywhere in the tag: models pulled from Hugging Face look like
        // "hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M".
        let m = model.lowercased().replacingOccurrences(of: "_", with: "-")
        for family in ["qwen3-vl", "qwen3.5", "qwen3.6", "qwen3.8"] where m.contains(family) {
            return .normalized1000
        }
        return .pixels
    }

    // MARK: Readiness

    /// True when the server answered a probe AND the chosen model is pulled.
    /// Updated by OllamaServer; read synchronously everywhere a gate is needed.
    private static let readinessLock = NSLock()
    private static var _isConfigured = false
    private static var _lastProblem: String? = "Checking Ollama…"
    static var isConfigured: Bool { readinessLock.lock(); defer { readinessLock.unlock() }; return _isConfigured }
    static var lastProblem: String? { readinessLock.lock(); defer { readinessLock.unlock() }; return _lastProblem }

    /// Fired (on the main actor) whenever readiness flips or settings change.
    static var onStatusChanged: (() -> Void)?
    /// Fired when host/model/context settings change (OllamaServer re-probes).
    static var onSettingsChanged: (() -> Void)?

    static func updateReadiness(ready: Bool, problem: String?) {
        readinessLock.lock()
        let newProblem = ready ? nil : problem
        let flipped = ready != _isConfigured || newProblem != _lastProblem
        _isConfigured = ready
        _lastProblem = newProblem
        readinessLock.unlock()
        if flipped { onStatusChanged?() }
    }

    /// One consistent line for every "Holmes can't act right now" message.
    static var notReadyMessage: String {
        let why = lastProblem ?? "Ollama isn't ready"
        return "\(why) — open Holmes ▸ Settings ▸ Local Model."
    }

    // MARK: Version helpers

    /// Compares dotted versions ("0.17.4" ≥ "0.12.10").
    static func version(_ a: String, isAtLeast b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        let pb = b.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}
