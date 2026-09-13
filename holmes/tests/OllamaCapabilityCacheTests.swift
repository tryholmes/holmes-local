import Foundation

/// Intercepts the production client's URLSession.shared requests. A held reply
/// snapshots its capabilities when it starts, so tests can finish the OLD server
/// reply only after the configuration/cache has changed.
final class CapabilityShowProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [String: [String]] = [:]
    private static var counts: [String: Int] = [:]
    private static var holdNextRequest = false
    private static var held: CapabilityShowProtocol?
    private var responseCapabilities: [String] = []

    private static func key(_ host: String, _ model: String) -> String { "\(host)|\(model)" }

    static func configure(host: String, model: String, capabilities: [String]) {
        lock.lock(); defer { lock.unlock() }
        replies[key(host, model)] = capabilities
    }

    static func requestCount(host: String, model: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key(host, model), default: 0]
    }

    static func holdNext() {
        lock.lock(); defer { lock.unlock() }
        precondition(held == nil && !holdNextRequest, "Only one reply may be held")
        holdNextRequest = true
    }

    static var hasHeldReply: Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil
    }

    static func releaseHeldReply() {
        lock.lock()
        let pending = held
        held = nil
        lock.unlock()
        precondition(pending != nil, "No held reply to release")
        pending?.respond()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, url.path == "/api/show", request.httpMethod == "POST",
              let object = try? JSONSerialization.jsonObject(with: requestBody()) as? [String: Any],
              let model = object["model"] as? String,
              let host = url.host else { fatalError("Unexpected request: \(request)") }
        Self.lock.lock()
        let key = Self.key(host, model)
        guard let capabilities = Self.replies[key] else { fatalError("No mock for \(key)") }
        responseCapabilities = capabilities
        Self.counts[key, default: 0] += 1
        let shouldHold = Self.holdNextRequest
        if shouldHold {
            Self.holdNextRequest = false
            Self.held = self
        }
        Self.lock.unlock()
        if !shouldHold { respond() }
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["capabilities": responseCapabilities]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct OllamaCapabilityCacheTests {
    @MainActor static func main() async throws {
        // This executable has its own defaults domain; restore its one changed
        // setting as well. No real Ollama process, socket, or model is involved.
        let previousHost = UserDefaults.standard.object(forKey: "ollama.host")
        let previousSettingsCallback = OllamaConfig.onSettingsChanged
        OllamaConfig.onSettingsChanged = nil
        precondition(URLProtocol.registerClass(CapabilityShowProtocol.self))
        defer {
            URLProtocol.unregisterClass(CapabilityShowProtocol.self)
            OllamaConfig.onSettingsChanged = previousSettingsCallback
            if let previousHost { UserDefaults.standard.set(previousHost, forKey: "ollama.host") }
            else { UserDefaults.standard.removeObject(forKey: "ollama.host") }
        }

        let client = OllamaClient.shared
        let hostA = "cache-a.invalid"
        let hostB = "cache-b.invalid"
        let model = "same-tag"
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func matches(_ caps: OllamaClient.Capabilities, _ tools: Bool, _ vision: Bool, _ thinking: Bool) -> Bool {
            caps.tools == tools && caps.vision == vision && caps.thinking == thinking
        }

        await client.forgetCapabilities()
        CapabilityShowProtocol.configure(host: hostA, model: model, capabilities: ["tools"])
        CapabilityShowProtocol.configure(host: hostB, model: model, capabilities: ["vision", "thinking"])
        OllamaConfig.host = "http://\(hostA):11434"
        let a = try await client.capabilities(for: model)
        let aCached = try await client.capabilities(for: model)
        expect(matches(a, true, false, false) && matches(aCached, true, false, false), "Same-host cache returns its capabilities")
        expect(CapabilityShowProtocol.requestCount(host: hostA, model: model) == 1, "Repeated lookup should hit the cache")

        // Deliberately skip explicit invalidation: including HOST in the key must
        // independently keep a same-named model on another server separate.
        OllamaConfig.host = "http://\(hostB):11434"
        let b = try await client.capabilities(for: model)
        expect(matches(b, false, true, true), "Identical model tags on distinct hosts must not share capabilities")
        expect(CapabilityShowProtocol.requestCount(host: hostB, model: model) == 1, "A new host must actually be probed")
        OllamaConfig.host = "http://\(hostA):11434"
        let aAgain = try await client.capabilities(for: model)
        expect(matches(aAgain, true, false, false), "Returning to a host must use only its own cached entry")
        expect(CapabilityShowProtocol.requestCount(host: hostA, model: model) == 1, "Host-separated cached entries remain reusable")

        CapabilityShowProtocol.configure(host: hostA, model: "other-tag", capabilities: ["thinking"])
        let other = try await client.capabilities(for: "other-tag")
        expect(matches(other, false, false, true), "Different model tags on the same host have separate entries")

        // A completed old-host response must neither RETURN nor CACHE its caps
        // after a host change, even before any asynchronous invalidation arrives.
        await client.forgetCapabilities()
        CapabilityShowProtocol.holdNext()
        let oldHostLookup = Task { try await client.capabilities(for: model) }
        await eventually { CapabilityShowProtocol.hasHeldReply }
        OllamaConfig.host = "http://\(hostB):11434"
        let freshHost = try await client.capabilities(for: model)
        expect(matches(freshHost, false, true, true), "The new host remains usable while an old request is suspended")
        CapabilityShowProtocol.releaseHeldReply()
        do {
            _ = try await oldHostLookup.value
            fatalError("Old-host response must throw CancellationError")
        } catch is CancellationError { checks += 1 }
        let stillFresh = try await client.capabilities(for: model)
        expect(matches(stillFresh, false, true, true), "Old-host completion cannot replace the new-host cache")
        expect(CapabilityShowProtocol.requestCount(host: hostB, model: model) == 2, "Reading the fresh cache should not probe again")
        OllamaConfig.host = "http://\(hostA):11434"
        CapabilityShowProtocol.configure(host: hostA, model: model, capabilities: ["tools", "vision"])
        let reprobed = try await client.capabilities(for: model)
        expect(matches(reprobed, true, true, false), "Discarded old-host reply must not populate even its previous host's cache")
        expect(CapabilityShowProtocol.requestCount(host: hostA, model: model) == 3, "Returning to the discarded host must re-probe")

        // Reset while a SAME-host/same-model request is in flight: only the
        // generation can distinguish this stale response from the current one.
        await client.forgetCapabilities()
        CapabilityShowProtocol.configure(host: hostA, model: model, capabilities: ["tools"])
        CapabilityShowProtocol.holdNext()
        let beforeReset = Task { try await client.capabilities(for: model) }
        await eventually { CapabilityShowProtocol.hasHeldReply }
        await client.forgetCapabilities()
        CapabilityShowProtocol.configure(host: hostA, model: model, capabilities: ["vision", "thinking"])
        let afterReset = try await client.capabilities(for: model)
        expect(matches(afterReset, false, true, true), "Reset allows a fresh same-host lookup")
        CapabilityShowProtocol.releaseHeldReply()
        do {
            _ = try await beforeReset.value
            fatalError("A response started before invalidation must throw CancellationError")
        } catch is CancellationError { checks += 1 }
        let afterOldFinished = try await client.capabilities(for: model)
        expect(matches(afterOldFinished, false, true, true), "Stale completion must not overwrite a fresh same-key cache entry")
        expect(CapabilityShowProtocol.requestCount(host: hostA, model: model) == 5, "The post-reset result should remain cached")

        // Reset with no replacement lookup still prevents the pending response
        // from refilling a deliberately cleared cache.
        await client.forgetCapabilities()
        CapabilityShowProtocol.holdNext()
        let clearedLookup = Task { try await client.capabilities(for: model) }
        await eventually { CapabilityShowProtocol.hasHeldReply }
        await client.forgetCapabilities()
        CapabilityShowProtocol.releaseHeldReply()
        do {
            _ = try await clearedLookup.value
            fatalError("Reset must invalidate pending callbacks even with no replacement request")
        } catch is CancellationError { checks += 1 }
        CapabilityShowProtocol.configure(host: hostA, model: model, capabilities: ["tools", "vision", "thinking"])
        let afterClear = try await client.capabilities(for: model)
        expect(matches(afterClear, true, true, true), "An invalidated pending response cannot refill an empty cache")
        expect(CapabilityShowProtocol.requestCount(host: hostA, model: model) == 7, "Lookup after invalidated completion must re-probe")
        print("Passed \(checks) Ollama capability-cache regression checks")
    }

    private static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for held /api/show reply")
    }
}
