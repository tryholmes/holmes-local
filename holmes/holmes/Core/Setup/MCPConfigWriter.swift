import Foundation

// MARK: - MCPConfigWriter
// The one place Holmes WRITES mcp.json. Reads use MCPConfigLoader; this keeps
// the file's shape identical to what the loader and the holmes-sdk CLI expect,
// merges one server entry at a time, and never clobbers entries it did not
// touch. Writes go to whichever config file the loader would read first, so a
// user with an existing ~/.holmes/mcp.json keeps using it.

enum MCPConfigWriter {

    static var targetURL: URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support/Holmes/mcp.json")
        let legacy = home.appendingPathComponent(".holmes/mcp.json")
        if fm.fileExists(atPath: appSupport.path) { return appSupport }
        if fm.fileExists(atPath: legacy.path) { return legacy }
        return appSupport
    }

    private static func readAll() -> [String: Any] {
        guard let data = try? Data(contentsOf: targetURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["mcpServers": [String: Any]()]
        }
        var doc = json
        if doc["mcpServers"] as? [String: Any] == nil { doc["mcpServers"] = [String: Any]() }
        return doc
    }

    private static func write(_ doc: [String: Any]) throws {
        let url = targetURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        // The file can hold API keys: user-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func server(named name: String) -> [String: Any]? {
        (readAll()["mcpServers"] as? [String: Any])?[name] as? [String: Any]
    }

    static func setServer(_ name: String, entry: [String: Any]) throws {
        var doc = readAll()
        var servers = doc["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = entry
        doc["mcpServers"] = servers
        try write(doc)
    }

    static func removeServer(_ name: String) throws {
        var doc = readAll()
        var servers = doc["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: name)
        doc["mcpServers"] = servers
        try write(doc)
    }

    // MARK: Composio

    /// Composio's hosted MCP. The entry MUST be named "composio": the playbook
    /// tool policy honours the meta executor only from that server name.
    static let composioName = "composio"

    enum ComposioError: LocalizedError {
        case badURL
        var errorDescription: String? { "That does not look like a Composio MCP URL. Copy the Streamable HTTP URL from the Composio dashboard (https://backend.composio.dev/v3/mcp/…)." }
    }

    static func setComposio(url rawURL: String, apiKey: String) throws {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { throw ComposioError.badURL }
        var entry: [String: Any] = ["url": url.absoluteString]
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { entry["headers"] = ["x-api-key": key] }
        try setServer(composioName, entry: entry)
    }

    static var composioEntry: (url: String, apiKey: String)? {
        guard let e = server(named: composioName), let url = e["url"] as? String else { return nil }
        let key = (e["headers"] as? [String: String])?["x-api-key"] ?? ""
        return (url, key)
    }
}
