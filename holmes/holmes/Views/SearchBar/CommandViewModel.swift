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
        guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = inputText.trimmingCharacters(in: .whitespaces)
        matchedCommand = resolveCommand(from: text)
        suggestions = []
        runCommand(text)
    }

    func reset() {
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
        HolmesCommand.all.first { text.lowercased().hasPrefix($0.trigger) }
    }

    private func runCommand(_ text: String) {
        state = .running
        showOutput = true
        log = []

        let cmd = matchedCommand
        let arg = text.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)

        Task {
            await executeWithLLM(command: cmd, argument: arg)
        }
    }

    // MARK: - Real LLM execution

    private func executeWithLLM(command: HolmesCommand?, argument: String) async {
        let agent = HolmesAgent.shared
        let appName = agent.currentContext.appName.isEmpty
            ? ScreenEngine.shared.latestActiveApp
            : agent.currentContext.appName
        let contextSummary = agent.currentContext.description
        let ocrText = agent.lastOCRText
        let trigger = command?.trigger ?? "/ask"

        // ── Instant commands: bypass Ollama entirely ──────────────────────────
        // These work even when Ollama is offline.
        let argL = argument.lowercased()
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

        if !LocalModelEngine.shared.isAvailable {
            // Re-probe in case Ollama was started after Holmes launched
            await LocalModelEngine.shared.probe()
        }
        if !LocalModelEngine.shared.isAvailable {
            appendLog("Ollama not running. Start it with: ollama serve", kind: .error)
            state = .error
            return
        }

        let prompt = buildActionPrompt(
            trigger: trigger,
            argument: argument,
            appName: appName,
            contextSummary: contextSummary,
            ocrText: ocrText
        )

        // Stream tokens directly into one growing text block — no thinking noise
        var fullResponse = ""
        var displayedLines: Set<String> = []

        _ = await LocalModelEngine.shared.generate(prompt: prompt) { [weak self] token in
            guard let self else { return }
            fullResponse += token

            // Update the last log line live (streaming feel)
            let clean = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.log.isEmpty {
                self.log.append(LogLine(text: clean, kind: .info))
            } else {
                self.log[self.log.count - 1] = LogLine(text: clean, kind: .info)
            }
        }

        // Final: split into lines for readability
        log = []
        let lines = fullResponse
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            appendLog(line, kind: .info)
        }

        state = .done

        // If we're in a messaging app and answered /ask, offer to send the reply
        let isMessaging = ["discord","slack","messages","mail","outlook","teams"]
            .contains(where: { appName.lowercased().contains($0) })
        let isAsk = trigger == "/ask"

        if isMessaging && isAsk && !fullResponse.isEmpty {
            let clean = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let action = PendingAction(
                    title: "Send this reply on \(appName)",
                    preview: clean,
                    appName: appName,
                    actionType: .typeMessage
                )
                ConfirmationBus.shared.propose(action)
            }
        }
    }

    private func appendLog(_ text: String, kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
    }

    // MARK: - Direct availability reply (no Ollama needed)

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let action = PendingAction(
                title: title,
                preview: reply,
                appName: appName,
                actionType: .typeMessage
            )
            ConfirmationBus.shared.propose(action)
        }
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

        let screenContext = ocrText.isEmpty ? contextSummary : String(ocrText.prefix(1200))
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


