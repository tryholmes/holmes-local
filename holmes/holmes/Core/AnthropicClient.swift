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
        /// When set, the tool is serialized to the API from this dict VERBATIM
        /// instead of the name/description/input_schema shape. Native server tools
        /// (e.g. `{"type":"computer_20251124","name":"computer",…}`) have no
        /// input_schema and MUST be sent as-is; default nil keeps every existing
        /// custom-tool caller unchanged.
        var rawAPIDict: [String: Any]? = nil

        var apiDict: [String: Any] {
            rawAPIDict ?? ["name": name, "description": description, "input_schema": inputSchema]
        }
    }

    // Result of executing one tool call. `isError: true` tells the model the call failed.
    struct ToolResult {
        let text: String
        let isError: Bool
        /// An optional base64 JPEG returned to the model as an IMAGE content block
        /// alongside `text` (the `screenshot` computer action needs this — the
        /// model has to see the frame to reason about the next click). Default nil
        /// preserves the plain-string tool_result for every other tool.
        let imageBase64: String?
        init(_ text: String, isError: Bool = false, imageBase64: String? = nil) {
            self.text = text
            self.isError = isError
            self.imageBase64 = imageBase64
        }
    }

    // Runs a tool the model requested. Implemented by the caller (HolmesBrain).
    typealias ToolRunner = (_ name: String, _ input: [String: Any]) async -> ToolResult

    enum AgentError: Error { case notConfigured, http(Int, String), transport(String), refused(String) }

    struct AgentOutcome {
        /// Every turn's visible text concatenated — the full running transcript,
        /// including the model's between-tool narration. The user-initiated loop
        /// wants this (it's a live activity log); a DELIVERABLE never does.
        let finalText: String
        /// The visible text of ONLY the final turn — the turn whose stop_reason is
        /// terminal (end_turn / max_tokens / stop_sequence), not tool_use/pause_turn.
        /// This is the actual answer, with none of the "let me search…/now let me…"
        /// narration that accumulates in finalText. When the loop instead exhausts
        /// its iteration budget mid-tool (no terminal turn), this falls back to the
        /// last turn that produced any text. A playbook draft is a deliverable, so
        /// playbooks read THIS, not finalText.
        let lastTurnText: String
        let stopReason: String
        let toolCallCount: Int
    }

    // MARK: - Agentic loop

    /// Runs model → tool → result → model until the model stops asking for tools.
    /// - onAssistantText: called with each turn's visible text (for live UI logging).
    /// - maxIterations: override for the outer turn cap (defaults to
    ///   AnthropicConfig.maxIterations). Playbooks that should finish fast pass a
    ///   lower value so the loop can't wander.
    func runAgent(
        system: String,
        userText: String,
        tools: [ToolDef],
        maxIterations: Int? = nil,
        betaHeaders: [String] = [],
        runTool: ToolRunner,
        onAssistantText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentOutcome {
        guard AnthropicConfig.isConfigured else { throw AgentError.notConfigured }

        var messages: [[String: Any]] = [["role": "user", "content": userText]]
        var collectedText = ""
        // The most recent turn that produced any visible text — the fallback the
        // final AgentOutcome uses when the loop ends mid-tool (no terminal turn).
        var lastNonEmptyTurnText = ""
        var toolCalls = 0

        let iterationCap = maxIterations ?? AnthropicConfig.maxIterations
        for _ in 0..<iterationCap {
            let response = try await postMessage(system: system, messages: messages, tools: tools, betaHeaders: betaHeaders)

            let stop = response["stop_reason"] as? String ?? "end_turn"
            let content = response["content"] as? [[String: Any]] ?? []

            // Visible text from this turn.
            let turnText = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if !turnText.isEmpty {
                collectedText += (collectedText.isEmpty ? "" : "\n") + turnText
                lastNonEmptyTurnText = turnText
                onAssistantText(turnText)
            }

            if stop == "refusal" {
                throw AgentError.refused(turnText.isEmpty ? "Request was declined." : turnText)
            }

            guard stop == "tool_use" || stop == "pause_turn" else {
                // end_turn / max_tokens / stop_sequence → done. The deliverable is
                // THIS terminal turn's text (falling back to the last turn that had
                // text, in the rare case the terminal turn was text-free).
                return AgentOutcome(
                    finalText: collectedText,
                    lastTurnText: turnText.isEmpty ? lastNonEmptyTurnText : turnText,
                    stopReason: stop,
                    toolCallCount: toolCalls)
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
                // A screenshot (or any image-bearing) result becomes an image +
                // text block array; everything else stays a bare string. The image
                // block shape matches the one `complete()` already sends.
                let toolResultContent: Any
                if let img = result.imageBase64 {
                    toolResultContent = [
                        ["type": "image",
                         "source": ["type": "base64", "media_type": "image/jpeg", "data": img]],
                        ["type": "text", "text": result.text]
                    ]
                } else {
                    toolResultContent = result.text
                }
                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": toolResultContent,
                    "is_error": result.isError
                ])
            }
            messages.append(["role": "user", "content": toolResults])
        }

        // Iteration budget exhausted with no terminal turn — the model ended on a
        // tool call. There is no "final turn" deliverable; hand back the last turn
        // that produced text so a caller can still recover something usable.
        return AgentOutcome(
            finalText: collectedText,
            lastTurnText: lastNonEmptyTurnText,
            stopReason: "max_iterations",
            toolCallCount: toolCalls)
    }

    // MARK: - One-shot completion (no tools)

    /// A single non-tool request — the path every "think about this text and
    /// answer" caller uses (ReplyComposer, TriggerBrain's ambiguity check,
    /// HolmesAgent's context enrichment).
    ///
    /// - asJSON: constrain the reply to one JSON object. This is enforced by the
    ///   API through `output_config.format`, not by asking the model nicely —
    ///   structured outputs are schema-driven, so pass `schema` whenever the
    ///   caller knows the shape it wants (build one with `objectSchema`).
    /// - schema: a JSON-Schema object. Structured outputs require
    ///   `additionalProperties: false` plus an explicit `required` list, so every
    ///   key the model may return has to be declared up front. When asJSON is
    ///   true and no schema is supplied there is nothing for the API to constrain
    ///   against, so the request falls back to a one-line format instruction —
    ///   the degenerate path, kept only so a schema-less caller still works.
    /// - imageBase64: an optional base64 JPEG (see VisionEncoder). Opus 4.8 is a
    ///   vision model, so a screen whose text came back too thin to describe can
    ///   still be reasoned about from the pixels.
    func complete(system: String,
                  user: String,
                  maxTokens: Int = 1024,
                  asJSON: Bool = false,
                  schema: [String: Any]? = nil,
                  imageBase64: String? = nil) async throws -> String {
        var systemPrompt = system
        var outputFormat: [String: Any]? = nil
        if asJSON {
            if let schema {
                outputFormat = ["type": "json_schema", "schema": schema]
            } else {
                systemPrompt += "\n\nReply with a single JSON object and nothing else — no prose, no code fences."
            }
        }

        // The image goes BEFORE the text, which is the documented ordering for
        // "look at this, then answer this".
        let userContent: Any
        if let imageBase64 {
            userContent = [
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/jpeg", "data": imageBase64]],
                ["type": "text", "text": user]
            ]
        } else {
            userContent = user
        }

        let response = try await postMessage(
            system: systemPrompt,
            messages: [["role": "user", "content": userContent]],
            tools: [],
            maxTokens: maxTokens,
            outputFormat: outputFormat
        )

        let blocks = response["content"] as? [[String: Any]] ?? []
        // Only `text` blocks — a response may lead with a signed `thinking` block,
        // and concatenating that into the payload would break every JSON parse.
        return blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a strict JSON-Schema object literal for `complete(asJSON:schema:)`.
    /// Every declared property is required by default: structured outputs reject
    /// unlisted keys, and an optional key the model omits is indistinguishable
    /// from a key it forgot, so Holmes always asks for the full set.
    nonisolated static func objectSchema(_ properties: [String: [String: Any]],
                                         required: [String]? = nil) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required ?? properties.keys.sorted(),
            "additionalProperties": false
        ]
    }

    // MARK: - Single request

    private func postMessage(system: String,
                             messages: [[String: Any]],
                             tools: [ToolDef],
                             maxTokens: Int? = nil,
                             outputFormat: [String: Any]? = nil,
                             betaHeaders: [String] = []) async throws -> [String: Any] {
        guard let key = AnthropicConfig.apiKey else { throw AgentError.notConfigured }
        guard let url = URL(string: AnthropicConfig.messagesURL) else { throw AgentError.transport("bad url") }

        var body: [String: Any] = [
            "model": AnthropicConfig.model,
            "max_tokens": maxTokens ?? AnthropicConfig.maxTokens,
            "system": system,
            "messages": messages,
            // Adaptive thinking: the model decides when/how much to think. Required
            // form on Opus 4.8 (budget_tokens is rejected).
            "thinking": ["type": "adaptive"]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.apiDict }
        }
        // Structured outputs live under output_config.format. Never send
        // temperature/top_p/top_k alongside it — Opus 4.8 400s on all three.
        if let outputFormat {
            body["output_config"] = ["format": outputFormat]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Beta opt-ins (e.g. "computer-use-2025-11-24" for the native computer
        // tool). Comma-joined per the Anthropic wire format; omitted when empty.
        if !betaHeaders.isEmpty {
            request.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
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
