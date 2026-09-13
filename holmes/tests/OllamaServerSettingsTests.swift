import Foundation

/// Stubs only the model client. The config, server and URLSession probe path are
/// production code; every HTTP request is intercepted before reaching a socket.
actor OllamaClient {
    static let shared = OllamaClient()
    struct Capabilities { let tools: Bool; let vision: Bool; let thinking: Bool }
    var isAgentSessionActive = false
    private var heldModel: String?
    private var continuation: CheckedContinuation<Capabilities, Never>?
    private(set) var waitingForCapabilities = false

    func holdCapabilities(for model: String) { heldModel = model }
    func capabilities(for model: String) async throws -> Capabilities {
        if model == heldModel {
            heldModel = nil
            waitingForCapabilities = true
            return await withCheckedContinuation { continuation = $0 }
        }
        return Capabilities(tools: true, vision: true, thinking: false)
    }
    func releaseUnsuitableCapabilities() {
        waitingForCapabilities = false
        continuation?.resume(returning: Capabilities(tools: false, vision: false, thinking: false))
        continuation = nil
    }
    func forgetCapabilities() {}
    func request(path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { [:] }
}

final class SettingsProbeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var holdNext = false
    private static var waiting: SettingsProbeProtocol?
    private static var failReleasedRequest = false
    static var hasHeldRequest: Bool { lock.lock(); defer { lock.unlock() }; return waiting != nil }

    static func holdNextVersion(failingWhenReleased: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        holdNext = true
        failReleasedRequest = failingWhenReleased
    }

    static func release() {
        lock.lock()
        let pending = waiting
        let fail = failReleasedRequest
        waiting = nil
        lock.unlock()
        if fail { pending?.client?.urlProtocol(pending!, didFailWithError: URLError(.cannotConnectToHost)) }
        else { pending?.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        if Self.holdNext, request.url?.path == "/api/version" {
            Self.holdNext = false
            Self.waiting = self
            Self.lock.unlock()
            return
        }
        Self.lock.unlock()
        respond()
    }
    override func stopLoading() {}

    private func respond() {
        guard let url = request.url else { fatalError("Missing mock request URL") }
        let body: [String: Any]
        if url.path == "/api/version" {
            body = ["version": url.host == "old.invalid" ? "0.33.0" : "0.34.0"]
        } else if url.path == "/api/tags" {
            body = ["models": ["old-model", "new-model", "third-model"].map {
                ["name": $0, "size": 1024, "details": ["family": "test"]] as [String: Any]
            }]
        } else {
            fatalError("Unexpected network request: \(url)")
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct OllamaServerSettingsTests {
    @MainActor static func main() async {
        // The standalone executable uses its own defaults domain. Restore every
        // touched key as well, so repeated local runs leave no settings behind.
        let keys = ["ollama.host", "ollama.model", "ollama.userChoseModel", "ollama.modelAdopted", "ollama.keepAlive"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            OllamaConfig.onSettingsChanged = nil
            for key in keys {
                if let value = previous[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        OllamaConfig.host = "http://old.invalid:11434"
        OllamaConfig.model = "old-model"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsProbeProtocol.self]
        let server = OllamaServer(session: URLSession(configuration: config))
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        await server.refresh()
        expect(server.status == .ready(version: "0.33.0"), "Initial server should be ready")
        expect(OllamaConfig.isConfigured, "Initial probe must open readiness")

        SettingsProbeProtocol.holdNextVersion()
        let oldProbe = Task { await server.refresh() }
        await eventually { SettingsProbeProtocol.hasHeldRequest }
        OllamaConfig.host = "http://new.invalid:11434"
        expect(!OllamaConfig.isConfigured, "Changing host must close readiness immediately")
        expect(server.status == .unknown, "A changed host must show checking, not old success")
        expect(server.installedModels.isEmpty, "The old host's model list must be cleared")
        SettingsProbeProtocol.release()
        await oldProbe.value
        expect(server.status == .ready(version: "0.34.0"), "A queued host change must re-probe without waiting for the monitor")
        expect(server.serverVersion == "0.34.0", "Old server response must not overwrite new version")

        await OllamaClient.shared.holdCapabilities(for: "old-model")
        let capabilitiesProbe = Task { await server.refresh() }
        await eventually { await OllamaClient.shared.waitingForCapabilities }
        OllamaConfig.model = "new-model"
        OllamaConfig.model = "third-model"
        expect(!OllamaConfig.isConfigured, "Changing models must invalidate readiness")
        await OllamaClient.shared.releaseUnsuitableCapabilities()
        await capabilitiesProbe.value
        expect(server.status.isReady, "Old model's missing capabilities must not reject the latest model")
        expect(OllamaConfig.model == "third-model", "Rapid changes must preserve the latest model")
        expect(OllamaConfig.isConfigured, "Latest compatible model should reopen readiness")

        SettingsProbeProtocol.holdNextVersion(failingWhenReleased: true)
        let failedProbe = Task { await server.refresh() }
        await eventually { SettingsProbeProtocol.hasHeldRequest }
        OllamaConfig.host = "http://old.invalid:11434"
        SettingsProbeProtocol.release()
        await failedProbe.value
        expect(server.status == .ready(version: "0.33.0"), "A failed stale request must not mark the replacement host unavailable")
        expect(server.lastProbe != nil, "Completed current probe should publish its completion time")
        print("Passed \(checks) Ollama settings regression checks")
    }

    @MainActor private static func eventually(_ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for mocked probe suspension")
    }
}
