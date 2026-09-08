import Foundation

// MARK: - HolmesContextProviding
// Supplies the live context that Holmes exposes to OTHER agents (Claude Desktop,
// Cursor, a voice agent…) via its MCP server. Decoupled from the socket layer so the
// transport can be unit-tested with a stub. All methods return JSON-serializable values
// and are called off the main thread — implementations must hop to the main actor.

protocol HolmesContextProviding: AnyObject {
    func screenContext() -> [String: Any]
    func activeApp() -> [String: Any]
    func upcomingMeetings() -> [[String: Any]]
    func recentActivity() -> [[String: Any]]
}

// MARK: - MCPServer
// Holmes as an MCP *server*. Implements the MCP Streamable-HTTP transport over a raw
// BSD socket (no entitlements needed; the app is unsandboxed). Other MCP clients point
// at http://localhost:5767/mcp and can read the user's live screen context.
//
// Request/response only — each POST carries one JSON-RPC request and we answer with a
// single application/json body. No SSE / server-initiated streaming is needed.
//
// Security: bound to 127.0.0.1 (loopback) so only processes on this Mac can reach it.
// There is no auth, and loopback-only is NOT enough by itself: the endpoint relays
// TCC-gated screen content (whatever email, document, or 2FA code is on screen) to
// ANY local process, including ones the user never granted Screen Recording. The
// server is therefore OPT-IN — default off, started only when the user enables it
// in Settings > Privacy (see `isEnabledByUser` / HolmesAgent.start()).

final class MCPServer {
    #if !MCP_SERVER_TEST
    static let shared = MCPServer(provider: HolmesLiveContextProvider())
    #endif

    /// UserDefaults key for the Settings > Privacy opt-in. Default false: the
    /// server must never start without a deliberate user choice.
    static let enabledDefaultsKey = "holmes.mcpserver.enabled"

    static var isEnabledByUser: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    private let provider: HolmesContextProviding
    private let port: UInt16
    private var serverFD: Int32 = -1
    private let sessionID = UUID().uuidString
    private(set) var isRunning = false

    init(provider: HolmesContextProviding, port: UInt16 = 5767) {
        self.provider = provider
        self.port = port
    }

    // Tool catalog exposed to clients. All read-only (annotations.readOnlyHint).
    private var toolDefs: [[String: Any]] {
        func tool(_ name: String, _ desc: String) -> [String: Any] {
            ["name": name,
             "description": desc,
             "inputSchema": ["type": "object", "properties": [:]],
             "annotations": ["readOnlyHint": true, "title": name]]
        }
        return [
            tool("get_screen_context", "What the user is currently looking at: active app, window title, a one-line summary, and visible on-screen text. Check visibleTextConfidence before quoting visibleText — \"inferred\" means it is OCR of pixels and may be garbled, so never assert names, numbers or code from it."),
            tool("get_active_app", "The name and window title of the app the user is currently focused on."),
            tool("get_upcoming_meetings", "The user's meetings in the next 30 minutes, with join links and times."),
            tool("get_recent_activity", "A short log of what Holmes has recently observed the user doing.")
        ]
    }

    // MARK: - Lifecycle

    /// Binds + listens synchronously (so callers know it's ready), then accepts on a
    /// background queue. Safe to call once; no-op if already running.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[MCPServer] socket() failed: \(errno)"); return false }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1") // loopback only

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            print("[MCPServer] bind() failed on 127.0.0.1:\(port): \(errno)")
            close(fd); return false
        }
        guard listen(fd, 16) == 0 else {
            print("[MCPServer] listen() failed: \(errno)")
            close(fd); return false
        }

        serverFD = fd
        isRunning = true
        print("[MCPServer] Listening on http://127.0.0.1:\(port)/mcp")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { if isRunning { continue } else { break } }
            // SO_NOSIGPIPE: a client that disconnects mid-write must not raise SIGPIPE
            // and terminate the whole app — send() returns EPIPE instead.
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A client that connects and never sends must not park a global-queue
            // thread forever; 10 s is generous for a loopback JSON-RPC request.
            var rcvTimeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    // MARK: - HTTP

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let request = readHTTPRequest(fd) else { return }

        // Anti-DNS-rebinding (MCP spec requirement for local HTTP servers): loopback
        // binding alone doesn't stop a malicious web page from POSTing here, so reject
        // any request whose Origin/Host isn't local. Native MCP clients send no Origin
        // and a localhost Host, so they pass; a browser page sends its own origin.
        guard isLocalRequest(request) else {
            writeJSON(fd, status: "403 Forbidden",
                      object: ["error": "Origin/Host not allowed — Holmes MCP server is local-only"])
            return
        }

        // CORS preflight (browser-based MCP clients).
        if request.method == "OPTIONS" {
            writeRaw(fd, status: "204 No Content", headers: corsHeaders, body: Data())
            return
        }
        // We don't offer a server→client SSE stream; advertise that on GET.
        if request.method == "GET" {
            writeJSON(fd, status: "405 Method Not Allowed",
                      object: ["error": "Holmes MCP server is request/response only; POST JSON-RPC to /mcp"])
            return
        }
        guard request.method == "POST" else {
            writeJSON(fd, status: "405 Method Not Allowed", object: ["error": "use POST"])
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            writeJSON(fd, status: "400 Bad Request",
                      object: jsonrpcError(id: nil, code: -32700, message: "Parse error"))
            return
        }

        // A notification or response (no "id") gets a 202 with empty body per the transport.
        let hasID = obj["id"] != nil
        let response = dispatch(obj)
        if !hasID {
            writeRaw(fd, status: "202 Accepted", headers: corsHeaders, body: Data())
            return
        }
        writeJSON(fd, status: "200 OK", object: response, extraHeaders: ["Mcp-Session-Id": sessionID])
    }

    // MARK: - JSON-RPC dispatch

    private func dispatch(_ req: [String: Any]) -> [String: Any] {
        let id = req["id"]
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return jsonrpcResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "holmes", "version": "1.0"],
                "instructions": "Holmes sees the user's Mac screen. Call get_screen_context to know what they're looking at before answering questions about 'this' or 'here'."
            ])

        case "notifications/initialized":
            return [:] // notification — handler returns 202

        case "ping":
            return jsonrpcResult(id: id, result: [:])

        case "tools/list":
            return jsonrpcResult(id: id, result: ["tools": toolDefs])

        case "tools/call":
            return handleToolCall(id: id, params: params)

        default:
            return jsonrpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let payload: Any
        switch name {
        case "get_screen_context":   payload = provider.screenContext()
        case "get_active_app":       payload = provider.activeApp()
        case "get_upcoming_meetings": payload = ["meetings": provider.upcomingMeetings()]
        case "get_recent_activity":  payload = ["activity": provider.recentActivity()]
        default:
            return jsonrpcResult(id: id, result: [
                "content": [["type": "text", "text": "Unknown tool: \(name)"]],
                "isError": true
            ])
        }
        let text = prettyJSON(payload)
        return jsonrpcResult(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": false
        ])
    }

    // MARK: - JSON-RPC envelope helpers

    private func jsonrpcResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }
    private func jsonrpcError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return str
    }

    // MARK: - Raw socket I/O

    private struct HTTPRequest { let method: String; let path: String; let headers: [String: String]; let body: Data }

    /// Reads a full HTTP/1.1 request: headers, then Content-Length bytes of body.
    private func readHTTPRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var headerEnd: Range<Data.Index>? = nil
        var chunk = [UInt8](repeating: 0, count: 4096)

        // Read until end-of-headers.
        while headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1_048_576 { return nil } // 1MB guard
        }
        guard let he = headerEnd,
              let headerText = String(data: buffer[buffer.startIndex..<he.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        // Parse headers into a dict (lowercased keys). Safe split on the FIRST colon
        // only — a value-less header like "Content-Length:" must not crash.
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        // A negative length would skip the read loop and trap in body.prefix;
        // an absurd one would let a local client grow memory without bound.
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else { return nil }

        var body = buffer[he.upperBound...]
        while body.count < contentLength {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        return HTTPRequest(method: method, path: path, headers: headers,
                           body: Data(body.prefix(contentLength == 0 ? body.count : contentLength)))
    }

    /// Allows native MCP clients (no Origin, localhost Host) and localhost browser
    /// tooling; rejects real websites — including DNS-rebinding, where the browser
    /// still sends the attacker page's own origin.
    /// JSON-RPC requests are small; 1 MB is generous.
    private static let maxBodyBytes = 1_048_576

    private func isLocalRequest(_ r: HTTPRequest) -> Bool {
        func isLocalHostName(_ s: String) -> Bool {
            // Strip scheme + port → bare host.
            var h = s.lowercased()
            if let range = h.range(of: "://") { h = String(h[range.upperBound...]) }
            if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
            if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
            return h == "localhost" || h == "127.0.0.1" || h == "[::1]" || h == "::1" || h.isEmpty
        }
        // Host header must be local (defeats rebinding: attacker's Host is its domain).
        if let host = r.headers["host"], !isLocalHostName(host) { return false }
        // If an Origin is present it must be local. Absent is fine (native
        // clients). "null" is NOT: sandboxed iframes, file:/data: pages and
        // redirect-stripped requests all send it, and with the permissive CORS
        // reply below any website could read the user's screen text.
        if let origin = r.headers["origin"], !isLocalHostName(origin) { return false }
        return true
    }

    private var corsHeaders: [String: String] {
        ["Access-Control-Allow-Origin": "*",
         "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
         "Access-Control-Allow-Headers": "Content-Type, Mcp-Session-Id, MCP-Protocol-Version"]
    }

    private func writeJSON(_ fd: Int32, status: String, object: [String: Any], extraHeaders: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var headers = corsHeaders
        headers["Content-Type"] = "application/json"
        for (k, v) in extraHeaders { headers[k] = v }
        writeRaw(fd, status: status, headers: headers, body: body)
    }

    private func writeRaw(_ fd: Int32, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < out.count {
                let n = send(fd, base + sent, out.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - HolmesLiveContextProvider
// The real provider: reads Holmes's @MainActor singletons. Called from background socket
// threads, so it hops to the main thread (assumeIsolated is safe there).

#if !MCP_SERVER_TEST
final class HolmesLiveContextProvider: HolmesContextProviding {

    func screenContext() -> [String: Any] {
        onMain {
            let agent = HolmesAgent.shared
            let app = agent.currentContext.appName.isEmpty
                ? ScreenEngine.shared.latestActiveApp : agent.currentContext.appName
            return [
                "activeApp": app,
                "windowTitle": ScreenEngine.shared.latestActiveWindowTitle,
                "summary": agent.currentContext.description,
                "visibleText": String(agent.lastOCRText.prefix(3000)),
                // The tier ships WITH the text: `summary` hedges when Holmes is
                // down to OCR, but a remote agent reading `visibleText` next to it
                // has no way to tell garbled pixels from a literal DOM read unless
                // we say so. "inferred" means: do not quote this.
                "visibleTextConfidence": agent.lastTextConfidence.rawValue,
                "isAnalyzing": agent.isAnalyzing,
                "updatedAt": Self.iso(agent.lastUpdated)
            ]
        }
    }

    func activeApp() -> [String: Any] {
        onMain {
            ["app": ScreenEngine.shared.latestActiveApp,
             "windowTitle": ScreenEngine.shared.latestActiveWindowTitle]
        }
    }

    func upcomingMeetings() -> [[String: Any]] {
        onMain { CalendarEngine.shared.upcomingMeetings.map(Self.meetingDict) }
    }

    // Broken out + explicitly typed so the type-checker doesn't choke on a large
    // mixed-type dictionary literal inside a generic closure + .map.
    @MainActor
    private static func meetingDict(_ m: UpcomingMeeting) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["title"] = m.title
        dict["startsAt"] = iso(m.startDate)
        dict["minutesUntil"] = Int(m.minutesUntil)
        dict["timeLabel"] = m.timeLabel
        dict["type"] = m.meetingType?.rawValue ?? "Meeting"
        dict["joinURL"] = m.meetingURL?.absoluteString ?? ""
        dict["calendar"] = m.calendarName
        return dict
    }

    func recentActivity() -> [[String: Any]] {
        onMain {
            HolmesAgent.shared.recentActivities.prefix(15).map {
                ["description": $0.description, "when": $0.timeAgo]
            }
        }
    }

    // MARK: helpers

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
}
#endif
