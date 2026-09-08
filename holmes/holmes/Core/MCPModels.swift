import Foundation

// MARK: - MCP models + config
// Holmes acts as an MCP *host*: it launches/connects MCP servers and exposes their
// tools to the local model's action loop. Config uses the same shape as Claude Desktop so
// users can paste an existing `mcpServers` block. Two transports are supported:
//   • stdio  — a local subprocess (e.g. `npx <gmail server>`). Auth is the server's job.
//   • http   — a remote Streamable-HTTP endpoint (e.g. a hosted Gmail MCP), with
//              optional headers / bearer token.
//
// Config search order (first found wins):
//   1. ~/Library/Application Support/Holmes/mcp.json
//   2. ~/.holmes/mcp.json
//
// Example mcp.json:
// {
//   "mcpServers": {
//     "gmail":  { "command": "npx", "args": ["-y", "@gongrzhe/server-gmail-autoauth-mcp"] },
//     "remote": { "url": "https://mcp.example.com/mcp", "bearerToken": "sk-..." }
//   }
// }

struct MCPServerConfig {
    enum Transport {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
    }
    let name: String
    let transport: Transport
}

// One tool advertised by a connected server, namespaced for the model.
struct MCPTool {
    let serverName: String
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// MCP `annotations.readOnlyHint` — if true the call has no side effects and can
    /// run without user approval.
    let readOnly: Bool

    /// Tool name exposed to the model: "<server>__<tool>". Kept to ^[a-zA-Z0-9_-]{1,64}$ so names stay stable and safe for any backend.
    var namespacedName: String {
        let raw = "\(serverName)__\(name)"
        let mapped = raw.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "-" ? ch : "_"
        }
        let s = String(mapped)
        return s.count <= 64 ? s : String(s.prefix(64))
    }

    var toolDef: OllamaClient.ToolDef {
        OllamaClient.ToolDef(
            name: namespacedName,
            description: description.isEmpty ? "\(name) (via \(serverName) MCP server)" : description,
            inputSchema: inputSchema.isEmpty ? ["type": "object", "properties": [:]] : inputSchema
        )
    }
}

// MARK: - Shared MCP protocol bits (used by both transports)

enum MCPProtocol {
    static let version = "2024-11-05"

    static func initializeParams() -> [String: Any] {
        ["protocolVersion": version,
         "capabilities": [:],
         "clientInfo": ["name": "Holmes", "version": "1.0"]]
    }

    static func parseTool(_ dict: [String: Any], serverName: String) -> MCPTool? {
        guard let name = dict["name"] as? String else { return nil }
        let annotations = dict["annotations"] as? [String: Any]
        return MCPTool(
            serverName: serverName,
            name: name,
            description: dict["description"] as? String ?? "",
            inputSchema: dict["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]],
            readOnly: (annotations?["readOnlyHint"] as? Bool) ?? false
        )
    }

    /// Extracts a `tools/call` result dict into a flat text ToolResult.
    static func toolResult(from result: [String: Any]) -> OllamaClient.ToolResult {
        let isError = result["isError"] as? Bool ?? false
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":
                return block["text"] as? String
            case "resource":
                let r = block["resource"] as? [String: Any]
                return (r?["text"] as? String) ?? (r?["uri"] as? String)
            default:
                return nil
            }
        }.joined(separator: "\n")
        return OllamaClient.ToolResult(text.isEmpty ? "(no output)" : text, isError: isError)
    }
}

// MARK: - Config loader

enum MCPConfigLoader {
    static func load() -> [MCPServerConfig] {
        guard let url = configFileURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return [] }

        var result: [MCPServerConfig] = []
        for (name, value) in servers {
            guard let dict = value as? [String: Any] else { continue }

            // Remote HTTP server: { "url": "...", "headers": {...}, "bearerToken": "..." }
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                var headers = dict["headers"] as? [String: String] ?? [:]
                if let token = (dict["bearerToken"] as? String) ?? (dict["token"] as? String), !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                result.append(MCPServerConfig(name: name, transport: .http(url: url, headers: headers)))
                continue
            }

            // Local stdio server: { "command": "npx", "args": [...], "env": {...} }
            if let command = dict["command"] as? String, !command.isEmpty {
                let args = dict["args"] as? [String] ?? []
                let env = dict["env"] as? [String: String] ?? [:]
                result.append(MCPServerConfig(name: name, transport: .stdio(command: command, args: args, env: env)))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func configFileURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Holmes/mcp.json"),
            home.appendingPathComponent(".holmes/mcp.json")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
