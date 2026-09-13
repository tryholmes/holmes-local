import Foundation

/// Holds actual URLSession requests made by the production Ollama actor. No
/// Ollama process, microphone, or real network endpoint participates.
final class WorkModelProtocol: URLProtocol {
    struct Reply {
        var text = "Ready"
        var hold = false
        var status = 200
        var doneReason = "stop"
        var tool: String?
        var networkFailure = false
    }

    private static let lock = NSLock()
    private static var scripts: [String: [Reply]] = [:]
    private static var counts: [String: Int] = [:]
    private static var held: [String: WorkModelProtocol] = [:]
    private static var contexts: [Int] = []
    private var key = ""
    private var reply = Reply()
    private var stopped = false

    static func configure(_ key: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        scripts[key] = replies
    }

    static func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key, default: 0]
    }

    static func isHeld(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held[key] != nil
    }

    static var contextSizes: [Int] {
        lock.lock(); defer { lock.unlock() }
        return contexts
    }

    static func release(_ key: String) {
        lock.lock()
        let request = held.removeValue(forKey: key)
        lock.unlock()
        precondition(request != nil, "No held request for \(key)")
        request?.respond()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "work-activity.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let object = try? JSONSerialization.jsonObject(with: requestBody()) as? [String: Any] else {
            fatalError("Missing JSON body")
        }
        if request.url?.path == "/api/show" {
            respondJSON(["capabilities": ["tools"]])
            return
        }
        guard request.url?.path == "/api/chat",
              let messages = object["messages"] as? [[String: Any]],
              let user = messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String,
              let options = object["options"] as? [String: Any], let context = options["num_ctx"] as? Int
        else { fatalError("Unexpected production request") }
        key = user
        Self.lock.lock()
        let index = Self.counts[user, default: 0]
        guard let script = Self.scripts[user], index < script.count else {
            Self.lock.unlock()
            fatalError("No scripted response for \(user) request \(index)")
        }
        reply = script[index]
        Self.counts[user] = index + 1
        Self.contexts.append(context)
        if reply.hold { Self.held[user] = self }
        Self.lock.unlock()
        if !reply.hold { respond() }
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
        if Self.held[key] === self { Self.held.removeValue(forKey: key) }
    }

    private func respond() {
        Self.lock.lock()
        let mayRespond = !stopped
        Self.lock.unlock()
        guard mayRespond else { return }
        if reply.networkFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if reply.status != 200 {
            respondJSON(["error": "Controlled server failure"], status: reply.status)
            return
        }
        var message: [String: Any] = ["role": "assistant", "content": reply.text]
        if let tool = reply.tool {
            message["tool_calls"] = [["function": ["name": tool, "arguments": [String: Any]()]]]
        }
        let object: [String: Any] = ["message": message, "done": true, "done_reason": reply.doneReason]
        respondJSON(object, newline: true)
    }

    private func respondJSON(_ object: [String: Any], status: Int = 200, newline: Bool = false) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": newline ? "application/x-ndjson" : "application/json"])!
        var data = try! JSONSerialization.data(withJSONObject: object)
        if newline { data.append(10) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

@main
struct OllamaWorkActivityTests {
    @MainActor static func main() async throws {
        let keys = ["ollama.host", "ollama.model", "ollama.numCtx"]
        let defaults = UserDefaults.standard
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let settingsCallback = OllamaConfig.onSettingsChanged
        let statusCallback = OllamaConfig.onStatusChanged
        let wasReady = OllamaConfig.isConfigured
        let previousProblem = OllamaConfig.lastProblem
        OllamaConfig.onSettingsChanged = nil
        OllamaConfig.onStatusChanged = nil
        precondition(URLProtocol.registerClass(WorkModelProtocol.self))
        let center = WorkActivityCenter.shared
        center.invalidateAll()
        defer {
            center.onChange = nil
            center.invalidateAll()
            URLProtocol.unregisterClass(WorkModelProtocol.self)
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            OllamaConfig.updateReadiness(ready: wasReady, problem: previousProblem)
            OllamaConfig.onSettingsChanged = settingsCallback
            OllamaConfig.onStatusChanged = statusCallback
        }
        OllamaConfig.host = "http://work-activity.invalid:11434"
        OllamaConfig.model = "work-test"
        OllamaConfig.numCtx = 4096
        OllamaConfig.updateReadiness(ready: true, problem: nil)
        let client = OllamaClient.shared
        await client.forgetCapabilities()
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        var phases: [UUID: [WorkActivityCenter.Phase]] = [:]
        center.onChange = {
            for activity in center.activities {
                if phases[activity.id]?.last != activity.phase {
                    phases[activity.id, default: []].append(activity.phase)
                }
            }
        }

        WorkModelProtocol.configure("queue-a", [.init(text: "Background answer", hold: true)])
        let first = Task { try await client.complete(system: "Test", user: "queue-a") }
        try await eventually { WorkModelProtocol.isHeld("queue-a") }
        expect(center.activeCount == 1 && center.selectedActivity?.phase == .working,
               "A held production request must have one working owner")

        let cancelledID = center.begin(title: "Cancelled queued request")
        let cancelled = Task {
            try await WorkActivityScope.$id.withValue(cancelledID) {
                try await client.complete(system: "Test", user: "queue-b", priority: .agent)
            }
        }
        try await eventually { center.activities.first(where: { $0.id == cancelledID })?.phase == .queued }
        expect(center.selectedActivity?.id == cancelledID, "The explicit queued request must be visible over background generation")

        let followingID = center.begin(title: "Following queued request")
        WorkModelProtocol.configure("queue-c", [.init(text: "Following answer", hold: true)])
        let following = Task {
            try await WorkActivityScope.$id.withValue(followingID) {
                try await client.complete(system: "Test", user: "queue-c", priority: .agent)
            }
        }
        try await eventually { center.activities.first(where: { $0.id == followingID })?.phase == .queued }
        cancelled.cancel()
        switch await cancelled.result {
        case .failure(let error): expect(error is CancellationError, "Queued cancellation must throw CancellationError")
        case .success: fatalError("A cancelled waiter must not generate")
        }
        expect(center.isActive(cancelledID), "The model must never end an inherited owner's activity")
        center.cancel(cancelledID)
        expect(WorkModelProtocol.count("queue-b") == 0 && WorkModelProtocol.count("queue-c") == 0,
               "Cancelling a waiter must not steal or release the active request's GPU gate")
        expect(WorkModelProtocol.isHeld("queue-a"), "The original request must retain its gate after queued cancellation")
        WorkModelProtocol.release("queue-a")
        let firstText = try await first.value
        expect(firstText == "Background answer", "Original owner must finish normally")
        try await eventually { WorkModelProtocol.isHeld("queue-c") }
        expect(center.activeCount == 1 && center.selectedActivity?.id == followingID,
               "Background completion must leave the queued explicit owner in place")
        expect(phases[followingID] == [.preparing, .queued, .working],
               "Queue and generation states must be delivered in order at actual gate ownership")
        WorkModelProtocol.release("queue-c")
        let followingText = try await following.value
        expect(followingText == "Following answer" && center.isActive(followingID),
               "Successful nested generation must leave its parent active for postprocessing")
        center.finish(followingID, outcome: .success, summary: "Draft ready")

        // The notch's Stop callback must cancel the actual fallback request,
        // release its gate, and reject any late response from that old request.
        WorkModelProtocol.configure("stop-fallback", [.init(hold: true)])
        let stopped = Task { try await client.complete(system: "Test", user: "stop-fallback", priority: .agent) }
        try await eventually { WorkModelProtocol.isHeld("stop-fallback") }
        center.cancelSelected()
        switch await stopped.result {
        case .failure(let error): expect(error is CancellationError, "Stop must cancel the URLSession work, not only hide its indicator")
        case .success: fatalError("Stopped fallback must not return an answer")
        }
        expect(center.activeCount == 0 && center.completion?.outcome == .cancelled,
               "The cancelled fallback must retain its stopped outcome without leaking activity")
        WorkModelProtocol.configure("after-stop", [.init(text: "Still works")])
        let afterStop = try await client.complete(system: "Test", user: "after-stop", priority: .agent)
        expect(afterStop == "Still works" && center.activeCount == 0, "A stopped request must release the gate for the next user")

        for (key, reply) in [
            ("empty", WorkModelProtocol.Reply(text: "")),
            ("truncated", WorkModelProtocol.Reply(text: "", doneReason: "length")),
            ("server-error", WorkModelProtocol.Reply(status: 500)),
            ("network-error", WorkModelProtocol.Reply(networkFailure: true))
        ] {
            WorkModelProtocol.configure(key, [reply])
            do {
                _ = try await client.complete(system: "Test", user: key, priority: .agent)
                fatalError("\(key) must fail")
            } catch {
                expect(center.activeCount == 0 && center.completion?.outcome == .failure,
                       "\(key) must produce a visible failure and release all fallback state")
            }
        }

        let failedParent = center.begin(title: "Draft needing an error result")
        WorkModelProtocol.configure("parent-error", [.init(status: 500)])
        do {
            _ = try await WorkActivityScope.$id.withValue(failedParent) {
                try await client.complete(system: "Test", user: "parent-error", priority: .agent)
            }
            fatalError("Expected controlled error")
        } catch {
            expect(center.isActive(failedParent), "Nested generation errors must preserve their owner for its error policy or retry")
        }
        center.finish(failedParent, outcome: .failure, summary: "Couldn't draft the email")

        let agentParent = center.begin(title: "A multi-turn request")
        WorkModelProtocol.configure("agent-owned", [.init(text: "", tool: "probe"), .init(text: "Checked it")])
        var toolOwner: UUID?
        let agentResult = try await WorkActivityScope.$id.withValue(agentParent) {
            try await client.runAgent(system: "Test", userText: "agent-owned",
                                      tools: [.init(name: "probe", description: "Read-only test", inputSchema: [:])],
                                      maxIterations: 3, runTool: { _, _ in
                let id = WorkActivityScope.id
                await MainActor.run { toolOwner = id }
                return OllamaClient.ToolResult("Observed")
            })
        }
        expect(toolOwner == agentParent && agentResult.toolCallCount == 1 && center.isActive(agentParent),
               "Every model turn and nested tool must share the same live parent until the caller finishes")
        center.finish(agentParent, outcome: .success, summary: "Checked it")

        let busyAgentID = center.begin(title: "Current user request")
        WorkModelProtocol.configure("busy-agent", [.init(text: "Finished", hold: true)])
        let busyAgent = Task {
            try await WorkActivityScope.$id.withValue(busyAgentID) {
                try await client.runAgent(system: "Test", userText: "busy-agent", tools: [],
                                          maxIterations: 1, runTool: { _, _ in OllamaClient.ToolResult("") })
            }
        }
        try await eventually { WorkModelProtocol.isHeld("busy-agent") }
        let retryOwner = center.begin(title: "Automatic draft waiting to retry", origin: .background)
        let completionBeforeBusy = center.completion
        do {
            _ = try await WorkActivityScope.$id.withValue(retryOwner) {
                try await client.complete(system: "Test", user: "busy-background")
            }
            fatalError("Background work must retain the existing busy policy")
        } catch OllamaClient.AgentError.busy {
            expect(center.isActive(retryOwner) && center.activities.first(where: { $0.id == retryOwner })?.phase == .queued,
                   "Busy background work must retain its inherited owner for a visible queued retry")
        }
        do {
            _ = try await client.complete(system: "Test", user: "busy-fallback")
            fatalError("Fallback background work must retain the existing busy policy")
        } catch OllamaClient.AgentError.busy {
            expect(center.activeCount == 2 && center.completion == completionBeforeBusy,
                   "Rejected background fallbacks must not leak owners or flash error storms")
        }
        center.cancel(retryOwner)
        WorkModelProtocol.release("busy-agent")
        _ = try await busyAgent.value
        center.finish(busyAgentID, outcome: .success, summary: "Finished")

        OllamaConfig.updateReadiness(ready: false, problem: "Ollama is stopped")
        do {
            _ = try await client.complete(system: "Test", user: "not-ready", priority: .agent)
            fatalError("Unconfigured local model must fail")
        } catch {
            expect(center.activeCount == 0 && center.completion?.outcome == .failure,
                   "Readiness failure before any network request must still visibly finish the owned request")
        }
        expect(!WorkModelProtocol.contextSizes.isEmpty && WorkModelProtocol.contextSizes.allSatisfy { $0 == 4096 },
               "Queue and activity instrumentation must preserve the pinned num_ctx for every model request")
        print("Passed \(checks) production Ollama ownership, queue, cancellation, and failure checks")
    }

    @MainActor static func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for the controlled production request")
    }
}
