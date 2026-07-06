import Foundation
import AppKit

// MARK: - HolmesBrain
// The agentic "action brain". Given a goal, it runs a Claude tool-use loop with:
//   • built-in tools mapped to the existing ActionExecutor / ScreenEngine, and
//   • every tool exposed by connected MCP servers.
// Side-effecting tool calls are gated through the existing ConfirmationBus approval
// card, so nothing runs without the user's OK. Read-only tools run automatically.
//
// This is the Hybrid model in action: Ollama still drives fast on-device context,
// but real multi-step actions run through Claude here.

@MainActor
final class HolmesBrain {
    static let shared = HolmesBrain()
    private init() {}

    var isConfigured: Bool { AnthropicConfig.isConfigured }

    /// Kick off MCP servers in the background (called from HolmesAgent.start()).
    func start() {
        Task {
            await MCPClient.shared.startAll()
            updateBackendLabel()
        }
    }

    /// Folds Claude + MCP status into the backend label shown in the Main Panel,
    /// e.g. "Ollama (localhost) + Claude · MCP: 12 tools".
    func updateBackendLabel() {
        let local = LocalModelEngine.shared.activeBackend.rawValue
        let claude = AnthropicConfig.isConfigured ? " + Claude" : ""
        let toolCount = MCPClient.shared.tools.count
        let mcp = toolCount == 0 ? "" : " · MCP: \(toolCount) tools"
        HolmesAgent.shared.modelBackend = "\(local)\(claude)\(mcp)"
    }

    // MARK: - Run a goal

    enum RunResult {
        case notConfigured
        case text(String)
    }

    /// Runs `goal` to completion through the Claude + tools loop.
    /// - log: receives each turn's assistant text for live display.
    func run(goal: String, log: @escaping @MainActor (String) -> Void) async -> RunResult {
        guard AnthropicConfig.isConfigured else { return .notConfigured }

        await MCPClient.shared.startAll() // no-op if already started
        let tools = builtinTools + MCPClient.shared.anthropicTools()
        let system = buildSystemPrompt()

        do {
            let outcome = try await AnthropicClient.shared.runAgent(
                system: system,
                userText: goal,
                tools: tools,
                runTool: { [weak self] name, input in
                    guard let self else { return AnthropicClient.ToolResult("internal error", isError: true) }
                    return await self.runTool(name: name, input: input)
                },
                onAssistantText: { text in
                    Task { @MainActor in log(text) }
                }
            )
            let text = outcome.finalText.isEmpty
                ? "Done (\(outcome.toolCallCount) tool call\(outcome.toolCallCount == 1 ? "" : "s"))."
                : outcome.finalText
            return .text(text)
        } catch let AnthropicClient.AgentError.refused(msg) {
            return .text("Holmes declined: \(msg)")
        } catch let AnthropicClient.AgentError.http(code, msg) {
            return .text("Claude API error \(code): \(msg)")
        } catch {
            return .text("Action failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Run a playbook (draft-only mode)

    /// The result of a playbook run: the draft text plus ground-truth facts
    /// about the one sanctioned server-side write (Gmail draft creation),
    /// captured from actual tool calls — never from the model's prose.
    struct PlaybookOutcome {
        let text: String
        let gmailDraftsCreated: Int
        /// One entry per successful draft-create call, e.g.
        /// "to ada@x.com — “Re: Lunch”" (built from the tool-call input).
        let stagedDraftNotes: [String]
    }

    /// Runs a proactive playbook goal through the Claude tool loop in DRAFT-ONLY mode.
    /// Playbook mode is deterministically incapable of sending: the tool list contains
    /// only the read-only `read_screen` built-in, MCP tools whose bare name passes the
    /// ComposioCatalog.isPlaybookSafe default-deny policy AND that self-declare
    /// readOnlyHint, and the Composio meta tools (read-only search/schemas plus the
    /// executor, whose inner tool_slugs are re-validated per call by
    /// validateMetaExecute against the strict isMetaSlugReadOnly policy — the single
    /// draft-creation exception clears only when `allowDraftWrite` is true, and its
    /// recipients must be grounded in data fetched earlier in the SAME run). Anything
    /// that could send/post/modify simply is not offered to — or is rejected before
    /// reaching — MCP, so there is no ConfirmationBus involvement here at all.
    /// Returns the outcome (draft text + write facts), or nil on failure. Does not
    /// touch the user-initiated run(goal:).
    func runPlaybook(goal: String, systemHint: String, composioApps: [String], allowDraftWrite: Bool = false) async -> PlaybookOutcome? {
        guard AnthropicConfig.isConfigured else { return nil }

        await MCPClient.shared.startAll() // no-op if already started

        // Playbook-safe MCP tools only. The safety policy runs on the BARE,
        // untruncated tool name: the "server__" prefix comes from the user's
        // mcp.json, so a server named e.g. "drafts" or "readwise" must never be
        // able to allowlist its tools, and namespacedName's 64-char cap could
        // hide a blocklist verb past the cut. A playbook that declares no
        // Composio apps ([] = no MCP needed) gets NO MCP tools at all —
        // read_screen only — never the whole cross-app tool surface.
        //
        // Composio's hosted MCP exposes only META tools (COMPOSIO_SEARCH_TOOLS,
        // COMPOSIO_MULTI_EXECUTE_TOOL, ...) whose names carry no app slug, so they
        // bypass the composioApps NAME filter: the read-only metas are inert, and
        // the executor's inner tool_slugs are validated per-call at dispatch by
        // ComposioCatalog.validateMetaExecute (which does enforce composioApps).
        // WAIT_FOR_CONNECTIONS / REMOTE_BASH / WORKBENCH / MANAGE_CONNECTIONS
        // match none of these paths and stay excluded by default deny.
        //
        // Hardening:
        //   • meta tools are honored ONLY from the configured Composio server —
        //     any other server exposing a tool named COMPOSIO_MULTI_EXECUTE_TOOL
        //     must not be able to impersonate the guarded executor and receive
        //     validated (trusted-looking) calls;
        //   • non-meta tools must ALSO self-declare annotations.readOnlyHint —
        //     a tool NAME is not a contract, and playbook runs are unattended.
        let safeMCPTools = MCPClient.shared.tools.filter { tool in
            guard !composioApps.isEmpty else { return false }
            let bare = tool.name.uppercased()
            let isComposioServer = tool.serverName.lowercased() == ComposioCatalog.composioServerName
            if ComposioCatalog.metaReadTools.contains(bare) { return isComposioServer }
            if bare == ComposioCatalog.metaExecuteTool { return isComposioServer }
            guard tool.readOnly else { return false }
            guard ComposioCatalog.isPlaybookSafe(toolName: tool.name) else { return false }
            // isPlaybookSafe's rule-1 carve-out admits draft-CREATE names, but a
            // directly-offered draft-create is the same server-side write as the
            // meta path's sanctioned slug: hold it to the same kind gate, so
            // read-only playbooks (morning-brief, meeting-prep, evening-wrapup,
            // ...) are never offered one, whatever readOnlyHint the server claims.
            if ComposioCatalog.isDraftCreateTool(tool.name), !allowDraftWrite { return false }
            let lower = tool.namespacedName.lowercased()
            return composioApps.contains { lower.contains($0.lowercased()) }
        }

        // Namespaced name(s) the meta executor was offered under — dispatch matches
        // against these, never against whatever raw string the model sent.
        let metaExecuteNames = Set(
            safeMCPTools
                .filter { $0.name.uppercased() == ComposioCatalog.metaExecuteTool }
                .map { $0.namespacedName }
        )

        // Directly-offered draft-create tools (non-meta; present only when
        // allowDraftWrite let them through the filter above). Their dispatch is
        // held to the same recipient-grounding guard and stagedNote disclosure
        // as the meta path's GMAIL_CREATE_EMAIL_DRAFT — matched against the
        // names WE offered, never against whatever raw string the model sent.
        let directDraftCreateNames = Set(
            safeMCPTools
                .filter { !metaExecuteNames.contains($0.namespacedName) && ComposioCatalog.isDraftCreateTool($0.name) }
                .map { $0.namespacedName }
        )

        // Built-ins: only read_screen is allowed in playbook mode. The meta
        // executor's advertised description gains a draft-only warning so the
        // model doesn't waste budget on slugs the dispatch guard will reject.
        let tools = builtinTools.filter { $0.name == "read_screen" }
            + safeMCPTools.map { tool -> AnthropicClient.ToolDef in
                let def = tool.anthropicTool
                guard metaExecuteNames.contains(tool.namespacedName) else { return def }
                return AnthropicClient.ToolDef(
                    name: def.name,
                    description: def.description
                        + " DRAFT-ONLY MODE: only read/list/fetch/search tool_slugs will be permitted; send/write/delete slugs are rejected.",
                    inputSchema: def.inputSchema
                )
            }
        let allowedNames = Set(tools.map { $0.name })

        var system = screenContextPreamble()
            + "\n\n" + systemHint
            + "\n\nYou are in DRAFT-ONLY mode: you cannot and must not send, post, publish, "
            + "or modify anything; produce the draft as your final text."
        if !metaExecuteNames.isEmpty {
            system += "\n\nTo gather live data, first call COMPOSIO_SEARCH_TOOLS for the relevant app, "
                + "then execute ONLY read-only tool slugs via COMPOSIO_MULTI_EXECUTE_TOOL."
        }

        // Cap playbook work at 6 tool executions. (AnthropicClient's own
        // maxIterations still bounds the outer turn loop; this tighter budget is
        // enforced here because the loop's iteration count isn't parameterizable.)
        var toolBudget = 6

        // Addresses observed in this run's tool RESULTS. The sanctioned
        // draft-create may only be addressed to these — a recipient the model
        // invented (or was prompt-injected with) that never appeared in fetched
        // data blocks the call.
        var knownAddresses: Set<String> = []
        // Ground truth about successful draft-create calls (input-derived).
        var gmailDraftsCreated = 0
        var stagedDraftNotes: [String] = []

        do {
            let outcome = try await AnthropicClient.shared.runAgent(
                system: system,
                userText: goal,
                tools: tools,
                runTool: { [weak self] name, input in
                    guard let self else { return AnthropicClient.ToolResult("internal error", isError: true) }
                    // Default deny: only tools we explicitly offered may run.
                    guard allowedNames.contains(name) else {
                        return AnthropicClient.ToolResult("Tool '\(name)' is not available in draft-only mode.", isError: true)
                    }
                    guard toolBudget > 0 else {
                        return AnthropicClient.ToolResult("Tool budget exhausted. Stop calling tools and produce the final draft as your text now.")
                    }
                    toolBudget -= 1
                    if name == "read_screen" { return await self.readScreen() }
                    // Meta-executor guard: validate every inner tool_slug BEFORE the
                    // call ever reaches MCP. A blocked call is reported back to the
                    // model as an error result so the loop continues gracefully.
                    var draftItems: [[String: Any]] = []
                    if metaExecuteNames.contains(name) {
                        let verdict = ComposioCatalog.validateMetaExecute(
                            arguments: input,
                            composioApps: composioApps,
                            allowDraftWrite: allowDraftWrite
                        )
                        guard verdict.allowed else {
                            return AnthropicClient.ToolResult(
                                "Draft-only mode blocked this call: \(verdict.reason). Only read/fetch/list/search tool slugs are permitted.",
                                isError: true
                            )
                        }
                        // Sanctioned-write argument guard: the draft's recipients
                        // must be grounded in data fetched earlier in this run.
                        draftItems = ComposioCatalog.draftCreateItems(in: input)
                        // A sanctioned draft-create must be the SOLE tool in its
                        // execute call. Bundled with reads, the aggregate isError
                        // reflects those reads too — a failed read flips the whole
                        // call to error even when the draft succeeded server-side,
                        // so gmailDraftsCreated below would never count it and the
                        // draft's review card + notification would be suppressed on
                        // the quiet path. Requiring it solo makes the returned
                        // isError track the draft-create outcome exactly.
                        if !draftItems.isEmpty {
                            let totalTools = (input["tools"] as? [[String: Any]])?.count ?? 0
                            guard totalTools == 1 else {
                                return AnthropicClient.ToolResult(
                                    "Draft-only mode requires GMAIL_CREATE_EMAIL_DRAFT to be the only tool in its COMPOSIO_MULTI_EXECUTE_TOOL call. Run your read/fetch slugs first, then issue the draft-create on its own.",
                                    isError: true
                                )
                            }
                        }
                        for item in draftItems {
                            let check = ComposioCatalog.validateDraftRecipients(item: item, knownAddresses: knownAddresses)
                            guard check.allowed else {
                                return AnthropicClient.ToolResult(
                                    "Draft-only mode blocked this call: \(check.reason).",
                                    isError: true
                                )
                            }
                        }
                    } else if directDraftCreateNames.contains(name) {
                        // A DIRECTLY-offered draft-create tool is the same
                        // server-side write as the meta path's sanctioned slug:
                        // same recipient grounding (wrap the top-level input so
                        // the shared guard reads its to/cc/bcc keys), and on
                        // success it counts as a staged write so the review
                        // card, stagedNote, and notification disclose it.
                        let item: [String: Any] = ["arguments": input]
                        let check = ComposioCatalog.validateDraftRecipients(item: item, knownAddresses: knownAddresses)
                        guard check.allowed else {
                            return AnthropicClient.ToolResult(
                                "Draft-only mode blocked this call: \(check.reason).",
                                isError: true
                            )
                        }
                        draftItems = [item]
                    }
                    let result = await MCPClient.shared.call(namespacedName: name, arguments: input)
                    if !result.isError {
                        // Harvest participants from fetched data for the guard above.
                        knownAddresses.formUnion(ComposioCatalog.emailAddresses(in: result.text))
                        if !draftItems.isEmpty {
                            gmailDraftsCreated += draftItems.count
                            stagedDraftNotes.append(contentsOf: draftItems.map(ComposioCatalog.describeDraftCreate))
                        }
                    }
                    return result
                }
            )
            let text = outcome.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PlaybookOutcome(
                text: text,
                gmailDraftsCreated: gmailDraftsCreated,
                stagedDraftNotes: stagedDraftNotes
            )
        } catch {
            print("[Playbook] runPlaybook failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - System prompt

    /// Screen-context preamble shared by the user-initiated loop and playbook mode.
    private func screenContextPreamble() -> String {
        let agent = HolmesAgent.shared
        let app = agent.currentContext.appName.isEmpty ? ScreenEngine.shared.latestActiveApp : agent.currentContext.appName
        let window = ScreenEngine.shared.latestActiveWindowTitle
        let context = agent.currentContext.description
        let ocr = String(agent.lastOCRText.prefix(1500))

        return """
        You are Holmes, an autonomous macOS desktop assistant. You help the user by taking real \
        actions on their Mac through tools.

        Current screen context:
        - Active app: \(app.isEmpty ? "unknown" : app)
        - Window: \(window.isEmpty ? "unknown" : window)
        - Summary: \(context)
        - Visible text (OCR/AX, truncated):
        \(ocr.isEmpty ? "(none captured)" : ocr)
        """
    }

    private func buildSystemPrompt() -> String {
        screenContextPreamble() + "\n\n" + """
        Guidelines:
        - Call read_screen first if you need fresh, fuller screen content before acting.
        - Use the most specific tool available. MCP tools (named "<server>__<tool>") often do a \
        task more reliably than typing into a field.
        - The user must approve every side-effecting action via a confirmation card — that happens \
        automatically when you call such a tool. If a call returns "User declined", stop and explain.
        - Be concise. When the task is done, give a one-line summary of what you did.
        - Never fabricate results. Only report what tools actually returned.
        """
    }

    // MARK: - Built-in tools

    private var builtinTools: [AnthropicClient.ToolDef] {
        [
            .init(name: "read_screen",
                  description: "Read the user's current screen: active app, window title, and visible text. Read-only.",
                  inputSchema: ["type": "object", "properties": [:]]),
            .init(name: "type_text",
                  description: "Type text into the focused field of the frontmost app (e.g. a reply box). Requires user approval.",
                  inputSchema: ["type": "object",
                                "properties": ["text": ["type": "string", "description": "The exact text to type."]],
                                "required": ["text"]]),
            .init(name: "send_message",
                  description: "Put a message into the active messaging app's input field (Messages, Discord, Slack, Mail). Requires user approval.",
                  inputSchema: ["type": "object",
                                "properties": ["message": ["type": "string", "description": "The message text."],
                                               "app": ["type": "string", "description": "Optional target app name; defaults to the active app."]],
                                "required": ["message"]]),
            .init(name: "open_url",
                  description: "Open a URL in the user's default browser. Requires user approval.",
                  inputSchema: ["type": "object",
                                "properties": ["url": ["type": "string", "description": "A fully-qualified https URL."]],
                                "required": ["url"]]),
            .init(name: "click_button",
                  description: "Click a button in the frontmost app by its visible label, via Accessibility. Requires user approval.",
                  inputSchema: ["type": "object",
                                "properties": ["label": ["type": "string", "description": "The button's visible label."]],
                                "required": ["label"]])
        ]
    }

    // MARK: - Tool dispatch

    private func runTool(name: String, input: [String: Any]) async -> AnthropicClient.ToolResult {
        switch name {
        case "read_screen":   return readScreen()
        case "type_text":     return await typeText(input)
        case "send_message":  return await sendMessage(input)
        case "open_url":      return await openURL(input)
        case "click_button":  return await clickButton(input)
        default:              return await callMCP(name: name, input: input)
        }
    }

    private func readScreen() -> AnthropicClient.ToolResult {
        HolmesAgent.shared.captureNow() // refresh in the background for next time
        let agent = HolmesAgent.shared
        let app = agent.currentContext.appName.isEmpty ? ScreenEngine.shared.latestActiveApp : agent.currentContext.appName
        let window = ScreenEngine.shared.latestActiveWindowTitle
        let text = String(agent.lastOCRText.prefix(3000))
        return AnthropicClient.ToolResult("""
        Active app: \(app)
        Window: \(window)
        Visible text:
        \(text.isEmpty ? "(none)" : text)
        """)
    }

    private func typeText(_ input: [String: Any]) async -> AnthropicClient.ToolResult {
        guard let text = input["text"] as? String, !text.isEmpty else {
            return AnthropicClient.ToolResult("Missing 'text'.", isError: true)
        }
        let app = ScreenEngine.shared.latestActiveApp
        guard let approved = await approve(title: "Type into \(app.isEmpty ? "frontmost app" : app)",
                                           preview: text, app: app) else {
            return AnthropicClient.ToolResult("User declined to type the text.")
        }
        guard let running = ActionExecutor.shared.runningApp(named: app) else {
            return AnthropicClient.ToolResult("Could not find app '\(app)' to type into.", isError: true)
        }
        let ok = await offMain { ActionExecutor.shared.typeIntoFocusedField(in: running, text: approved) }
        return AnthropicClient.ToolResult(ok ? "Typed the text into \(app)." : "Failed to type.", isError: !ok)
    }

    private func sendMessage(_ input: [String: Any]) async -> AnthropicClient.ToolResult {
        guard let message = input["message"] as? String, !message.isEmpty else {
            return AnthropicClient.ToolResult("Missing 'message'.", isError: true)
        }
        let app = (input["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (ScreenEngine.shared.latestActiveApp.isEmpty ? "Messages" : ScreenEngine.shared.latestActiveApp)
        guard let approved = await approve(title: "Send on \(app)", preview: message, app: app) else {
            return AnthropicClient.ToolResult("User declined to send the message.")
        }
        let ok = await offMain { ActionExecutor.shared.sendMessageInApp(app, message: approved) }
        return AnthropicClient.ToolResult(ok ? "Placed the message into \(app)'s input field." : "Failed to send.", isError: !ok)
    }

    private func openURL(_ input: [String: Any]) async -> AnthropicClient.ToolResult {
        guard let urlString = input["url"] as? String, let url = URL(string: urlString) else {
            return AnthropicClient.ToolResult("Invalid 'url'.", isError: true)
        }
        guard await approve(title: "Open URL", preview: urlString, app: "Browser") != nil else {
            return AnthropicClient.ToolResult("User declined to open the URL.")
        }
        NSWorkspace.shared.open(url)
        return AnthropicClient.ToolResult("Opened \(urlString).")
    }

    private func clickButton(_ input: [String: Any]) async -> AnthropicClient.ToolResult {
        guard let label = input["label"] as? String, !label.isEmpty else {
            return AnthropicClient.ToolResult("Missing 'label'.", isError: true)
        }
        let app = ScreenEngine.shared.latestActiveApp
        guard await approve(title: "Click \"\(label)\" in \(app)", preview: "Click button: \(label)", app: app) != nil else {
            return AnthropicClient.ToolResult("User declined to click the button.")
        }
        guard let running = ActionExecutor.shared.runningApp(named: app) else {
            return AnthropicClient.ToolResult("Could not find app '\(app)'.", isError: true)
        }
        let ok = await offMain { ActionExecutor.shared.clickButton(label: label, in: running) }
        return AnthropicClient.ToolResult(ok ? "Clicked '\(label)'." : "Could not find a button labeled '\(label)'.", isError: !ok)
    }

    private func callMCP(name: String, input: [String: Any]) async -> AnthropicClient.ToolResult {
        let mcpTool = MCPClient.shared.tool(forNamespacedName: name)
        if let mcpTool, !mcpTool.readOnly {
            let preview = prettyArguments(input)
            guard await approve(title: "Run \(name)", preview: preview, app: mcpTool.serverName) != nil else {
                return AnthropicClient.ToolResult("User declined to run \(name).")
            }
        }
        return await MCPClient.shared.call(namespacedName: name, arguments: input)
    }

    // MARK: - Helpers

    /// Surfaces an approval card and suspends until the user decides.
    /// Returns the (possibly edited) preview text, or nil if dismissed.
    private func approve(title: String, preview: String, app: String) async -> String? {
        let action = PendingAction(title: title, preview: preview, appName: app, actionType: .agentToolCall)
        switch await ConfirmationBus.shared.decide(action) {
        case .approved(let text): return text
        case .dismissed:          return nil
        }
    }

    /// Runs blocking AppKit/AX work off the main thread (ActionExecutor uses Thread.sleep).
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    private func prettyArguments(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "(no arguments)" }
        return str
    }
}
