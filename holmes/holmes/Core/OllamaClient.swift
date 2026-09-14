import Foundation

// MARK: - OllamaClient
// Minimal Ollama /api/chat client + agentic tool-use loop over URLSession.
// It is the drop-in replacement for the hosted-model client Holmes used to have:
// the same nested types (ToolDef, ToolResult, AgentOutcome, AgentError) and the
// same two entry points (runAgent / complete), so every caller changes only the
// type name.
//
// Design notes — everything here is shaped by how a LOCAL model differs from a
// hosted one:
//  • ONE request at a time. There is one GPU. Concurrent callers (context
//    enrichment, trigger checks, a 40-turn computer session) are serialized by
//    a gate; agent turns take priority, and background completions are dropped
//    with `.busy` instead of queueing forever behind a long session.
//  • ONE context size. Changing `num_ctx` between requests reloads the model
//    (20 s+), so every request sends OllamaConfig.numCtx.
//  • Images ride on USER messages. Ollama renderers disagree about images on
//    `tool` messages (qwen3.5 ignores them), so a screenshot returned by a tool
//    is sent as a follow-up user message, and only the newest few are kept —
//    each frame costs ~1-2k tokens of a 16k window.
//  • `format` (JSON schema) is NEVER sent together with `tools` — Ollama forces
//    the tool arguments into the schema shape when both are present.
//  • Schema descriptions are invisible to the model (Ollama compiles the schema
//    to a grammar), so `complete(asJSON:schema:)` restates the fields in the
//    prompt.
//  • Thinking is off unless the user opts in: on a laptop a thinking model
//    spends minutes per step. `think` is only sent to models that advertise it
//    (a 400 otherwise).
//  • Streaming NDJSON: Ollama sends nothing until generation starts, and a cold
//    load plus a screenshot prompt can take a couple of minutes on a laptop.
//    Streaming keeps bytes flowing once it does, and lets us read mid-stream
//    `{"error": …}` objects, which arrive with HTTP 200 already sent.

actor OllamaClient {
    static let shared = OllamaClient()
    private init() {}

    // MARK: - Public types (unchanged shape for callers)

    /// A tool the model can call. `inputSchema` is a JSON-Schema object dict.
    struct ToolDef {
        let name: String
        let description: String
        let inputSchema: [String: Any]

        var apiDict: [String: Any] {
            var params = inputSchema
            if params["type"] == nil { params["type"] = "object" }
            if params["properties"] == nil { params["properties"] = [String: Any]() }
            return ["type": "function",
                    "function": ["name": name, "description": description, "parameters": params]]
        }
    }

    /// Result of executing one tool call. `isError: true` tells the model the call failed.
    struct ToolResult {
        let text: String
        let isError: Bool
        /// An optional base64 JPEG the model must SEE (screenshot / zoom). It is
        /// delivered as a follow-up user message with `images`, see runAgent.
        let imageBase64: String?
        init(_ text: String, isError: Bool = false, imageBase64: String? = nil) {
            self.text = text
            self.isError = isError
            self.imageBase64 = imageBase64
        }
    }

    /// Runs a tool the model requested. Implemented by the caller (HolmesBrain).
    typealias ToolRunner = (_ name: String, _ input: [String: Any]) async -> ToolResult

    enum AgentError: Error, LocalizedError {
        /// Server unreachable or model not pulled (per OllamaConfig.isConfigured).
        case notConfigured
        /// Connection refused / dropped: the server is not running (or died).
        case serverUnreachable(String)
        /// 404 from the server: the model tag is not pulled.
        case modelMissing(String)
        /// 400 "<model> does not support tools/thinking/…".
        case unsupported(String)
        case http(Int, String)
        case transport(String)
        /// Generation hit `num_predict` before producing anything usable.
        case truncated
        /// Dropped: too many background requests already waiting on the GPU.
        case busy
        /// Kept for API parity (a hosted model can decline); never thrown here.
        case refused(String)
        /// No response in time, or the stream went silent mid answer. The
        /// request is safe to try again once the server answers.
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:            return OllamaConfig.notReadyMessage
            case .serverUnreachable(let m): return "Ollama server unreachable (\(m))"
            case .modelMissing(let m):      return "Model \(m) is not pulled — pull it in Holmes ▸ Settings ▸ Local Model"
            case .unsupported(let m):       return m
            case .http(let c, let m):       return "Ollama HTTP \(c): \(m)"
            case .transport(let m):         return "Ollama request failed: \(m)"
            case .truncated:                return "The model ran out of output tokens before answering"
            case .busy:                     return "The local model is busy"
            case .refused(let m):           return m
            case .timedOut(let m):          return "The local model stopped responding (\(m)). Holmes is rechecking the Ollama server; try again in a moment."
            }
        }
    }

    struct AgentOutcome {
        /// Every turn's visible text concatenated — the full running transcript.
        let finalText: String
        /// The visible text of ONLY the final (tool-free) turn — the deliverable.
        /// Falls back to the last turn that produced text when the loop ended
        /// on a tool call.
        let lastTurnText: String
        /// "end_turn" | "max_tokens" | "max_iterations"
        let stopReason: String
        let toolCallCount: Int
    }

    /// Who is asking. Agent turns jump the queue; background enrichment waits
    /// and is dropped (`.busy`) when the queue is already deep.
    enum Priority { case agent, background }

    // MARK: - Model capabilities (cached /api/show)

    struct Capabilities {
        let tools: Bool
        let vision: Bool
        let thinking: Bool
    }
    private var capabilityCache: [String: Capabilities] = [:]
    private var capabilityGeneration = 0

    func capabilities(for model: String) async throws -> Capabilities {
        let host = OllamaConfig.host
        let key = "\(host)\n\(model)"
        let generation = capabilityGeneration
        if let cached = capabilityCache[key] { return cached }
        let json = try await request(path: "/api/show", body: ["model": model], timeout: 30)
        // An old server's response cannot populate the new configuration's
        // cache after the user changes host/model while /api/show is in flight.
        guard generation == capabilityGeneration, host == OllamaConfig.host else {
            throw CancellationError()
        }
        let caps = Set((json["capabilities"] as? [String]) ?? [])
        let c = Capabilities(tools: caps.contains("tools"),
                             vision: caps.contains("vision"),
                             thinking: caps.contains("thinking"))
        capabilityCache[key] = c
        return c
    }

    func forgetCapabilities() {
        capabilityGeneration &+= 1
        capabilityCache.removeAll()
    }

    // MARK: - Serialization gate

    private var gateHeld = false
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Never> }
    private var agentWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private static let maxBackgroundQueue = 2
    /// Number of agentic sessions in flight. While > 0, background completions
    /// are refused outright (`.busy`) instead of interleaving between turns —
    /// each interleaved call would cost a full local generation per turn.
    private var activeAgentSessions = 0

    /// True while an agentic loop is in flight — the health probe gives the
    /// server more time to answer then, since the GPU is busy generating.
    var isAgentSessionActive: Bool { activeAgentSessions > 0 }

    private func acquire(_ priority: Priority, activityID: UUID? = nil) async throws {
        try Task.checkCancellation()
        if let activityID {
            let active = await MainActor.run {
                let center = WorkActivityCenter.shared
                guard center.isActive(activityID) else { return false }
                center.update(activityID, phase: .queued, detail: "Your request is in line")
                return true
            }
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
        }
        if priority == .background && activeAgentSessions > 0 { throw AgentError.busy }
        if !gateHeld { gateHeld = true; return }
        if priority == .background, backgroundWaiters.count >= Self.maxBackgroundQueue { throw AgentError.busy }
        let id = UUID()
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let w = Waiter(id: id, continuation: c)
                if priority == .agent { agentWaiters.append(w) } else { backgroundWaiters.append(w) }
            }
        } onCancel: {
            // Hop back onto the actor to drop the parked waiter so a cancelled
            // Task never occupies a queue slot forever.
            Task { await self.cancelWaiter(id) }
        }
        // release() resumes a waiter WITH the gate (and records its id);
        // cancelWaiter resumes it WITHOUT. Only proceed in the former case.
        if !gateOwnerIs(id) { throw CancellationError() }
    }

    /// Ids handed the gate by `release()`; consulted once by the resumed waiter.
    private var grantedIDs: Set<UUID> = []
    private func gateOwnerIs(_ id: UUID) -> Bool {
        if grantedIDs.contains(id) { grantedIDs.remove(id); return true }
        return false
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = agentWaiters.firstIndex(where: { $0.id == id }) {
            agentWaiters.remove(at: i).continuation.resume()
        } else if let i = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: i).continuation.resume()
        }
    }

    private func release() {
        if !agentWaiters.isEmpty {
            let w = agentWaiters.removeFirst(); grantedIDs.insert(w.id); w.continuation.resume()
        } else if !backgroundWaiters.isEmpty {
            let w = backgroundWaiters.removeFirst(); grantedIDs.insert(w.id); w.continuation.resume()
        } else {
            gateHeld = false
        }
    }

    // MARK: - Agentic loop

    /// Retains the caller's owner through actor hops and nested tool work. The
    /// fallback covers model callers which have no higher-level activity yet.
    /// Its completion never ends a parent's multi-stage task.
    private func withModelActivity<T>(
        title: String,
        origin: WorkActivityCenter.Origin,
        completion: (T) -> (WorkActivityCenter.Outcome, String),
        operation: @escaping (UUID) async throws -> T
    ) async throws -> T {
        let inheritedID = WorkActivityScope.id
        let id: UUID
        if let inheritedID {
            id = inheritedID
        } else {
            id = await WorkActivityCenter.shared.begin(title: title, origin: origin)
        }
        do {
            try await checkActivity(id)
            let result: T
            if inheritedID == nil {
                let requestTask = Task {
                    try await WorkActivityScope.$id.withValue(id) {
                        try await operation(id)
                    }
                }
                await WorkActivityCenter.shared.setCancellationHandler(id) { requestTask.cancel() }
                result = try await withTaskCancellationHandler {
                    try await requestTask.value
                } onCancel: {
                    requestTask.cancel()
                }
            } else {
                result = try await WorkActivityScope.$id.withValue(id) {
                    try await operation(id)
                }
            }
            try await checkActivity(id)
            if inheritedID == nil {
                let (outcome, summary) = completion(result)
                if origin == .background, outcome == .success {
                    await WorkActivityCenter.shared.cancel(id)
                } else {
                    await WorkActivityCenter.shared.finish(id, outcome: outcome, summary: summary)
                }
            }
            return result
        } catch {
            if inheritedID == nil {
                if error is CancellationError {
                    await WorkActivityCenter.shared.cancel(id)
                } else if origin == .background, case AgentError.busy = error {
                    // A rejected optional background request is retried by its
                    // owner when appropriate; it must not flash an error storm.
                    await WorkActivityCenter.shared.cancel(id)
                } else {
                    await WorkActivityCenter.shared.finish(id, outcome: .failure,
                                                           summary: error.localizedDescription)
                }
            }
            throw error
        }
    }

    private func checkActivity(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard await WorkActivityCenter.shared.isActive(id) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func markWorking(_ id: UUID, detail: String = "Thinking with the local model") async throws {
        try await checkActivity(id)
        await WorkActivityCenter.shared.update(id, phase: .working, detail: detail)
        try Task.checkCancellation()
    }

    /// Runs model → tool → result → model until the model stops asking for tools.
    /// - onAssistantText: called with each turn's visible text (for live UI logging).
    /// - maxIterations: override for the outer turn cap (defaults to
    ///   OllamaConfig.maxIterations). Playbooks that should finish fast pass a
    ///   lower value so the loop can't wander.
    /// - systemContext: the volatile half of the system prompt (what's on screen
    ///   right now). Appended after `system` — there is no prompt cache to protect.
    func runAgent(
        system: String,
        systemContext: String? = nil,
        userText: String,
        tools: [ToolDef],
        maxIterations: Int? = nil,
        runTool: @escaping ToolRunner,
        onAssistantText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentOutcome {
        try await withModelActivity(title: String(userText.prefix(90)), origin: .user,
                                   completion: { result in
            if result.stopReason != "end_turn" {
                return (.failure, "The local model reached its limit before finishing.")
            }
            if result.lastTurnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.failure, "The local model returned no answer.")
            }
            return (.success, String(result.lastTurnText.prefix(180)))
        }) { id in
            try await self.runAgentRequest(system: system, systemContext: systemContext, userText: userText,
                                      tools: tools, maxIterations: maxIterations, runTool: runTool,
                                      onAssistantText: onAssistantText, activityID: id)
        }
    }

    private func runAgentRequest(
        system: String, systemContext: String?, userText: String, tools: [ToolDef],
        maxIterations: Int?, runTool: ToolRunner,
        onAssistantText: @escaping @Sendable (String) -> Void, activityID: UUID
    ) async throws -> AgentOutcome {
        guard OllamaConfig.isConfigured else { throw AgentError.notConfigured }
        let model = OllamaConfig.model
        let caps = try await capabilities(for: model)
        if !tools.isEmpty && !caps.tools {
            throw AgentError.unsupported("\(model) does not support tool calling — pick a tools-capable model in Settings ▸ Local Model")
        }

        activeAgentSessions += 1
        defer { activeAgentSessions -= 1 }

        // The system prompt + tool schemas are rendered FIRST and are identical
        // from run to run; the screen context changes every time. Keeping the
        // context out of the system message makes that prefix byte-identical,
        // so Ollama's KV prefix cache (and `primeCache`) skip re-reading it —
        // on a laptop that is the difference between 60 s and 5 s to the first
        // tool call.
        var firstUser = userText
        if let systemContext, !systemContext.isEmpty {
            firstUser = systemContext + "\n\n---\nTask: " + userText
        }
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": firstUser]
        ]
        var collectedText = ""
        var lastNonEmptyTurnText = ""
        var toolCalls = 0
        let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        let iterationCap = maxIterations ?? OllamaConfig.maxIterations
        for _ in 0..<iterationCap {
            // Hold the GPU for one turn. Already-queued work may proceed between
            // turns; new background requests are refused during agent sessions.
            try await acquire(.agent, activityID: activityID)
            let reply: ChatReply
            do {
                try await markWorking(activityID)
                reply = try await chat(model: model,
                                       messages: messages,
                                       tools: tools,
                                       format: nil,
                                       think: caps.thinking ? OllamaConfig.thinkingEnabled : nil,
                                       temperature: OllamaConfig.agentTemperature,
                                       // A thinking-capable model may deliberate even with
                                       // think:false (qwen3-vl's thinking tags do); leave
                                       // headroom so the answer is not guillotined.
                                       numPredict: OllamaConfig.agentNumPredict + (caps.thinking ? 1536 : 0),
                                       // Never retry once a tool has taken effect in this
                                       // session: the failure is surfaced instead.
                                       allowTransientRetry: toolCalls == 0)
                release()
            } catch {
                release()
                throw error
            }

            let turnText = reply.content
            if !turnText.isEmpty {
                collectedText += (collectedText.isEmpty ? "" : "\n") + turnText
                lastNonEmptyTurnText = turnText
                onAssistantText(turnText)
            }

            var toolCallsThisTurn = reply.toolCalls
            if toolCallsThisTurn.isEmpty, !tools.isEmpty,
               let synthesized = Self.toolCallFromContent(turnText, tools: tools) {
                // Small models sometimes write the call as JSON text instead of a
                // structured tool_call. Honour it rather than ending the run with
                // a JSON blob as the "answer".
                toolCallsThisTurn = [synthesized]
            }

            if toolCallsThisTurn.isEmpty {
                // Terminal turn. A `length` stop with nothing said is a truncation,
                // not an answer.
                if reply.doneReason == "length" && turnText.isEmpty { throw AgentError.truncated }
                return AgentOutcome(
                    finalText: collectedText,
                    lastTurnText: turnText.isEmpty ? lastNonEmptyTurnText : turnText,
                    stopReason: reply.doneReason == "length" ? "max_tokens" : "end_turn",
                    toolCallCount: toolCalls)
            }

            // Echo the assistant turn back VERBATIM (content + thinking + tool_calls).
            if reply.toolCalls.isEmpty, let call = toolCallsThisTurn.first {
                // Synthesized from content: echo it as a real tool_call so the
                // transcript the model sees next turn has the canonical shape.
                var assistant = reply.assistantMessage
                assistant["content"] = ""
                assistant["tool_calls"] = [["function": ["index": 0, "name": call.name, "arguments": call.arguments]]]
                messages.append(assistant)
            } else {
                messages.append(reply.assistantMessage)
            }

            // Execute every tool call; text results go back as `tool` messages,
            // images as ONE follow-up user message the model is guaranteed to see.
            var images: [(tool: String, base64: String)] = []
            for call in toolCallsThisTurn {
                try await markWorking(activityID, detail: "Checking the next step")
                toolCalls += 1
                let name = call.name
                var input = call.arguments
                input = Self.coerceArguments(input, schema: toolsByName[name]?.inputSchema)
                let result = await runTool(name, input)
                try await checkActivity(activityID)
                // Bounded: a single MCP listing can be 10-30k chars (3-8k
                // tokens) and the whole transcript has to fit num_ctx. Ollama
                // truncates an overlong prompt from the FRONT, which discards
                // the system prompt and tool definitions first.
                let text = Self.truncated(result.text, to: Self.maxToolResultChars)
                var toolMessage: [String: Any] = [
                    "role": "tool",
                    "tool_name": name,
                    "content": result.isError ? "ERROR: \(text)" : text
                ]
                if let id = call.id { toolMessage["tool_call_id"] = id }
                messages.append(toolMessage)
                if let img = result.imageBase64 { images.append((name, img)) }
            }
            // Older tool results are shortened the same way older screenshots
            // are dropped: the model has already acted on them.
            Self.pruneToolResults(in: &messages, keepingRecent: Self.fullToolResultsKept)
            let estimate = Self.estimatedTokens(of: messages)
            if estimate > OllamaConfig.numCtx * 7 / 10 {
                print("[Holmes] OllamaClient: transcript ≈\(estimate) tokens, \(OllamaConfig.numCtx) context — Ollama will trim the oldest input if it overflows")
            }

            if !images.isEmpty {
                Self.pruneImages(in: &messages, keeping: OllamaConfig.maxImagesInHistory - 1)
                let names = images.map { "`\($0.tool)`" }.joined(separator: ", ")
                messages.append([
                    "role": "user",
                    "content": "Image result of \(names) is attached. Coordinates you give must be pixels of the full `screenshot` frame (top-left origin). Look at it, then continue the task — call the next tool, or reply with a one-line summary if the task is complete.",
                    "images": images.map { $0.base64 }
                ])
            }
        }

        // Iteration budget exhausted with no terminal turn.
        return AgentOutcome(
            finalText: collectedText,
            lastTurnText: lastNonEmptyTurnText,
            stopReason: "max_iterations",
            toolCallCount: toolCalls)
    }

    /// Recognizes a tool call the model wrote as JSON TEXT, e.g.
    /// `{"name":"computer","parameters":{"action":"left_click",…}}` or
    /// `{"action":"screenshot"}` (bare computer-tool arguments). Returns nil for
    /// anything that is not unambiguously a call to one of `tools`.
    nonisolated static func toolCallFromContent(_ text: String, tools: [ToolDef]) -> ToolCall? {
        let names = tools.map { $0.name }
        func match(_ raw: String) -> String? {
            if names.contains(raw) { return raw }
            return names.first { $0.lowercased() == raw.lowercased() }
        }
        func namedCall(_ obj: [String: Any]) -> ToolCall? {
            // {"name": …, "parameters"/"arguments"/"input": {…}}
            for key in ["name", "tool", "function", "tool_name"] {
                if let raw = obj[key] as? String, let name = match(raw) {
                    let args = (obj["parameters"] as? [String: Any]) ?? (obj["arguments"] as? [String: Any])
                        ?? (obj["input"] as? [String: Any]) ?? [:]
                    return ToolCall(id: nil, name: name, arguments: args)
                }
            }
            // {"function": {"name": …, "arguments": {…}}}
            if let fn = obj["function"] as? [String: Any], let raw = fn["name"] as? String, let name = match(raw) {
                return ToolCall(id: nil, name: name, arguments: (fn["arguments"] as? [String: Any]) ?? [:])
            }
            return nil
        }

        // A call NAMING an offered tool is recovered wherever it sits: after a
        // sentence of narration, before one, or inside a code fence.
        var named: ToolCall?
        _ = ModelJSON.firstObject(in: text, where: { obj in
            named = namedCall(obj)
            return named != nil
        })
        if let named { return named }

        // Bare computer arguments carry no tool name, so they only count when
        // the whole message (after fence stripping) IS the object: a final prose
        // answer that merely quotes one ("I clicked using {"action":…} and it
        // worked") must not be re-executed.
        let t = stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), t.hasSuffix("}"),
              let data = t.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["action"] is String, let name = match("computer") else { return nil }
        return ToolCall(id: nil, name: name, arguments: obj)
    }

    /// Runs one throwaway turn with exactly the system prompt + tools an agent
    /// run will send, so the server's KV cache already holds that prefix when
    /// the user asks for something. Cheap (num_predict 1) and best-effort.
    func primeCache(system: String, tools: [ToolDef]) async {
        guard OllamaConfig.isConfigured else { return }
        let model = OllamaConfig.model
        guard let caps = try? await capabilities(for: model), !tools.isEmpty, caps.tools else { return }
        // A failed acquire (busy / cancelled) must NOT be followed by release():
        // that would hand the gate away from whoever actually holds it.
        do { try await acquire(.background) } catch { return }
        defer { release() }
        _ = try? await chat(model: model,
                            messages: [["role": "system", "content": system], ["role": "user", "content": "ready"]],
                            tools: tools, format: nil,
                            think: caps.thinking ? false : nil,
                            temperature: 0, numPredict: 1)
    }

    /// Small local models sometimes hand back `{"x":1,"y":2}` where the schema
    /// asked for `"coordinate":[x,y]`, or a JSON string where an object/array was
    /// expected. Fix the common shapes here so every tool runner keeps its strict
    /// parser.
    nonisolated static func coerceArguments(_ raw: [String: Any], schema: [String: Any]?) -> [String: Any] {
        var input = raw
        let props = (schema?["properties"] as? [String: Any]) ?? [:]
        // Arguments that arrived as a JSON string — but ONLY where the schema
        // declares an array/object. A string-typed argument that merely LOOKS
        // like JSON (`type_text` of a snippet, a `fill_field` value that is a
        // payload) must reach the tool verbatim, or its runner sees a
        // dictionary where it expects a String and reports "Missing 'text'".
        for (key, value) in raw {
            guard let spec = props[key] as? [String: Any] else { continue }
            let declared: Set<String>
            if let t = spec["type"] as? String { declared = [t] }
            else if let ts = spec["type"] as? [String] { declared = Set(ts) }
            else { declared = [] }
            guard declared.contains("array") || declared.contains("object") else { continue }
            if let s = value as? String, let first = s.trimmingCharacters(in: .whitespaces).first,
               first == "[" || first == "{",
               let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                input[key] = parsed
            }
        }
        // "coordinate": "412, 88" / "(412, 88)" → [412, 88]
        for key in ["coordinate", "start_coordinate"] {
            if let s = input[key] as? String {
                let nums = s.split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
                if nums.count == 2 { input[key] = [nums[0], nums[1]] }
            }
        }
        // {"x":..,"y":..} at the top level when the schema wants "coordinate".
        if props["coordinate"] != nil, input["coordinate"] == nil,
           let x = input["x"], let y = input["y"] {
            input["coordinate"] = [x, y]
            input.removeValue(forKey: "x"); input.removeValue(forKey: "y")
        }
        return input
    }

    /// Longest tool result forwarded to the model, in characters (≈1.5k tokens).
    nonisolated static let maxToolResultChars = 6000
    /// How many of the newest tool messages keep their full text; older ones
    /// are cut to `staleToolResultChars`.
    nonisolated static let fullToolResultsKept = 4
    nonisolated static let staleToolResultChars = 600

    nonisolated static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let dropped = text.count - limit
        return String(text.prefix(limit)) + "\n… [truncated \(dropped) chars]"
    }

    /// Shortens every `tool` message except the newest `keep`, so a long run's
    /// early listings stop competing with the system prompt for the window.
    nonisolated static func pruneToolResults(in messages: inout [[String: Any]], keepingRecent keep: Int) {
        let indices = messages.indices.filter { (messages[$0]["role"] as? String) == "tool" }
        let dropCount = max(0, indices.count - max(0, keep))
        for i in indices.prefix(dropCount) {
            guard let content = messages[i]["content"] as? String,
                  content.count > staleToolResultChars + 40 else { continue }
            messages[i]["content"] = truncated(content, to: staleToolResultChars)
                + " (earlier result shortened to save context)"
        }
    }

    /// Rough size of the transcript: chars/4 for text, ~1k per attached image.
    nonisolated static func estimatedTokens(of messages: [[String: Any]]) -> Int {
        var chars = 0
        var images = 0
        for m in messages {
            if let c = m["content"] as? String { chars += c.count }
            if let t = m["thinking"] as? String { chars += t.count }
            if let calls = m["tool_calls"] as? [[String: Any]] {
                for c in calls { chars += (try? JSONSerialization.data(withJSONObject: c))?.count ?? 0 }
            }
            images += (m["images"] as? [String])?.count ?? 0
        }
        return chars / 4 + images * 1000
    }

    /// Drops `images` from all but the newest `keep` user messages that carry
    /// them, leaving a placeholder so the transcript still reads correctly.
    nonisolated static func pruneImages(in messages: inout [[String: Any]], keeping keep: Int) {
        var indices: [Int] = []
        for (i, m) in messages.enumerated() where (m["role"] as? String) == "user" && m["images"] != nil {
            indices.append(i)
        }
        let dropCount = max(0, indices.count - max(0, keep))
        for i in indices.prefix(dropCount) {
            messages[i].removeValue(forKey: "images")
            let old = (messages[i]["content"] as? String) ?? ""
            messages[i]["content"] = "(earlier screenshot omitted to save context) " + old
        }
    }

    // MARK: - One-shot completion (no tools)

    /// A single tool-free request — the path every "think about this text and
    /// answer" caller uses (ReplyComposer, TriggerBrain's ambiguity check,
    /// HolmesAgent's context enrichment).
    ///
    /// - asJSON: constrain the reply to one JSON object. With `schema` this is
    ///   enforced by Ollama's grammar (`format`); the field list is ALSO restated
    ///   in the prompt because the grammar discards `description`s.
    /// - imageBase64: an optional base64 JPEG. Silently skipped (with a note in
    ///   the prompt) when the chosen model has no vision capability.
    /// - priority: `.background` (default) may be dropped with `.busy` while an
    ///   agent session owns the GPU; pass `.agent` for user-initiated work.
    func complete(system: String,
                  user: String,
                  maxTokens: Int = 1024,
                  asJSON: Bool = false,
                  schema: [String: Any]? = nil,
                  imageBase64: String? = nil,
                  priority: Priority = .background) async throws -> String {
        try await withModelActivity(title: priority == .agent ? "Answering your request" : "Reading context",
                                   origin: priority == .agent ? .user : .background,
                                   completion: { _ in (.success, "Answer ready.") }) { id in
            try await self.completeRequest(system: system, user: user, maxTokens: maxTokens,
                                      asJSON: asJSON, schema: schema, imageBase64: imageBase64,
                                      priority: priority, activityID: id)
        }
    }

    private func completeRequest(system: String, user: String, maxTokens: Int,
                                 asJSON: Bool, schema: [String: Any]?, imageBase64: String?,
                                 priority: Priority, activityID: UUID) async throws -> String {
        guard OllamaConfig.isConfigured else { throw AgentError.notConfigured }
        let model = OllamaConfig.model
        let caps = try await capabilities(for: model)

        var systemPrompt = system
        var format: Any? = nil
        if asJSON {
            if let schema {
                format = schema
                systemPrompt += "\n\nReply with a single JSON object and nothing else. Fields:\n"
                    + Self.describe(schema: schema)
            } else {
                format = "json"
                systemPrompt += "\n\nReply with a single JSON object and nothing else — no prose, no code fences."
            }
        }

        var userMessage: [String: Any] = ["role": "user", "content": user]
        if let imageBase64 {
            if caps.vision {
                userMessage["images"] = [imageBase64]
            } else {
                userMessage["content"] = "(A screenshot was attached but the local model cannot see images; rely on the text.)\n\n" + user
            }
        }

        try await acquire(priority, activityID: activityID)
        defer { release() }
        try await markWorking(activityID)
        let reply = try await chat(model: model,
                                   messages: [["role": "system", "content": systemPrompt], userMessage],
                                   tools: [],
                                   format: format,
                                   think: caps.thinking ? false : nil,
                                   temperature: asJSON ? OllamaConfig.jsonTemperature : 0.3,
                                   numPredict: max(maxTokens, OllamaConfig.quickNumPredictFloor) + (caps.thinking ? 1024 : 0),
                                   allowTransientRetry: true)
        var text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if asJSON { text = Self.stripCodeFences(text) }
        if text.isEmpty && reply.doneReason == "length" { throw AgentError.truncated }
        guard !text.isEmpty else { throw AgentError.transport("The local model returned no answer") }
        return text
    }

    /// Builds a strict JSON-Schema object literal for `complete(asJSON:schema:)`.
    /// Every declared property is required by default.
    nonisolated static func objectSchema(_ properties: [String: [String: Any]],
                                         required: [String]? = nil) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required ?? properties.keys.sorted(),
            "additionalProperties": false
        ]
    }

    /// Renders a schema's properties as prompt text, so the descriptions (which
    /// are load-bearing instructions in Holmes' prompts) still reach the model.
    nonisolated static func describe(schema: [String: Any], indent: String = "") -> String {
        guard let props = schema["properties"] as? [String: Any] else { return "" }
        let required = Set((schema["required"] as? [String]) ?? [])
        var lines: [String] = []
        for key in props.keys.sorted() {
            guard let spec = props[key] as? [String: Any] else { continue }
            var type = (spec["type"] as? String) ?? ((spec["type"] as? [String])?.joined(separator: "|") ?? "value")
            if type == "array", let items = spec["items"] as? [String: Any], let it = items["type"] as? String {
                type = "array of \(it)"
            }
            var line = "\(indent)- \"\(key)\" (\(type)\(required.contains(key) ? "" : ", optional"))"
            if let e = spec["enum"] as? [Any] {
                line += " one of: " + e.map { "\"\($0)\"" }.joined(separator: ", ")
            }
            if let d = spec["description"] as? String, !d.isEmpty { line += ": \(d)" }
            lines.append(line)
            if type == "object" { lines.append(describe(schema: spec, indent: indent + "  ")) }
            if let items = spec["items"] as? [String: Any], (items["type"] as? String) == "object" {
                lines.append(describe(schema: items, indent: indent + "  "))
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    nonisolated static func stripCodeFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - /api/chat

    struct ToolCall {
        let id: String?
        let name: String
        let arguments: [String: Any]
    }

    struct ChatReply {
        let content: String
        let thinking: String
        let toolCalls: [ToolCall]
        let doneReason: String
        /// The assistant message to echo back into the transcript.
        let assistantMessage: [String: Any]
    }

    private func chat(model: String,
                      messages: [[String: Any]],
                      tools: [ToolDef],
                      format: Any?,
                      think: Bool?,
                      temperature: Double,
                      numPredict: Int,
                      allowTransientRetry: Bool = false) async throws -> ChatReply {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "keep_alive": OllamaConfig.keepAlive,
            "options": [
                "num_ctx": OllamaConfig.numCtx,
                "temperature": temperature,
                "num_predict": numPredict
            ]
        ]
        if !tools.isEmpty { body["tools"] = tools.map { $0.apiDict } }
        if let format { body["format"] = format }   // never together with tools (see header)
        if let think { body["think"] = think }

        var content = ""
        var thinking = ""
        var rawToolCalls: [[String: Any]] = []
        var doneReason = "stop"
        var receivedAny = false
        var retried = false

        while true {
            do {
                try await streamNDJSON(path: "/api/chat", body: body) { chunk in
                    receivedAny = true
                    if let message = chunk["message"] as? [String: Any] {
                        if let c = message["content"] as? String { content += c }
                        if let t = message["thinking"] as? String { thinking += t }
                        if let calls = message["tool_calls"] as? [[String: Any]] { rawToolCalls += calls }
                    }
                    if (chunk["done"] as? Bool) == true {
                        doneReason = (chunk["done_reason"] as? String) ?? "stop"
                    }
                }
                break
            } catch let error as AgentError {
                // One short retry for a dropped/refused connection that produced
                // nothing yet. Timeouts, HTTP errors and partial streams are not
                // retried: they are reported so the user can decide.
                guard allowTransientRetry, !retried, !receivedAny, Self.isTransientConnectionFailure(error) else {
                    throw error
                }
                retried = true
                try await Task.sleep(nanoseconds: UInt64(max(0, OllamaConfig.transientRetryDelay) * 1_000_000_000))
            }
        }

        // A model whose template leaks <think> tags into content (no thinking
        // capability advertised) must not have them parsed as an answer.
        content = Self.stripThinkTags(content)

        let calls: [ToolCall] = rawToolCalls.compactMap { raw in
            guard let fn = raw["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            var args: [String: Any] = [:]
            if let obj = fn["arguments"] as? [String: Any] { args = obj }
            else if let s = fn["arguments"] as? String, let data = s.data(using: .utf8),
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { args = obj }
            return ToolCall(id: raw["id"] as? String, name: name, arguments: args)
        }

        var assistant: [String: Any] = ["role": "assistant", "content": content]
        if !thinking.isEmpty { assistant["thinking"] = thinking }
        if !rawToolCalls.isEmpty { assistant["tool_calls"] = rawToolCalls }

        return ChatReply(content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                         thinking: thinking, toolCalls: calls, doneReason: doneReason,
                         assistantMessage: assistant)
    }

    nonisolated static func stripThinkTags(_ s: String) -> String {
        guard s.contains("<think>") || s.contains("</think>") else { return s }
        var t = s.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transport

    /// POST a JSON body, parse a single JSON object reply. Errors: Ollama's
    /// envelope is `{"error": "<string>"}`.
    func request(path: String, body: [String: Any], timeout: TimeInterval = OllamaConfig.requestTimeout) async throws -> [String: Any] {
        let request = try makeRequest(path: path, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw try Self.mapTransport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw Self.mapHTTP(status: status, json: json, data: data, body: body)
        }
        return json ?? [:]
    }

    /// POST a JSON body and feed each NDJSON line to `onChunk`. Throws on HTTP
    /// errors and on a mid-stream `{"error": …}` object.
    private func streamNDJSON(path: String, body: [String: Any],
                              onChunk: ([String: Any]) -> Void) async throws {
        let request = try makeRequest(path: path, body: body, timeout: OllamaConfig.requestTimeout)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw try Self.mapTransport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            do { for try await b in bytes { data.append(b) } } catch {}
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Self.mapHTTP(status: status, json: json, data: data, body: body)
        }
        // Stall watchdog: once output has started, silence longer than
        // streamStallTimeout cancels the transfer and reports a timeout. The
        // first byte may still take as long as a cold model load needs.
        let activity = StreamActivity()
        let stallLimit = max(0.05, OllamaConfig.streamStallTimeout)
        let transfer = bytes.task
        let watchdog = Task.detached {
            let tick = UInt64(min(1.0, stallLimit / 4) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tick)
                if let idle = activity.secondsSinceLastChunk(), idle > stallLimit {
                    activity.markStalled()
                    transfer.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        do {
            for try await line in bytes.lines {
                activity.touch()
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                if let err = obj["error"] as? String {
                    // Delivered after a 200 was already sent ("model not found"
                    // once unloaded, "does not support …"): classify like an
                    // HTTP error so callers show the right text.
                    throw Self.mapHTTP(status: 500, json: obj, data: Data(), body: body)
                }
                onChunk(obj)
            }
            if activity.didStall { throw Self.stalled(after: stallLimit) }
        } catch let e as AgentError {
            throw e
        } catch {
            if activity.didStall { throw Self.stalled(after: stallLimit) }
            throw try Self.mapTransport(error)
        }
    }

    nonisolated private static func stalled(after seconds: TimeInterval) -> AgentError {
        OllamaConfig.onModelTransportFailure?()
        return .timedOut("no output for \(Int(seconds.rounded())) seconds")
    }

    nonisolated static func isTransientConnectionFailure(_ error: AgentError) -> Bool {
        if case .serverUnreachable = error { return true }
        return false
    }

    /// Last streamed chunk time, shared with the stall watchdog task.
    private final class StreamActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastChunk: Date?
        private var stalled = false
        func touch() { lock.lock(); lastChunk = Date(); lock.unlock() }
        func secondsSinceLastChunk() -> TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            return lastChunk.map { Date().timeIntervalSince($0) }
        }
        func markStalled() { lock.lock(); stalled = true; lock.unlock() }
        var didStall: Bool { lock.lock(); defer { lock.unlock() }; return stalled }
    }

    private func makeRequest(path: String, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: OllamaConfig.baseURL)?.absoluteURL else {
            throw AgentError.transport("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Maps a URLSession failure to AgentError — except cancellation, which is
    /// rethrown as CancellationError so a cancelled run exits quietly instead
    /// of surfacing "Ollama request failed: cancelled" to the user.
    nonisolated private static func mapTransport(_ error: Error) throws -> AgentError {
        if error is CancellationError { throw CancellationError() }
        if let u = error as? URLError {
            if u.code == .cancelled { throw CancellationError() }
            switch u.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                OllamaConfig.onModelTransportFailure?()
                return .serverUnreachable(u.localizedDescription)
            case .timedOut:
                // User visible and retryable by the user, never silently retried
                // (another full wait). The server status is refreshed right away.
                OllamaConfig.onModelTransportFailure?()
                return .timedOut("no response for \(Int(OllamaConfig.requestTimeout)) seconds")
            default: break
            }
        }
        return .transport(error.localizedDescription)
    }

    nonisolated private static func mapHTTP(status: Int, json: [String: Any]?, data: Data, body: [String: Any]) -> AgentError {
        let message = (json?["error"] as? String)
            ?? (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            ?? "HTTP \(status)"
        if status == 404, message.lowercased().contains("not found"), message.lowercased().contains("model") {
            return .modelMissing((body["model"] as? String) ?? message)
        }
        if status == 400 && message.lowercased().contains("does not support") { return .unsupported(message) }
        return .http(status, message)
    }
}
