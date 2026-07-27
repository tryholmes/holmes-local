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
    /// - systemContext: the VOLATILE half of the system prompt (what's on screen
    ///   right now). Sent as a second, uncached block after `system` so the stable
    ///   half — and the tool definitions ahead of it — stay cacheable across every
    ///   turn of the loop. A 40-turn computer session re-sends that prefix 40
    ///   times, so this is where caching pays for itself.
    func runAgent(
        system: String,
        systemContext: String? = nil,
        userText: String,
        tools: [ToolDef],
        maxIterations: Int? = nil,
        betaHeaders: [String] = [],
        runTool: ToolRunner,
        onAssistantText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentOutcome {
        guard AnthropicConfig.isConfigured else { throw AgentError.notConfigured }

        // The agentic path opts into everything: cache the stable prefix, give the
        // model a budget it can pace itself against, and let a policy decline be
        // re-served by a fallback model instead of failing the run.
        let extras = Extras(cacheSystem: true,
                            taskBudgetTokens: AnthropicConfig.agentTaskBudgetTokens,
                            serverSideFallback: true)

        var messages: [[String: Any]] = [["role": "user", "content": userText]]
        var collectedText = ""
        // The most recent turn that produced any visible text — the fallback the
        // final AgentOutcome uses when the loop ends mid-tool (no terminal turn).
        var lastNonEmptyTurnText = ""
        var toolCalls = 0

        let iterationCap = maxIterations ?? AnthropicConfig.maxIterations
        for _ in 0..<iterationCap {
            let response = try await postMessage(
                system: system,
                systemContext: systemContext,
                messages: messages,
                tools: tools,
                effort: AnthropicConfig.agentEffort,
                extras: extras,
                betaHeaders: betaHeaders)

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
                // Checked BEFORE the content is used for anything: a declined turn
                // carries empty or partial content, so treating it as an answer
                // would report half-work as done. Reaching here means the fallback
                // model declined too (or fallbacks were stripped), so it is final.
                // stop_details names the policy category when the API supplies it.
                let details = (response["stop_details"] as? [String: Any]) ?? [:]
                var categoryText = ""
                if let category = details["category"] as? String, !category.isEmpty {
                    categoryText = " (\(category))"
                }
                let explanation = (details["explanation"] as? String) ?? ""
                var reason = turnText
                if reason.isEmpty { reason = explanation }
                if reason.isEmpty { reason = "The request was declined." }
                throw AgentError.refused(reason + categoryText)
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
    /// - imageBase64: an optional base64 JPEG (see VisionEncoder). Opus 5 is a
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

    /// The opt-in extras that ride on top of a plain Messages request. Kept in one
    /// place because they are ALSO what gets stripped by the fail-soft retry below.
    private struct Extras {
        /// Cache the stable half of the system prompt (with the tool definitions).
        var cacheSystem = false
        /// Model-visible token allowance for a whole agentic run.
        var taskBudgetTokens: Int? = nil
        /// Re-serve a policy-declined request on a fallback model, server-side.
        var serverSideFallback = false
    }

    private func postMessage(system: String,
                             systemContext: String? = nil,
                             messages: [[String: Any]],
                             tools: [ToolDef],
                             maxTokens: Int? = nil,
                             effort: String = AnthropicConfig.quickEffort,
                             outputFormat: [String: Any]? = nil,
                             extras: Extras = Extras(),
                             betaHeaders: [String] = []) async throws -> [String: Any] {
        do {
            return try await send(system: system, systemContext: systemContext, messages: messages,
                                  tools: tools, maxTokens: maxTokens, effort: effort,
                                  outputFormat: outputFormat, extras: extras, betaHeaders: betaHeaders)
        } catch let AgentError.http(status, message) where status == 400 && Self.isExperimentalRejection(message) {
            // FAIL SOFT. Prompt caching, task budgets, and server-side fallbacks are
            // opt-in extras; a single unrecognized one must not take the whole app
            // down. Retry once with every extra stripped so Holmes keeps working
            // (slower and pricier) instead of failing every request outright.
            print("[Holmes] Anthropic rejected an optional feature — retrying without it: \(message)")
            return try await send(system: system, systemContext: systemContext, messages: messages,
                                  tools: tools, maxTokens: maxTokens, effort: effort,
                                  outputFormat: outputFormat, extras: Extras(), betaHeaders: betaHeaders)
        }
    }

    /// True when a 400 blames one of the opt-in extras rather than the request's
    /// actual content — the only case worth retrying without them.
    private static func isExperimentalRejection(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("fallback") || m.contains("task_budget") || m.contains("task budget")
            || m.contains("cache_control") || m.contains("effort") || m.contains("beta")
    }

    private func send(system: String,
                      systemContext: String?,
                      messages: [[String: Any]],
                      tools: [ToolDef],
                      maxTokens: Int?,
                      effort: String,
                      outputFormat: [String: Any]?,
                      extras: Extras,
                      betaHeaders: [String]) async throws -> [String: Any] {
        guard let key = AnthropicConfig.apiKey else { throw AgentError.notConfigured }
        guard let url = URL(string: AnthropicConfig.messagesURL) else { throw AgentError.transport("bad url") }

        var body: [String: Any] = [
            "model": AnthropicConfig.model,
            "max_tokens": maxTokens ?? AnthropicConfig.maxTokens,
            "messages": messages,
            // Adaptive thinking: the model decides when/how much to think. The only
            // accepted on-mode (budget_tokens is rejected); on Opus 5 it is also
            // what you get by omitting the field, so this is explicit, not a change.
            "thinking": ["type": "adaptive"]
        ]

        // SYSTEM AS CONTENT BLOCKS, stable half first.
        //
        // Render order is tools → system → messages, and caching is a PREFIX
        // match: a breakpoint on the last stable system block caches the tool
        // definitions along with it. That only works if the bytes ahead of the
        // breakpoint never change — which is why the per-turn screen context is a
        // SECOND, uncached block after it. (Holmes used to put that volatile
        // context first, which changed the prefix every single turn and made
        // caching impossible.)
        if extras.cacheSystem || systemContext?.isEmpty == false {
            var stable: [String: Any] = ["type": "text", "text": system]
            if extras.cacheSystem { stable["cache_control"] = ["type": "ephemeral"] }
            var blocks: [[String: Any]] = [stable]
            if let systemContext, !systemContext.isEmpty {
                blocks.append(["type": "text", "text": systemContext])
            }
            body["system"] = blocks
        } else {
            body["system"] = system
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { $0.apiDict }
        }

        // output_config carries three things: reasoning effort, the optional
        // structured-output format, and the optional task budget. Never send
        // temperature/top_p/top_k alongside — the model 400s on all three.
        var outputConfig: [String: Any] = ["effort": effort]
        if let outputFormat { outputConfig["format"] = outputFormat }
        if let budget = extras.taskBudgetTokens {
            outputConfig["task_budget"] = ["type": "tokens", "total": budget]
        }
        body["output_config"] = outputConfig

        // A safety classifier can decline a request outright (HTTP 200 +
        // stop_reason "refusal"). Benign work adjacent to a sensitive topic
        // occasionally trips one, so let the API re-serve the SAME request on a
        // fallback model inside this call rather than surfacing "task failed".
        if extras.serverSideFallback {
            body["fallbacks"] = "default"
        }

        var betas = betaHeaders
        if extras.serverSideFallback { betas.append("server-side-fallback-2026-07-01") }
        if extras.taskBudgetTokens != nil { betas.append("task-budgets-2026-03-13") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Generous: at high effort a single turn can spend a while thinking about
        // a dense screen before it emits one short tool call.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Beta opt-ins (e.g. "computer-use-2025-11-24" for the native computer
        // tool). Comma-joined per the Anthropic wire format; omitted when empty.
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
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
