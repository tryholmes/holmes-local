import Foundation

// MARK: - AnthropicConfig
// Configuration for the ONE model Holmes uses: Claude (claude-opus-4-8).
//   • Perception is model-free — LiveContext computes the headline deterministically
//     from DOM/Accessibility data, so nothing Holmes claims to see comes from a model.
//   • Claude runs the multi-step tool-calling loop that takes actions, and enriches
//     an already-correct context with goal/intent behind the headline.
// Without a key Holmes degrades honestly (it says the key is missing); there is no
// local-model fallback.
//
// The API key lives in the Keychain (never on disk / never in source). Holmes only
// reaches the network here when the user explicitly invokes an action that needs it.

enum AnthropicConfig {
    /// Keychain service + account for the Anthropic API key.
    static let keychainService = "com.grain.holmes.anthropic"
    static let apiKeyAccount   = "anthropic_api_key"

    /// Default model for the agentic action loop. Opus 4.8 is the most capable
    /// model for long-horizon, tool-heavy work. Override per-install if desired.
    static let model = "claude-opus-4-8"

    static let apiVersion = "2023-06-01"
    static let messagesURL = "https://api.anthropic.com/v1/messages"

    /// Per-turn output cap. Tool-loop turns are short; 8K keeps non-streaming
    /// requests comfortably under URLSession timeouts.
    static let maxTokens = 8000

    /// Safety bound on the agentic loop (model → tool → result → model …).
    static let maxIterations = 10

    static var apiKey: String? {
        if let key = KeychainManager.load(service: keychainService, account: apiKeyAccount),
           !key.isEmpty {
            return key
        }
        // Fallback: a plain-text key file, mirroring the mcp.json convention. Lets the
        // user enable Claude without a settings UI. Migrated into the Keychain on read.
        if let fileKey = keyFromFile() {
            setAPIKey(fileKey)
            return fileKey
        }
        return nil
    }

    private static func keyFromFile() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Holmes/anthropic_key"),
            home.appendingPathComponent(".holmes/anthropic_key")
        ]
        for url in candidates {
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { return key }
            }
        }
        return nil
    }

    static var isConfigured: Bool { apiKey != nil }

    static func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainManager.delete(service: keychainService, account: apiKeyAccount)
        } else {
            KeychainManager.save(trimmed, service: keychainService, account: apiKeyAccount)
        }
    }
}
