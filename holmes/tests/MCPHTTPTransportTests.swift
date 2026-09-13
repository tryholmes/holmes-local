import Foundation

// Regression checks for MCPHTTPConnection, the remote Streamable HTTP transport.
// The bug: a server that answered over SSE and then kept the connection open made
// Holmes wait for the request timeout, because the whole body was buffered before
// any event was parsed. Every scenario below runs against a scripted stand in for
// the server; nothing touches the network.

/// Intercepts URLSession.shared like the other Holmes test doubles. Each request is
/// answered by the reply queued for its JSON-RPC method: a status, headers and body
/// chunks that may be delayed or left open forever. `{{id}}` inside a chunk is
/// replaced with the request's JSON-RPC id so scripts do not depend on numbering.
final class ScriptedMCPServer: URLProtocol {
    enum Step {
        case chunk(String)
        case wait(TimeInterval)
        case finish
        case hold
    }

    struct Reply {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var steps: [Step]
    }

    struct Seen {
        let method: String
        let id: Int?
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var scripts: [String: [Reply]] = [:]
    private static var seen: [Seen] = []
    private static var stops: [String] = []
    private var stopped = false
    private var method = ""
    private let queue = DispatchQueue(label: "holmes.tests.scripted-mcp-server")

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        scripts = [:]; seen = []; stops = []
    }

    static func script(_ method: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        scripts[method, default: []].append(reply)
    }

    static var requests: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    /// Methods whose load has been stopped. URLSession stops a finished load too, so
    /// for a `.hold` reply this only happens when the client cancels it.
    static var released: [String] {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.httpMethod == "POST",
              let object = try? JSONSerialization.jsonObject(with: body()) as? [String: Any],
              let method = object["method"] as? String
        else { fatalError("Unexpected request: \(request)") }
        let id = (object["id"] as? NSNumber)?.intValue
        self.method = method

        Self.lock.lock()
        Self.seen.append(Seen(method: method, id: id, headers: request.allHTTPHeaderFields ?? [:]))
        guard !(Self.scripts[method] ?? []).isEmpty else { fatalError("No scripted reply for \(method)") }
        let reply = Self.scripts[method]!.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        queue.async { self.run(reply.steps, id: id) }
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
        Self.stops.append(method)
    }

    private func isStopped() -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return stopped
    }

    private func run(_ steps: [Step], id: Int?) {
        for step in steps {
            if isStopped() { return }
            switch step {
            case .chunk(let text):
                let filled = text.replacingOccurrences(of: "{{id}}", with: id.map(String.init) ?? "null")
                client?.urlProtocol(self, didLoad: Data(filled.utf8))
            case .wait(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            case .finish:
                client?.urlProtocolDidFinishLoading(self)
                return
            case .hold:
                return
            }
        }
    }

    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@main
struct MCPHTTPTransportTests {
    static var checks = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    /// One SSE event carrying `object` as its data line.
    static func event(_ object: [String: Any], eol: String = "\n") -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return "event: message\(eol)data: \(json)\(eol)\(eol)"
    }

    static func toolResponse(_ text: String) -> String {
        // The id is a placeholder the scripted server fills in from the request.
        "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":{{id}},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}\n\n"
    }

    static func connection(timeout: TimeInterval = 120) -> MCPHTTPConnection {
        let c = MCPHTTPConnection(name: "remote", url: URL(string: "https://mcp.invalid/mcp")!, headers: ["X-Test": "1"])
        c.requestTimeout = timeout
        return c
    }

    static func eventually(_ what: String, _ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for \(what)")
    }

    static func main() async throws {
        precondition(URLProtocol.registerClass(ScriptedMCPServer.self))
        defer { URLProtocol.unregisterClass(ScriptedMCPServer.self) }

        try await streamedReplyOnOpenConnection()
        try await eventsSplitAcrossChunksWithCRLF()
        try await otherMessagesOnTheStreamAreSkipped()
        try await jsonReplyAndSessionHeader()
        print("Passed \(checks) MCP HTTP transport regression checks")
    }

    // TEST: streamedReplyOnOpenConnection
    /// The reported bug: the response arrives over SSE but the server never closes.
    static func streamedReplyOnOpenConnection() async throws {
        ScriptedMCPServer.reset()
        ScriptedMCPServer.script("tools/call", .init(steps: [
            .chunk(": keepalive\n\n"), .wait(0.1), .chunk(toolResponse("streamed")), .hold
        ]))
        let started = Date()
        let result = try await connection().callTool("echo", arguments: ["q": "x"])
        let elapsed = Date().timeIntervalSince(started)
        expect(result.text == "streamed" && !result.isError, "Result comes from the SSE event")
        expect(elapsed < 10, "Reply must not wait for the connection to close (took \(elapsed)s)")
        await eventually("connection release") { ScriptedMCPServer.released == ["tools/call"] }
        expect(ScriptedMCPServer.released == ["tools/call"], "The open stream is cancelled once the response is read")
    }

    // TEST: eventsSplitAcrossChunksWithCRLF
    /// Bytes land in arbitrary pieces and servers may use CRLF; data may span lines.
    static func eventsSplitAcrossChunksWithCRLF() async throws {
        ScriptedMCPServer.reset()
        ScriptedMCPServer.script("tools/call", .init(steps: [
            .chunk("event: mess"), .wait(0.05),
            .chunk("age\r\nid: 7\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":{{id}},\r\n"), .wait(0.05),
            .chunk("data: \"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pieces\"}]}}\r\n"), .wait(0.05),
            .chunk("\r\n"), .hold
        ]))
        let result = try await connection().callTool("echo", arguments: [:])
        expect(result.text == "pieces", "Multi line data across chunk boundaries with CRLF is reassembled")
    }

    // TEST: otherMessagesOnTheStreamAreSkipped
    /// Notifications, server requests and replies to other ids share the stream.
    static func otherMessagesOnTheStreamAreSkipped() async throws {
        ScriptedMCPServer.reset()
        ScriptedMCPServer.script("tools/call", .init(steps: [
            .chunk(event(["jsonrpc": "2.0", "method": "notifications/message", "params": ["level": "info", "data": "hi"]])),
            .chunk(event(["jsonrpc": "2.0", "id": 900, "method": "sampling/createMessage", "params": [:]])),
            .chunk(event(["jsonrpc": "2.0", "id": 901, "result": ["content": [["type": "text", "text": "not mine"]]]])),
            .chunk(toolResponse("mine")), .hold
        ]))
        let result = try await connection().callTool("echo", arguments: [:])
        expect(result.text == "mine", "Only the response echoing our id completes the call")
    }

    // TEST: jsonReplyAndSessionHeader
    /// Plain JSON replies still work and the session id is carried on later requests.
    static func jsonReplyAndSessionHeader() async throws {
        ScriptedMCPServer.reset()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":{{id}},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"plain\"}],\"isError\":true}}"
        ScriptedMCPServer.script("tools/call", .init(
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            steps: [.chunk(json), .finish]))
        ScriptedMCPServer.script("tools/call", .init(
            headers: ["Content-Type": "application/json"], steps: [.chunk(json), .finish]))
        let c = connection()
        let first = try await c.callTool("echo", arguments: [:])
        expect(first.text == "plain" && first.isError, "JSON body is parsed with its isError flag")
        _ = try await c.callTool("echo", arguments: [:])
        let requests = ScriptedMCPServer.requests
        expect(requests.count == 2 && requests[0].headers["Mcp-Session-Id"] == nil, "First request has no session yet")
        expect(requests[1].headers["Mcp-Session-Id"] == "sess-1", "Session id from the reply is sent on the next request")
        expect(requests[1].headers["Accept"] == "application/json, text/event-stream", "Both reply types are advertised")
        expect(requests[1].headers["X-Test"] == "1", "Configured headers are sent")
    }
}
