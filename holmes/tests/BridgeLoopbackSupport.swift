import Foundation

// A tiny blocking HTTP/1.1 client over real loopback sockets. Used by the bridge
// socket tests and the soak test so they exercise the production BridgeServer
// parser, auth, long poll and body limits exactly as the extension does.

struct LoopbackResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
    var json: Any? { try? JSONSerialization.jsonObject(with: body) }
}

enum LoopbackHTTP {
    /// Sends one request and reads the whole response. Returns nil on a connection
    /// failure (refused, reset before any response, timeout).
    static func request(port: UInt16, method: String, path: String, headers: [String: String] = [:],
                        body: Data = Data(), timeout: TimeInterval = 10) -> LoopbackResponse? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n"
        var allHeaders = headers
        if method != "GET" || !body.isEmpty { allHeaders["Content-Length"] = "\(body.count)" }
        for (key, value) in allHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        let sentAll = out.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var sent = 0
            while sent < out.count {
                let n = send(fd, base + sent, out.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        _ = sentAll  // a server that answers 413 early may stop reading; still read its reply
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: buffer[buffer.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return LoopbackResponse(status: status, headers: parsed, body: Data(buffer[split.upperBound...]))
    }

    /// Runs a blocking closure on a background thread and awaits it without
    /// occupying the main actor.
    static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

/// A lock protected box for values written from background threads.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
