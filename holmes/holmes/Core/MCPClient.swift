import Foundation

// MARK: - MCPTransport
// Common interface for the two ways Holmes talks to an MCP server.

protocol MCPTransport: AnyObject {
    var serverName: String { get }
    func start() async throws -> [MCPTool]
    func callTool(_ name: String, arguments: [String: Any]) async throws -> OllamaClient.ToolResult
    func stop()
}

// MARK: - MCPConnection (stdio)
// One local MCP server spoken to over stdio with newline-delimited JSON-RPC 2.0.
// Launched as a child process — only possible because Holmes is NOT sandboxed.

final class MCPConnection: MCPTransport {
    let serverName: String

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readBuffer = Data()

    enum MCPError: LocalizedError {
        case launch(String), timeout, serverError(String), notConnected
        var errorDescription: String? {
            switch self {
            case .launch(let m):       return "Failed to launch: \(m)"
            case .timeout:             return "MCP request timed out"
            case .serverError(let m):  return m
            case .notConnected:        return "MCP server not connected"
            }
        }
    }

    init(name: String, command: String, args: [String], env: [String: String]) {
        serverName = name

        // Resolve the command from PATH via /usr/bin/env.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        var environment = ProcessInfo.processInfo.environment
        // Finder-launched GUI apps inherit a minimal PATH; add common bin dirs so
        // `npx` / `uvx` / `python` resolve.
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                     "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (extra + existing).joined(separator: ":")
        for (k, v) in env { environment[k] = v }
        process.environment = environment
    }

    // MARK: Lifecycle

    func start() async throws -> [MCPTool] {
        startReading()
        process.terminationHandler = { [weak self] proc in
            self?.outPipe.fileHandleForReading.readabilityHandler = nil
            self?.errPipe.fileHandleForReading.readabilityHandler = nil
            self?.failAllPending(MCPError.serverError("server exited (status \(proc.terminationStatus))"))
        }
        do { try process.run() }
        catch { throw MCPError.launch(error.localizedDescription) }

        // npx may download the package on first run, so allow a generous handshake.
        _ = try await send("initialize", params: MCPProtocol.initializeParams(), timeout: 120)
        notify("notifications/initialized", params: [:])

        // Page through tools/list (some servers paginate via nextCursor).
        var tools: [MCPTool] = []
        var cursor: String? = nil
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await send("tools/list", params: params, timeout: 60)
            let arr = result["tools"] as? [[String: Any]] ?? []
            tools += arr.compactMap { MCPProtocol.parseTool($0, serverName: serverName) }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        return tools
    }

    func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        failAllPending(MCPError.notConnected)
    }

    // MARK: Tool call

    func callTool(_ name: String, arguments: [String: Any]) async throws -> OllamaClient.ToolResult {
        let result = try await send("tools/call",
                                    params: ["name": name, "arguments": arguments],
                                    timeout: 120)
        return MCPProtocol.toolResult(from: result)
    }

    // MARK: JSON-RPC

    private func send(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = withLock { () -> Int in let i = nextID; nextID += 1; return i }
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            withLock { pending[id] = cont }
            do {
                try writeMessage(payload)
            } catch {
                withLock { _ = pending.removeValue(forKey: id) }
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let c = self.withLock { self.pending.removeValue(forKey: id) }
                c?.resume(throwing: MCPError.timeout)
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) {
        try? writeMessage(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func writeMessage(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A) // newline-delimited
        try inPipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: Reader

    private func startReading() {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: the dispatch source keeps firing until the handler is
            // removed — leaving it would spin a thread at 100% for the app's life.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.ingest(data)
        }
        // Surface server diagnostics (auth prompts, crashes) instead of silently dropping them.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { print("[MCP:\(self?.serverName ?? "?")] \(trimmed)") }
        }
    }

    private func ingest(_ data: Data) {
        let lines: [Data] = withLock {
            readBuffer.append(data)
            var out: [Data] = []
            while let nl = readBuffer.firstIndex(of: 0x0A) {
                out.append(readBuffer.subdata(in: readBuffer.startIndex..<nl))
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
            }
            return out
        }
        for line in lines { handleLine(line) }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        let id = (obj["id"] as? Int) ?? (obj["id"] as? NSNumber)?.intValue
        guard let id else { return } // server-initiated notification/request — ignore

        let cont = withLock { pending.removeValue(forKey: id) }
        guard let cont else { return }

        if let error = obj["error"] as? [String: Any] {
            cont.resume(throwing: MCPError.serverError(error["message"] as? String ?? "MCP error"))
        } else {
            cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: Locking helpers (NSLock is fine here — never held across an await).

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    private func failAllPending(_ error: Error) {
        let conts = withLock { () -> [Int: CheckedContinuation<[String: Any], Error>] in
            let c = pending; pending.removeAll(); return c
        }
        for (_, c) in conts { c.resume(throwing: error) }
    }
}

// MARK: - MCPSSEParser
// Incremental parser for a `text/event-stream` body (WHATWG Server-Sent Events).
// Feed it bytes as they arrive off the wire; it hands back the `data` payload of
// each event as soon as the event's terminating blank line has been seen, so the
// caller never has to wait for the connection to close.

struct MCPSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var skipLineFeed = false

    /// Feeds one byte. Returns the event payload when this byte completes an event.
    mutating func feed(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0D: // CR ends the line; a following LF belongs to the same terminator.
            skipLineFeed = true
            return endLine()
        case 0x0A:
            if skipLineFeed { skipLineFeed = false; return nil }
            return endLine()
        default:
            skipLineFeed = false
            line.append(byte)
            return nil
        }
    }

    /// Feeds a chunk. Returns every event payload completed within it, in order.
    mutating func feed<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var events: [String] = []
        for byte in bytes {
            if let event = feed(byte) { events.append(event) }
        }
        return events
    }

    private mutating func endLine() -> String? {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)

        // A blank line dispatches the pending event; a blank line with no data is a no-op.
        if text.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            return payload
        }
        if text.hasPrefix(":") { return nil } // comment / keepalive

        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        // Only `data` carries JSON-RPC; `event`, `id` and `retry` do not affect Holmes.
        if field == "data" { dataLines.append(String(value)) }
        return nil
    }
}

// MARK: - MCPHTTPConnection (remote Streamable HTTP)
// Talks to a hosted MCP server over HTTP. Each JSON-RPC request is a POST; the server
// may reply with a single JSON body or an SSE stream. A stream is read event by event
// as bytes arrive, so a server that keeps the connection open after answering does
// not stall the request. Auth is via headers (e.g. Authorization: Bearer …) supplied
// in mcp.json.

final class MCPHTTPConnection: MCPTransport {
    let serverName: String
    private let url: URL
    private let headers: [String: String]

    private let lock = NSLock()
    private var nextID = 1
    private var sessionID: String?
    private var negotiatedVersion = MCPProtocol.version

    enum MCPError: LocalizedError {
        case http(Int, String), badResponse(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .badResponse(let m):       return m
            }
        }
    }

    init(name: String, url: URL, headers: [String: String]) {
        self.serverName = name
        self.url = url
        self.headers = headers
    }

    func start() async throws -> [MCPTool] {
        let initResult = try await rpc("initialize", params: MCPProtocol.initializeParams())
        negotiatedVersion = initResult["protocolVersion"] as? String ?? MCPProtocol.version
        try? await notify("notifications/initialized")

        var tools: [MCPTool] = []
        var cursor: String? = nil
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc("tools/list", params: params)
            let arr = result["tools"] as? [[String: Any]] ?? []
            tools += arr.compactMap { MCPProtocol.parseTool($0, serverName: serverName) }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        return tools
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> OllamaClient.ToolResult {
        let result = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
        return MCPProtocol.toolResult(from: result)
    }

    func stop() {} // stateless; the server reaps idle sessions on its own.

    // MARK: HTTP JSON-RPC

    private func nextRequestID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let i = nextID; nextID += 1; return i
    }

    private func buildRequest(body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID()
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: payload)

        // bytes(for:) returns once the headers are in, so an SSE reply can be consumed
        // incrementally instead of waiting for the server to close the connection.
        let (bytes, response) = try await URLSession.shared.bytes(for: buildRequest(body: body))
        let http = response as? HTTPURLResponse
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { sessionID = sid }

        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let data = try await Self.collect(bytes)
            throw MCPError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let obj: [String: Any]
        if ctype.contains("text/event-stream") {
            obj = try await Self.firstResponse(in: bytes)
        } else {
            let data = try await Self.collect(bytes)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.badResponse("no JSON-RPC object in response")
            }
            obj = parsed
        }
        if let error = obj["error"] as? [String: Any] {
            throw MCPError.badResponse(error["message"] as? String ?? "MCP error")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    /// Reads a whole body: a plain JSON reply or an error page.
    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    /// Walks an SSE stream event by event and returns the first JSON-RPC response
    /// (an object carrying `result` or `error`) the moment it is complete.
    private static func firstResponse(in bytes: URLSession.AsyncBytes) async throws -> [String: Any] {
        var parser = MCPSSEParser()
        for try await byte in bytes {
            guard let payload = parser.feed(byte),
                  let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["result"] != nil || obj["error"] != nil
            else { continue }
            return obj
        }
        throw MCPError.badResponse("SSE stream ended before a JSON-RPC response arrived")
    }

    private func notify(_ method: String) async throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": [:]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await URLSession.shared.data(for: buildRequest(body: body))
    }
}

// MARK: - MCPClient
// Host-side registry: connects every configured server (stdio or http) and aggregates
// their tools into one namespaced set the local model's tool loop can call.

@MainActor
final class MCPClient {
    static let shared = MCPClient()
    private init() {}

    private(set) var transports: [any MCPTransport] = []
    private(set) var tools: [MCPTool] = []
    private(set) var status: String = "Not started"

    private var index: [String: (transport: any MCPTransport, toolName: String)] = [:]
    private var starting = false

    /// Connects all configured servers. Safe to call repeatedly; the `starting` flag
    /// (set synchronously before any await) prevents reentrant double-starts.
    func startAll() async {
        guard transports.isEmpty, !starting else { return }
        starting = true
        defer { starting = false }

        let configs = MCPConfigLoader.load()
        guard !configs.isEmpty else { status = "No MCP servers configured"; return }

        for config in configs {
            let transport: any MCPTransport
            switch config.transport {
            case .stdio(let command, let args, let env):
                transport = MCPConnection(name: config.name, command: command, args: args, env: env)
            case .http(let url, let headers):
                transport = MCPHTTPConnection(name: config.name, url: url, headers: headers)
            }
            do {
                let serverTools = try await transport.start()
                transports.append(transport)
                for t in serverTools {
                    tools.append(t)
                    index[t.namespacedName] = (transport, t.name)
                }
                print("[MCP] \(config.name): \(serverTools.count) tools")
            } catch {
                print("[MCP] \(config.name) failed: \(error.localizedDescription)")
                transport.stop() // do not orphan a launched child process
            }
        }
        status = transports.isEmpty
            ? "All MCP servers failed to start"
            : "\(transports.count) server(s), \(tools.count) tools"
        print("[MCP] \(status)")
    }

    func toolDefs() -> [OllamaClient.ToolDef] { tools.map { $0.toolDef } }

    func tool(forNamespacedName name: String) -> MCPTool? {
        tools.first { $0.namespacedName == name }
    }

    func call(namespacedName: String, arguments: [String: Any]) async -> OllamaClient.ToolResult {
        guard let entry = index[namespacedName] else {
            return OllamaClient.ToolResult("Unknown tool: \(namespacedName)", isError: true)
        }
        do {
            return try await entry.transport.callTool(entry.toolName, arguments: arguments)
        } catch {
            return OllamaClient.ToolResult("Tool call failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Tear down every transport and reconnect from the current mcp.json —
    /// what onboarding/Settings call after writing a new server entry.
    func restart() async {
        stopAll()
        await startAll()
    }

    func stopAll() {
        transports.forEach { $0.stop() }
        transports.removeAll()
        tools.removeAll()
        index.removeAll()
        status = "Stopped"
    }
}
