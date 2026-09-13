import Foundation
import Observation

/// Fixed examples keep the tour independent of the user's screen and memory.
enum GuidedDemoCase: String, CaseIterable, Identifiable {
    case openCalculator
    case summarizeNotes
    case draftReply

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openCalculator: return "Open an app"
        case .summarizeNotes: return "Summarize notes"
        case .draftReply: return "Draft a reply"
        }
    }

    var subtitle: String {
        switch self {
        case .openCalculator: return "An everyday action, in a moment."
        case .summarizeNotes: return "Turn a few notes into a clear next step."
        case .draftReply: return "Find the words, then make them yours."
        }
    }

    var symbol: String {
        switch self {
        case .openCalculator: return "plus.forwardslash.minus"
        case .summarizeNotes: return "text.alignleft"
        case .draftReply: return "square.and.pencil"
        }
    }

    var prompt: String {
        switch self {
        case .openCalculator: return "Open Calculator"
        case .summarizeNotes: return "Summarize these sample notes in three short bullets, including the next steps."
        case .draftReply: return "Draft a friendly, concise reply to this sample message. Use only the supplied reply notes."
        }
    }

    var sampleText: String {
        switch self {
        case .openCalculator: return "Calculator will open on your Mac."
        case .summarizeNotes:
            return """
            Sample project: neighborhood book swap
            • The event is Saturday, October 17, from 10 am to noon.
            • The community room is reserved.
            • Maya will bring signs and name tags.
            • Leo will set up the tables by 9:30 am.
            • Next step: send the volunteer reminder by Thursday.
            """
        case .draftReply:
            return """
            Sample message from Alex:
            “Can you help set up the book swap on Saturday? We could use a hand with the tables at 9:30.”

            Sample reply notes:
            You can help and will arrive at 9:30. You can bring name tags, too. Ask how many are needed.
            """
        }
    }

    var expectation: String {
        switch self {
        case .openCalculator: return "Holmes opens Calculator. No model or screen permissions are needed."
        case .summarizeNotes: return "Your model summarizes the sample below. This example uses no screen content or saved memories."
        case .draftReply: return "Your model writes a draft here for you to review and edit. Nothing is sent."
        }
    }

    var resultTitle: String {
        switch self {
        case .openCalculator: return "App opened"
        case .summarizeNotes: return "Your summary"
        case .draftReply: return "Your draft"
        }
    }

    var runLabel: String {
        switch self {
        case .openCalculator: return "Open Calculator"
        case .summarizeNotes: return "Summarize sample notes"
        case .draftReply: return "Draft sample reply"
        }
    }

    var requiresModel: Bool { self != .openCalculator }

    fileprivate var systemPrompt: String {
        switch self {
        case .openCalculator: return ""
        case .summarizeNotes:
            return "You are Holmes. Summarize only the supplied fictional sample notes in three concise bullets. Preserve names, times, and next steps. Do not invent facts. Return only the summary."
        case .draftReply:
            return "You are Holmes. Write a friendly, concise draft using only the supplied fictional message and reply notes. Return only the draft text. Do not claim that the reply has been sent or that any action has been performed."
        }
    }

    fileprivate var modelInput: String { prompt + "\n\n" + sampleText }
}

@MainActor
@Observable
final class GuidedDemoModel {
    static let onboardingCompletedKey = "hasCompletedOnboarding"
    static let hasSeenDemoKey = "hasSeenGuidedDemo"
    static let completedCasesKey = "guidedDemo.completedCases"

    /// Only these two execution paths exist: a native app launch and a plain
    /// text completion. No screen capture, memory lookup, agent tools or send.
    struct Dependencies {
        var isModelReady: @MainActor () -> Bool
        var modelNotReadyMessage: @MainActor () -> String
        var launchCalculator: @MainActor () async -> AppLaunchResult
        var complete: @MainActor (_ system: String, _ user: String) async throws -> String

        static var live: Dependencies {
            Dependencies(
                isModelReady: { OllamaConfig.isConfigured },
                modelNotReadyMessage: { OllamaConfig.notReadyMessage },
                launchCalculator: { await AppLauncher.launch(named: "Calculator") },
                complete: { system, user in
                    try await OllamaClient.shared.complete(
                        system: system, user: user, maxTokens: 512,
                        imageBase64: nil, priority: .agent)
                })
        }
    }

    var selectedCase: GuidedDemoCase = .openCalculator {
        didSet {
            if selectedCase != oldValue { cancel() }
        }
    }
    private(set) var outputs: [GuidedDemoCase: String] = [:]
    private(set) var errors: [GuidedDemoCase: String] = [:]
    private(set) var completedCases: Set<GuidedDemoCase>
    private(set) var runningCase: GuidedDemoCase?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?

    init(defaults: UserDefaults = .standard, dependencies: Dependencies = .live) {
        self.defaults = defaults
        self.dependencies = dependencies
        completedCases = Set((defaults.stringArray(forKey: Self.completedCasesKey) ?? [])
            .compactMap(GuidedDemoCase.init(rawValue:)))
    }

    var completedCount: Int { completedCases.count }

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: onboardingCompletedKey) && !defaults.bool(forKey: hasSeenDemoKey)
    }

    static func markPresented(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasSeenDemoKey)
    }

    func select(_ example: GuidedDemoCase) {
        selectedCase = example
    }

    func runSelected() {
        guard runningCase == nil else { return }
        let example = selectedCase
        errors.removeValue(forKey: example)
        outputs.removeValue(forKey: example)

        guard !example.requiresModel || dependencies.isModelReady() else {
            errors[example] = dependencies.modelNotReadyMessage()
                + " Open Settings → Local Model to finish setup, then try this example again."
            return
        }

        let id = UUID()
        let dependencies = dependencies
        runID = id
        runningCase = example
        runTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let text: String
                if example == .openCalculator {
                    let result = await dependencies.launchCalculator()
                    guard result.succeeded else {
                        self?.finish(id: id, example: example, error: result.message)
                        return
                    }
                    text = result.message
                } else {
                    text = try await dependencies.complete(example.systemPrompt, example.modelInput)
                }
                try Task.checkCancellation()
                self?.finish(id: id, example: example, output: text)
            } catch is CancellationError {
                // A cancelled request may finish after a retry has begun.
                self?.finishCancellation(id: id)
            } catch {
                self?.finish(id: id, example: example, error: error.localizedDescription)
            }
        }
    }

    /// Cancel before changing examples or closing the tour. App launches that
    /// macOS has already accepted cannot be undone; their late result is ignored.
    func cancel() {
        runID = nil
        runTask?.cancel()
        runTask = nil
        runningCase = nil
    }

    /// Editing the returned draft is local UI state, never evidence of a run.
    func updateOutput(_ text: String, for example: GuidedDemoCase) {
        guard outputs[example] != nil, runningCase != example else { return }
        outputs[example] = text
    }

    private func finish(id: UUID, example: GuidedDemoCase, output: String? = nil, error: String? = nil) {
        guard runID == id else { return }
        defer {
            runID = nil
            runTask = nil
            runningCase = nil
        }
        if let error {
            errors[example] = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This example couldn't finish. Try again." : error
            return
        }
        let text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errors[example] = "The local model returned an empty response. Try this example again."
            return
        }
        outputs[example] = text
        completedCases.insert(example)
        defaults.set(completedCases.map(\.rawValue).sorted(), forKey: Self.completedCasesKey)
    }

    private func finishCancellation(id: UUID) {
        guard runID == id else { return }
        runID = nil
        runTask = nil
        runningCase = nil
    }
}
