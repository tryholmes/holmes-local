import Foundation
import AppKit

// MARK: - BrowserBridge
// Listens on localhost:5766 using raw BSD sockets (no entitlements needed).
// The Holmes browser extension POSTs JSON context here every 3 seconds.

@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()
    private let port: UInt16 = 5766
    private var serverFD: Int32 = -1

    var onContext: ((BrowserContext) -> Void)?

    private init() {}

    func start() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.runServer()
        }
    }

    private func runServer() {
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            print("[Bridge] socket() failed: \(errno)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[Bridge] bind() failed on port \(port): \(errno)")
            return
        }

        guard listen(serverFD, 10) == 0 else {
            print("[Bridge] listen() failed: \(errno)")
            return
        }

        print("[Bridge] Listening on localhost:\(port)")

        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { return }

        let raw = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""

        // CORS preflight
        if raw.hasPrefix("OPTIONS") {
            let response = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\n\r\n"
            response.withCString { send(fd, $0, strlen($0), 0) }
            return
        }

        // Extract JSON from POST body
        guard let bodyRange = raw.range(of: "\r\n\r\n") else { return }
        let jsonStr = String(raw[bodyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsonStr.isEmpty,
              let jsonData = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            let r = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            r.withCString { send(fd, $0, strlen($0), 0) }
            return
        }

        let ctx = BrowserContext(
            type: obj["type"] as? String ?? "unknown",
            recipient: obj["recipient"] as? String ?? "",
            subject: obj["subject"] as? String ?? "",
            body: obj["body"] as? String ?? "",
            sender: obj["sender"] as? String ?? "",
            url: obj["url"] as? String ?? "",
            title: obj["title"] as? String ?? ""
        )

        print("[Bridge] \(ctx.type) — \(ctx.subject.prefix(50))")

        let ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 10\r\n\r\n{\"ok\":true}"
        ok.withCString { send(fd, $0, strlen($0), 0) }

        Task { @MainActor in
            self.onContext?(ctx)
        }
    }
}

// MARK: - BrowserContext

struct BrowserContext {
    let type: String
    let recipient: String
    let subject: String
    let body: String
    let sender: String
    let url: String
    let title: String

    var ocrText: String {
        switch type {
        case "gmail_compose":
            return "New Message\n\(recipient)\nSubject\n\(subject)\n\(body)"
        case "gmail_read":
            return "From: \(sender)\nSubject: \(subject)\n\(body)"
        default:
            return title
        }
    }

    var appDescription: String {
        switch type {
        case "gmail_compose":
            let to = recipient.isEmpty ? "" : " to \(recipient)"
            let sub = subject.isEmpty ? "" : " — \"\(subject)\""
            return "Composing email\(to)\(sub)"
        case "gmail_read":
            return sender.isEmpty ? "Reading email" : "Reading email from \(sender)"
        default:
            return "Gmail"
        }
    }
}
