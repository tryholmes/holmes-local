import Foundation

// MARK: - AnthropicClient
// Minimal Claude Messages API client + agentic tool-use loop, implemented over
// URLSession (Swift has no official Anthropic SDK, so this is the raw-HTTP path).
//
// Design notes:
//  • Messages are kept as raw [String: Any] dictionaries so that assistant
//    `content` blocks (text, thinking, tool_use) round-trip back to the API
//    BYTE-FOR-BYTE. Adaptive thinking returns signed `thinking` blocks that the
//    API rejects if modified — passing the response `content` array straight back
//    is the robust way to satisfy that.
//  • Non-streaming: tool-loop turns are short, and 8K max_tokens stays well under
//    the request timeout. Streaming can be layered on later if needed.

actor AnthropicClient {
    static let shared = AnthropicClient()
    private init() {}

    // A tool the model can call. `inputSchema` is a JSON-Schema object dict.
    struct ToolDef {
        let name: String
        let description: String
        let inputSchema: [String: Any]

        var apiDict: [String: Any] {
            ["name": name, "description": description, "input_schema": inputSchema]
        }
    }

    // Result of executing one tool call. `isError: true` tells the model the call failed.
    struct ToolResult {
        let text: String
        let isError: Bool
        init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
    }

    // Runs a tool the model requested. Implemented by the caller (HolmesBrain).
    typealias ToolRunner = (_ name: String, _ input: [String: Any]) async -> ToolResult

    enum AgentError: Error { case notConfigured, http(Int, String), transport(String), refused(String) }

    struct AgentOutcome {
        let finalText: String
        let stopReason: String
        let toolCallCount: Int
    }

    // MARK: - Agentic loop

    /// Runs model → tool → result → model until the model stops asking for tools.
    /// - onAssistantText: called with each turn's visible text (for live UI logging).
    func runAgent(
        system: String,
        userText: String,
        tools: [ToolDef],
        runTool: ToolRunner,
        onAssistantText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentOutcome {
        guard AnthropicConfig.isConfigured else { throw AgentError.notConfigured }

        var messages: [[String: Any]] = [["role": "user", "content": userText]]
        var collectedText = ""
        var toolCalls = 0

        for _ in 0..<AnthropicConfig.maxIterations {
            let response = try await postMessage(system: system, messages: messages, tools: tools)

            let stop = response["stop_reason"] as? String ?? "end_turn"
            let content = response["content"] as? [[String: Any]] ?? []

            // Visible text from this turn.
            let turnText = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if !turnText.isEmpty {
                collectedText += (collectedText.isEmpty ? "" : "\n") + turnText
                onAssistantText(turnText)
            }

            if stop == "refusal" {
                throw AgentError.refused(turnText.isEmpty ? "Request was declined." : turnText)
            }

            guard stop == "tool_use" || stop == "pause_turn" else {
                // end_turn / max_tokens / stop_sequence → done.
                return AgentOutcome(finalText: collectedText, stopReason: stop, toolCallCount: toolCalls)
            }

            // Echo assistant content back VERBATIM (preserves thinking + tool_use blocks).
            messages.append(["role": "assistant", "content": content])

            if stop == "pause_turn" {
                // Server-side pause; re-send to continue (no new user content).
                continue
            }

            // Execute every tool_use block, collect results into one user turn.
            var toolResults: [[String: Any]] = []
            for block in content where (block["type"] as? String) == "tool_use" {
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                toolCalls += 1
                let result = await runTool(name, input)
                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": result.text,
                    "is_error": result.isError
                ])
            }
            messages.append(["role": "user", "content": toolResults])
        }

        return AgentOutcome(finalText: collectedText, stopReason: "max_iterations", toolCallCount: toolCalls)
    }

    // MARK: - Single request

    private func postMessage(system: String, messages: [[String: Any]], tools: [ToolDef]) async throws -> [String: Any] {
        guard let key = AnthropicConfig.apiKey else { throw AgentError.notConfigured }
        guard let url = URL(string: AnthropicConfig.messagesURL) else { throw AgentError.transport("bad url") }

        var body: [String: Any] = [
            "model": AnthropicConfig.model,
            "max_tokens": AnthropicConfig.maxTokens,
            "system": system,
            "messages": messages,
            // Adaptive thinking: the model decides when/how much to think. Required
            // form on Opus 4.8 (budget_tokens is rejected).
            "thinking": ["type": "adaptive"]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.apiDict }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AgentError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.http(status, "non-JSON response")
        }

        guard (200..<300).contains(status) else {
            // Anthropic error envelope: {"type":"error","error":{"type","message"}}
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw AgentError.http(status, message)
        }
        return json
    }
}
