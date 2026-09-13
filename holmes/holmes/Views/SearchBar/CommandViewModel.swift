import SwiftUI
import Observation

// MARK: - Command definitions

struct HolmesCommand: Identifiable, Equatable {
    let id = UUID()
    let trigger: String      // e.g. "/run"
    let label: String
    let description: String
    let icon: String         // SF Symbol

    static let all: [HolmesCommand] = [
        HolmesCommand(trigger: "/run",     label: "Run",     description: "Execute an autonomous task",        icon: "play.fill"),
        HolmesCommand(trigger: "/watch",   label: "Watch",   description: "Monitor your screen continuously",  icon: "eye.fill"),
        HolmesCommand(trigger: "/ask",     label: "Ask",     description: "Ask a free-form question",          icon: "bubble.left.fill"),
        HolmesCommand(trigger: "/plan",    label: "Plan",    description: "Break a goal into actionable steps", icon: "list.bullet"),
        HolmesCommand(trigger: "/done",    label: "Done",    description: "Mark current task as complete",     icon: "checkmark.circle.fill"),
    ]
}

// MARK: - Execution log line

struct LogLine: Identifiable {
    let id = UUID()
    var text: String
    var kind: Kind

    enum Kind { case info, success, error, step }

    var prefix: String {
        switch kind {
        case .info:    return "›"
        case .success: return "✓"
        case .error:   return "✗"
        case .step:    return "·"
        }
    }

    var color: Color {
        switch kind {
        case .info:    return Color(hex: "8FA8B0")
        case .success: return Color(hex: "5DBB7A")
        case .error:   return Color(hex: "E05252")
        case .step:    return Color(hex: "C8B87A")
        }
    }
}

// MARK: - State

enum CommandState {
    case idle
    case typing
    case running
    case done
    case error
}

// MARK: - ViewModel

@Observable
@MainActor
final class CommandViewModel {
    var inputText: String = ""
    var state: CommandState = .idle
    var log: [LogLine] = []
    var showOutput: Bool = false
    var matchedCommand: HolmesCommand? = nil
    var suggestions: [HolmesCommand] = []
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration = UUID()
    @ObservationIgnored private var activityID: UUID?

    // Called by SearchBarView on appear — picks up any pending suggestion tap
    func checkPendingCommand() {
        if let cmd = CommandBus.shared.consume(), !cmd.isEmpty {
            onInputChange(cmd)
            submit()
        }
    }

    func onInputChange(_ text: String) {
        inputText = text
        state = text.isEmpty ? .idle : .typing
        updateSuggestions(text)
    }

    func selectCommand(_ cmd: HolmesCommand) {
        inputText = cmd.trigger + " "
        matchedCommand = cmd
        suggestions = []
    }

    func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        matchedCommand = resolveCommand(from: text)
        suggestions = []
        runCommand(text)
    }

    func reset() {
        cancelCurrentCommand()
        inputText = ""
        state = .idle
        log = []
        showOutput = false
        matchedCommand = nil
        suggestions = []
    }

    // MARK: Private

    private func updateSuggestions(_ text: String) {
        guard text.hasPrefix("/") else { suggestions = []; return }
        let query = text.lowercased()
        suggestions = HolmesCommand.all.filter { $0.trigger.hasPrefix(query) }
    }

    private func resolveCommand(from text: String) -> HolmesCommand? {
        let firstWord = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first?.lowercased()
        return HolmesCommand.all.first { $0.trigger == firstWord }
    }

    private func runCommand(_ text: String) {
        cancelCurrentCommand()
        ClickyController.shared.cancelPendingQuery()
        state = .running
        showOutput = true
        log = []

        let cmd = matchedCommand
        // Strip only a recognized slash command. Plain text is the whole
        // request: "open Spotify" must not silently become "Spotify".
        let arg = cmd.map {
            String(text.dropFirst($0.trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? text

        let generation = commandGeneration
        let id = WorkActivityCenter.shared.begin(title: cmd?.label ?? "Your request", detail: arg, origin: .user)
        activityID = id
        commandTask = Task {
            await WorkActivityScope.$id.withValue(id) {
                await executeWithLLM(command: cmd, argument: arg, generation: generation)
            }
            guard commandGeneration == generation else { return }
            if Task.isCancelled {
                WorkActivityCenter.shared.cancel(id)
            } else if WorkActivityCenter.shared.isActive(id) {
                let summary = log.last?.text ?? "Request finished"
                WorkActivityCenter.shared.finish(id, outcome: state == .done ? .success : .failure, summary: summary)
            }
            commandTask = nil
            activityID = nil
        }
        WorkActivityCenter.shared.setCancellationHandler(id) { [weak self] in
            guard let self, self.commandGeneration == generation else { return }
            self.cancelCurrentCommand()
            self.appendLog("Request stopped.", kind: .info)
            self.state = .idle
        }
    }

    private func cancelCurrentCommand() {
        commandGeneration = UUID()
        commandTask?.cancel()
        commandTask = nil
        if let activityID { WorkActivityCenter.shared.cancel(activityID) }
        activityID = nil
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        guard commandGeneration == generation, !Task.isCancelled, let activityID else { return false }
        return WorkActivityCenter.shared.isActive(activityID)
    }

    // MARK: - Real LLM execution

    private func executeWithLLM(command: HolmesCommand?, argument: String, generation: UUID) async {
        guard isCurrent(generation) else { return }
        let trigger = command?.trigger ?? "/ask"

        // An explicit /plan remains a plan. Plain text, /ask and /run drafting
        // requests all produce the same editable email card before other routing.
        if command == nil || trigger == "/ask" || trigger == "/run",
           EmailDraftCoordinator.shared.canHandle(argument) {
            appendLog("Drafting your email…", kind: .step)
            let result = await EmailDraftCoordinator.shared.request(instruction: argument)
            guard isCurrent(generation) else { return }
            switch result {
            case .ready(let summary):
                appendLog(summary, kind: .success)
                state = .done
            case .needsContext(let message), .failed(let message):
                appendLog(message, kind: .error)
                state = .error
            case .cancelled:
                appendLog("Request cancelled", kind: .info)
                state = .idle
                if let activityID { WorkActivityCenter.shared.cancel(activityID, summary: "Request cancelled") }
            }
            return
        }

        // A clear app launch is native and needs neither screen context nor a
        // model. Explicit /ask and compound requests retain their existing path.
        if command == nil || trigger == "/run",
           let appName = AppLaunchIntent.appName(in: argument) {
            let result = await AppLauncher.launch(named: appName)
            guard isCurrent(generation) else { return }
            appendLog(result.message, kind: result.succeeded ? .success : .error)
            state = result.succeeded ? .done : .error
            return
        }

        let agent = HolmesAgent.shared
        let appName = agent.currentContext.appName.isEmpty
            ? ScreenEngine.shared.latestActiveApp
            : agent.currentContext.appName
        let contextSummary = agent.currentContext.description
        let ocrText = agent.lastOCRText

        // ── Instant commands: no model at all ─────────────────────────────────
        // Pure local logic (calendar + AX reads), so they work even when Ollama is down.
        let argL = argument.lowercased()

        // A reply to a real conversation, grounded in the actual thread and in
        // memory, beats a canned availability line whenever the thread is
        // readable. This is user-initiated and lands in the approval card —
        // ReplyComposer has no send path at all, and staging still goes through
        // ActionExecutor after the user approves.
        if argL.hasPrefix("reply imessage") || argL.hasPrefix("suggest imessage reply") {
            if await draftGroundedReply(appName: appName, generation: generation) { return }
            guard isCurrent(generation) else { return }
        }

        if trigger == "/run" {
            // "reply busy meeting …" or "reply imessage" or "reply free"
            if argL.hasPrefix("reply busy") || argL.hasPrefix("reply imessage") || argL.hasPrefix("reply free") {
                handleDirectAvailabilityReply(isBusy: argL.hasPrefix("reply busy") || argL.hasPrefix("reply imessage"))
                return
            }
            // "join meeting"
            if argL.hasPrefix("join meeting") {
                if let meeting = CalendarEngine.shared.upcomingMeetings.first {
                    MeetingJoinEngine.shared.joinMeeting(meeting)
                    appendLog("Joining \(meeting.title)…", kind: .success)
                    state = .done
                } else {
                    appendLog("No upcoming meetings found.", kind: .error)
                    state = .error
                }
                return
            }
        }

        // Every model path from here needs the local model (Ollama running and
        // the chosen model pulled). There is no fallback: a degraded answer the
        // user can't tell apart from a real one is worse than an honest error,
        // so say exactly what's missing.
        guard OllamaConfig.isConfigured else {
            appendLog("\(OllamaConfig.notReadyMessage) \(trigger) needs the local model.", kind: .error)
            state = .error
            return
        }

        // Agentic action path: /run runs the local model + MCP tool-use loop, which can
        // take real, multi-step actions. Everything else is a single completion.
        if trigger == "/run" || (command == nil && ActionRequestIntent.matches(argument)) {
            await runAgentic(argument: argument, generation: generation)
            return
        }

        let prompt = buildActionPrompt(
            trigger: trigger,
            argument: argument,
            appName: appName,
            contextSummary: contextSummary,
            ocrText: ocrText
        )

        appendLog("Thinking…", kind: .step)
        let fullResponse: String
        do {
            fullResponse = try await OllamaClient.shared.complete(
                system: "You are Holmes, a direct AI assistant running on the user's Mac. Answer exactly what is asked, with no preamble.",
                user: prompt,
                maxTokens: 1024,
                priority: .agent)
        } catch OllamaClient.AgentError.serverUnreachable {
            guard isCurrent(generation) else { return }
            appendLog("Ollama isn't running — start it in Holmes ▸ Settings ▸ Local Model and try again.", kind: .error)
            state = .error
            Task { await OllamaServer.shared.refreshAfterFailure() }
            return
        } catch OllamaClient.AgentError.modelMissing(let model) {
            guard isCurrent(generation) else { return }
            appendLog("The local model \(model) isn't downloaded — download it in Holmes ▸ Settings ▸ Local Model.", kind: .error)
            state = .error
            Task { await OllamaServer.shared.refreshAfterFailure() }
            return
        } catch OllamaClient.AgentError.busy {
            guard isCurrent(generation) else { return }
            appendLog("The local model is busy — try again in a moment.", kind: .error)
            state = .error
            return
        } catch is CancellationError {
            guard isCurrent(generation) else { return }
            appendLog("Request cancelled", kind: .info)
            state = .idle
            if let activityID { WorkActivityCenter.shared.cancel(activityID, summary: "Request cancelled") }
            return
        } catch {
            guard isCurrent(generation) else { return }
            appendLog("Local model request failed — \(error.localizedDescription)", kind: .error)
            state = .error
            return
        }
        guard isCurrent(generation) else { return }

        // Final: split into lines for readability
        log = []
        let lines = fullResponse
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            appendLog(line, kind: .info)
        }
        if lines.isEmpty {
            appendLog("The local model returned an empty response.", kind: .error)
            state = .error
            return
        }

        state = .done

        // If we're in a messaging app and answered /ask, offer to send the reply
        let isMessaging = ["discord","slack","messages","mail","outlook","teams"]
            .contains(where: { appName.lowercased().contains($0) })
        let isAsk = trigger == "/ask"

        if isMessaging && isAsk && !fullResponse.isEmpty {
            let clean = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = PendingAction(
                title: "Send this reply on \(appName)",
                preview: clean,
                appName: appName,
                actionType: .typeMessage
            )
            ConfirmationBus.shared.propose(action)
        }
    }

    private func appendLog(_ text: String, kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
    }

    // MARK: - Agentic /run (local model + MCP tools)

    private func runAgentic(argument: String, generation: UUID) async {
        let goal = argument.isEmpty ? "Help me with what's on my screen right now." : argument
        let result = await HolmesBrain.shared.run(goal: goal) { [weak self] text in
            guard let self, self.isCurrent(generation) else { return }
            self.appendLog(text, kind: .info)
        }
        guard isCurrent(generation) else { return }
        switch result {
        case .notConfigured:
            appendLog("\(OllamaConfig.notReadyMessage) Agentic actions need the local model.", kind: .error)
            state = .error
        case .failed(let message):
            appendLog(message, kind: .error)
            state = .error
        case .cancelled:
            appendLog("Request cancelled", kind: .info)
            state = .idle
            if let activityID { WorkActivityCenter.shared.cancel(activityID, summary: "Request cancelled") }
        case .text(let final):
            if log.isEmpty { appendLog(final, kind: .success) }
            else { appendLog("Done.", kind: .success) }
            state = .done
        }
    }

    // MARK: - Grounded reply (ReplyComposer)

    /// Drafts a reply to the conversation actually on screen. Returns false when
    /// there is no readable thread — the caller then falls back to the canned
    /// availability line rather than inventing a recipient.
    private func draftGroundedReply(appName: String, generation: UUID) async -> Bool {
        guard OllamaConfig.isConfigured else { return false }
        guard MessagesReader.shared.isMessagesFrontmost(),
              let thread = MessagesReader.shared.readFrontmostThread(),
              let incoming = thread.messages.last(where: { !$0.isFromMe })
        else { return false }

        appendLog("Reading the conversation with \(thread.contact)…", kind: .step)

        let target = appName.isEmpty ? "Messages" : appName
        let message = ReplyComposer.IncomingMessage(
            surface: ReplyComposer.surfaceIMessage,
            sender: incoming.sender,
            text: incoming.text,
            threadID: thread.contact,
            app: target)

        // The user typed this command: it jumps the GPU queue instead of being
        // dropped as `.busy` behind a running playbook.
        let draft = await ReplyComposer.shared.draftReply(
            to: message, context: HolmesAgent.shared.live, priority: .agent)
        guard isCurrent(generation) else { return true }
        guard let draft else {
            appendLog("Couldn't draft a grounded reply. Try again after checking the local model.", kind: .error)
            state = .error
            return true
        }

        appendLog("Drafting: \"\(draft.body)\"", kind: .success)
        if !draft.groundedIn.isEmpty {
            appendLog("Grounded in \(draft.groundedIn.count) remembered note\(draft.groundedIn.count == 1 ? "" : "s").", kind: .info)
        }
        if draft.confidence != .exact {
            // The UI must not imply Holmes verified specifics it only inferred.
            appendLog("Context was \(draft.confidence.label.lowercased()) — check the details before sending.", kind: .info)
        }
        state = .done

        let action = PendingAction(
            title: "Reply to \(incoming.sender)",
            preview: draft.body,
            appName: target,
            actionType: .typeMessage
        )
        ConfirmationBus.shared.propose(action)
        return true
    }

    // MARK: - Direct availability reply (no model needed)

    private func handleDirectAvailabilityReply(isBusy: Bool) {
        let meetings = CalendarEngine.shared.upcomingMeetings
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let appName = ScreenEngine.shared.latestActiveApp.isEmpty ? "Messages" : ScreenEngine.shared.latestActiveApp
        let ocrText = HolmesAgent.shared.lastOCRText
        let sender = ContextEngine.shared.extractIMessageSenderPublic(from: ocrText)
            ?? ScreenEngine.shared.latestActiveWindowTitle

        let reply: String
        if let next = meetings.first {
            let time = f.string(from: next.startDate)
            reply = "No sorry, I have \(next.title) at \(time)"
        } else if isBusy {
            reply = "Busy right now, can we do later?"
        } else {
            reply = "Yeah I'm free! What's up?"
        }

        let title = sender.isEmpty ? "Reply on \(appName)" : "Reply to \(sender)"
        appendLog("Drafting: \"\(reply)\"", kind: .success)
        state = .done

        let action = PendingAction(
            title: title,
            preview: reply,
            appName: appName,
            actionType: .typeMessage
        )
        ConfirmationBus.shared.propose(action)
    }

    // MARK: - Action prompt builder

    private func buildActionPrompt(trigger: String, argument: String, appName: String, contextSummary: String, ocrText: String) -> String {
        // Strip the command trigger from the argument if present
        var userArg = argument
        for cmd in HolmesCommand.all {
            if userArg.lowercased().hasPrefix(cmd.trigger) {
                userArg = String(userArg.dropFirst(cmd.trigger.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // The tier travels with the text. Pasted raw, garbled OCR is
        // indistinguishable from a literal DOM read, and the model quotes
        // whatever it is handed — so the block announces which one it is.
        let quality = HolmesAgent.shared.lastTextConfidence.textReliabilityNote
        let screenContext = ocrText.isEmpty
            ? contextSummary
            : "(\(quality))\n" + String(ocrText.prefix(1200))
        let taskDesc = userArg.isEmpty ? contextSummary : userArg

        switch trigger {
        case "/ask":
            let question = userArg.isEmpty ? "What should I do next based on what's on my screen?" : userArg
            return """
You are Holmes, a direct AI assistant on macOS. The user is on \(appName).

Screen content:
\(screenContext)

Question: \(question)

Answer directly and concisely. No intro, no "I see that...", just the answer. Max 80 words.
"""

        case "/run":
            return """
You are Holmes, an AI assistant on macOS. The user is on \(appName).

Screen content:
\(screenContext)

Task to run: \(taskDesc)

Give a direct, numbered action plan. No intro. Max 5 steps, each under 12 words.
"""

        case "/plan":
            return """
You are Holmes on macOS. User is on \(appName).

Screen content:
\(screenContext)

Goal: \(taskDesc)

Output a numbered plan, max 6 steps. No intro. Each step under 10 words.
"""

        case "/watch":
            return """
You are Holmes on macOS. User is on \(appName).
Screen: \(contextSummary)
Task: Monitor \(taskDesc)

In 2-3 sentences: what to watch for and when to alert the user.
"""

        default:
            return """
You are Holmes on macOS. User is on \(appName).

Screen content:
\(screenContext)

Request: \(taskDesc)

Answer directly. No intro. Max 80 words.
"""
        }
    }
}
