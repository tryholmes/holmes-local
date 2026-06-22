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

    // MARK: - System prompt

    private func buildSystemPrompt() -> String {
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
