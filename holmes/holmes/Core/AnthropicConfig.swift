import Foundation

// MARK: - AnthropicConfig
// Configuration for the ONE model Holmes uses: Claude (claude-opus-5).
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

    /// Default model for the agentic action loop. Opus 5 is a step change on
    /// exactly what Holmes does — long-horizon agentic execution and vision —
    /// at the same price as Opus 4.8. Two behaviors differ from 4.8 and both are
    /// handled in AnthropicClient: thinking is ON by default (so `maxTokens` has
    /// to leave room for it, see below), and safety classifiers can decline a
    /// request outright with stop_reason "refusal" (so the loop checks that
    /// before reading content, and opts into a server-side fallback).
    static let model = "claude-opus-5"

    static let apiVersion = "2023-06-01"
    static let messagesURL = "https://api.anthropic.com/v1/messages"

    /// Per-turn output cap — and on Opus 5 this budget covers THINKING plus the
    /// response text, not just the text. At `xhigh` effort a computer-use turn
    /// thinks hard about the frame before emitting one short tool call, so the
    /// old 8K ceiling would truncate mid-decision. 16K leaves that headroom while
    /// staying under the non-streaming request timeout.
    static let maxTokens = 16000

    /// Reasoning effort for the agentic / computer-use loop. `xhigh` is the
    /// recommended setting for coding and agentic work — it is the single
    /// highest-leverage quality knob for deciding where to click.
    static let agentEffort = "xhigh"

    /// Reasoning effort for one-shot completions (context enrichment, reply
    /// drafting, teach answers). These run often and are far less demanding than
    /// driving a UI, so they don't pay for the deepest reasoning tier.
    static let quickEffort = "medium"

    /// Token allowance handed to a full agentic run. Unlike `maxTokens` (a hard
    /// per-turn cap the model cannot see) this is a budget the model IS aware of:
    /// it paces itself against the countdown and wraps up gracefully instead of
    /// being guillotined mid-task by the iteration cap. API minimum is 20,000.
    static let agentTaskBudgetTokens = 200_000

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
