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

        simulateExecution(command: cmd, argument: arg)
    }

    // Simulated streaming execution — replace with real API calls
    private func simulateExecution(command: HolmesCommand?, argument: String) {
        let lines: [LogLine]

        switch command?.trigger {
        case "/run":
            let task = argument.isEmpty ? "task" : argument
            lines = [
                LogLine(text: "Preparing to run: \(task)", kind: .info),
                LogLine(text: "Analyzing current context...", kind: .step),
                LogLine(text: "Detecting active app and screen state", kind: .step),
                LogLine(text: "Building execution plan", kind: .step),
                LogLine(text: "Executing \(task)", kind: .info),
                LogLine(text: "Done", kind: .success),
            ]
        case "/watch":
            lines = [
                LogLine(text: "Starting screen monitor", kind: .info),
                LogLine(text: "Capturing screen state every 3s", kind: .step),
                LogLine(text: "Watching for changes...", kind: .info),
            ]
        case "/ask":
            let q = argument.isEmpty ? "your question" : argument
            lines = [
                LogLine(text: "Processing: \(q)", kind: .info),
                LogLine(text: "Searching knowledge base", kind: .step),
                LogLine(text: "Generating answer", kind: .step),
                LogLine(text: "Ready", kind: .success),
            ]
        case "/plan":
            let goal = argument.isEmpty ? "goal" : argument
            lines = [
                LogLine(text: "Planning: \(goal)", kind: .info),
                LogLine(text: "Step 1 — Identify requirements", kind: .step),
                LogLine(text: "Step 2 — Break into sub-tasks", kind: .step),
                LogLine(text: "Step 3 — Estimate effort", kind: .step),
                LogLine(text: "Plan ready", kind: .success),
            ]
        case "/done":
            lines = [
                LogLine(text: "Marking task complete", kind: .info),
                LogLine(text: "Logging to activity history", kind: .step),
                LogLine(text: "Task closed", kind: .success),
            ]
        default:
            lines = [
                LogLine(text: "Running: \(argument)", kind: .info),
                LogLine(text: "Processing...", kind: .step),
                LogLine(text: "Done", kind: .success),
            ]
        }

        // Stream lines in with delays
        for (i, line) in lines.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { [weak self] in
                guard let self else { return }
                self.log.append(line)
                if i == lines.count - 1 {
                    self.state = line.kind == .error ? .error : .done
                }
            }
        }
    }
}


