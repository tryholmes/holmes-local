import Foundation
import SwiftUI

// Boundary doubles keep these tests on the production entry-point code while
// excluding microphone, screen capture, app launches, model servers, and TTS.
@MainActor final class VoiceInputController {
    static let shared = VoiceInputController()
    var onFinalTranscript: ((String) -> Void)?
    var transcriptOnRelease = ""
    var starts = 0
    func requestPermission() async -> Bool { true }
    func beginListening(holdID: UUID) { starts += 1 }
    func stopListening(holdID: UUID) {
        if !transcriptOnRelease.isEmpty { onFinalTranscript?(transcriptOnRelease) }
    }
    func cancelListening(holdID: UUID? = nil) {}
}
@MainActor final class HotkeyManager {
    static let shared = HotkeyManager()
    var heldID: UUID?
    func isPushToTalkHeld(_ id: UUID) -> Bool { heldID == id }
}
enum EmailDraftOutcome { case ready(String), needsContext(String), failed(String), cancelled }
@MainActor final class EmailDraftCoordinator {
    static let shared = EmailDraftCoordinator()
    var isEmailContext = true
    var requests: [String] = []
    var inheritedIDs: [UUID?] = []
    var handler: (String) async -> EmailDraftOutcome = { _ in .ready("Email draft ready to edit") }
    func canHandle(_ query: String) -> Bool { EmailDraftIntent.matches(query, isEmailContext: isEmailContext) }
    func request(instruction: String, context: Int? = nil) async -> EmailDraftOutcome {
        requests.append(instruction)
        inheritedIDs.append(WorkActivityScope.id)
        return await handler(instruction)
    }
}
@MainActor enum VisualGuidance {
    struct Result { let spokenAnswer: String; let annotations: [String]; let capture: String }
    static var questions: [String] = []
    static var handler: (String) async throws -> Result = { _ in Result(spokenAnswer: "Screen answer", annotations: [], capture: "screen") }
    static func answerResult(question: String, context: String) async throws -> Result {
        questions.append(question)
        return try await handler(question)
    }
}
@MainActor final class VisualGuidanceOverlay {
    static let shared = VisualGuidanceOverlay()
    var shown: [[String]] = []
    func hide() {}
    func show(_ annotations: [String], mappedFrom: String, autoHideAfter: Double) { shown.append(annotations) }
}
@MainActor final class SpeechSynthesizer {
    enum Priority { case status }
    static let shared = SpeechSynthesizer()
    var spoken: [String] = []
    func stop() {}
    func enqueue(_ text: String, priority: Priority) { spoken.append(text) }
    func speak(_ text: String) async { spoken.append(text) }
}
@MainActor final class ScreenGlowController {
    enum State { case thinking, ready, off }
    static let shared = ScreenGlowController()
    var state: State = .off
    func set(state: State) { self.state = state }
}
@MainActor final class HolmesBrain {
    enum RunResult { case notConfigured, text(String), failed(String), cancelled }
    static let shared = HolmesBrain()
    var goals: [String] = []
    var result: RunResult = .text("Action finished")
    func run(goal: String, narrateAloud: Bool = true, log: @escaping @MainActor (String) -> Void) async -> RunResult {
        goals.append(goal)
        return result
    }
}
@MainActor final class HolmesAgent {
    struct Context { var appName = "Mail"; var description = "Email compose window" }
    struct Confidence { var textReliabilityNote = "Direct text" }
    static let shared = HolmesAgent()
    var currentContext = Context()
    var lastOCRText = ""
    var lastTextConfidence = Confidence()
    var live = 0
}
@MainActor final class ScreenEngine {
    static let shared = ScreenEngine()
    var latestActiveApp = "Mail"
    var latestActiveWindowTitle = "Compose"
}
@MainActor enum AppLauncher {
    struct Result { let message: String; let succeeded: Bool }
    static func launch(named: String) async -> Result { Result(message: "Opened \(named)", succeeded: true) }
}
enum OllamaConfig {
    static var isConfigured = true
    static var lastProblem: String? = "Local model unavailable"
    static var notReadyMessage = "Local model unavailable"
}
@MainActor final class OllamaClient {
    enum Priority { case agent, background }
    enum AgentError: Error { case serverUnreachable(String), modelMissing(String), busy }
    static let shared = OllamaClient()
    var prompts: [String] = []
    func complete(system: String, user: String, maxTokens: Int, priority: Priority) async throws -> String {
        prompts.append(user)
        return "A plan or answer"
    }
}
@MainActor final class OllamaServer {
    static let shared = OllamaServer()
    func refreshAfterFailure() async {}
}
@MainActor final class CommandBus {
    static let shared = CommandBus()
    func consume() -> String? { nil }
}
struct PendingAction {
    enum ActionType { case typeMessage }
    let title: String
    let preview: String
    let appName: String
    let actionType: ActionType
}
@MainActor final class ConfirmationBus {
    static let shared = ConfirmationBus()
    var proposals: [PendingAction] = []
    func propose(_ action: PendingAction) { proposals.append(action) }
}
@MainActor final class CalendarEngine {
    struct Meeting { let title: String; let startDate: Date }
    static let shared = CalendarEngine()
    var upcomingMeetings: [Meeting] = []
}
@MainActor final class MeetingJoinEngine {
    static let shared = MeetingJoinEngine()
    func joinMeeting(_ meeting: CalendarEngine.Meeting) {}
}
@MainActor final class ContextEngine {
    static let shared = ContextEngine()
    func extractIMessageSenderPublic(from: String) -> String? { nil }
}
@MainActor final class MessagesReader {
    struct Message { let sender: String; let text: String; let isFromMe: Bool }
    struct Thread { let messages: [Message]; let contact: String }
    static let shared = MessagesReader()
    func isMessagesFrontmost() -> Bool { false }
    func readFrontmostThread() -> Thread? { nil }
}
@MainActor final class ReplyComposer {
    struct IncomingMessage { let surface: String; let sender: String; let text: String; let threadID: String; let app: String }
    enum Confidence { case exact; var label: String { "Exact" } }
    struct Draft { let body: String; let groundedIn: [String]; let confidence: Confidence }
    static let surfaceIMessage = "imessage"
    static let shared = ReplyComposer()
    func draftReply(to: IncomingMessage, context: Int, priority: OllamaClient.Priority) async -> Draft? { nil }
}
extension Color { init(hex: String) { self = .black } }

/// A deliberately cancellation-insensitive provider: cancelling the caller is
/// observed, but an old result still arrives later to test publication guards.
@MainActor final class HeldReply<Value> {
    var started = false
    var cancelled = false
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                started = true
            }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
    }
    func release(_ result: Value) {
        let pending = continuation
        continuation = nil
        precondition(pending != nil)
        pending?.resume(returning: result)
    }
}

@main
struct RequestRoutingTests {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        let speechKey = ClickyController.Defaults.speakAnswers
        let oldSpeech = defaults.object(forKey: speechKey)
        defaults.set(false, forKey: speechKey)
        defer {
            if let oldSpeech { defaults.set(oldSpeech, forKey: speechKey) }
            else { defaults.removeObject(forKey: speechKey) }
        }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let center = WorkActivityCenter.shared
        let clicky = ClickyController.shared
        let drafts = EmailDraftCoordinator.shared
        clicky.start()
        center.invalidateAll()

        // Draft routing precedes model readiness and never falls back to screen
        // teaching, even when the coordinator needs a real compose window.
        OllamaConfig.isConfigured = false
        drafts.handler = { _ in .needsContext("Open the email compose window first") }
        await clicky.handle(query: "Can you draft this email?")
        expect(drafts.requests.count == 1, "Voice drafting must reach coordinator before model readiness")
        expect(center.completion?.outcome == .failure, "Missing email context must be visible with TTS disabled")
        expect(center.completion?.summary == "Open the email compose window first", "Preserve actionable missing-context reason")
        expect(VisualGuidance.questions.isEmpty && HolmesBrain.shared.goals.isEmpty, "Missing-context drafting must not fall through")
        expect(center.activeCount == 0, "Missing context must end the owned request")

        OllamaConfig.isConfigured = true
        drafts.handler = { _ in .ready("Email draft ready to edit") }
        await clicky.handle(query: "could you please write it for me?")
        expect(drafts.requests.last == "could you please write it for me?", "Contextual polite writing request reaches draft coordinator intact")
        expect(drafts.inheritedIDs.last! != nil, "Voice passes its work owner to draft generation")
        expect(center.completion?.outcome == .success && center.activeCount == 0, "Ready draft ends its single owner")
        expect(ConfirmationBus.shared.proposals.isEmpty, "Voice router must not publish a duplicate draft card")

        drafts.handler = { _ in .failed("The local model could not generate a draft") }
        await clicky.handle(query: "draft an email")
        expect(center.completion?.outcome == .failure, "Draft failure must not become a ready glow/success")
        expect(ScreenGlowController.shared.state == .off, "Failed voice requests turn off the ready glow")
        expect(VisualGuidance.questions.isEmpty && HolmesBrain.shared.goals.isEmpty, "Draft errors cannot invoke general guidance or agent")

        HolmesBrain.shared.result = .failed("Computer control is disabled")
        await clicky.handle(query: "Could you click Save?")
        expect(HolmesBrain.shared.goals.last == "Could you click Save?", "Polite action routes into the existing guarded Brain")
        expect(center.completion?.outcome == .failure, "Brain failure stays a visible failure")
        await clicky.handle(query: "How do I click Save?")
        expect(VisualGuidance.questions.last == "How do I click Save?", "How-to questions remain guidance")

        // A new physical hold invalidates an already-released question before
        // its late screen response can redraw overlays or resume TTS.
        defaults.set(true, forKey: speechKey)
        let heldGuidance = HeldReply<VisualGuidance.Result>()
        VisualGuidance.handler = { _ in await heldGuidance.wait() }
        clicky.askAloud("What is on my screen?")
        await eventually { heldGuidance.started }
        let heldID = UUID()
        HotkeyManager.shared.heldID = heldID
        clicky.beginPushToTalk(holdID: heldID)
        await eventually { heldGuidance.cancelled }
        expect(center.activeCount == 0, "A new hold clears ownership of the old released query")
        let overlaysBefore = VisualGuidanceOverlay.shared.shown.count
        let speechBefore = SpeechSynthesizer.shared.spoken.count
        let revisionBefore = center.revision
        heldGuidance.release(.init(spokenAnswer: "Stale answer", annotations: ["stale circle"], capture: "old screen"))
        await drain()
        expect(VisualGuidanceOverlay.shared.shown.count == overlaysBefore, "Late guidance cannot restore an overlay after a new hold")
        expect(SpeechSynthesizer.shared.spoken.count == speechBefore, "Late guidance cannot resume speech")
        expect(center.revision == revisionBefore, "Old query completion cannot mutate the new activity epoch")

        // Fn-up submits the captured transcript and does not immediately cancel
        // the newly created model/draft task.
        let heldDraft = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await heldDraft.wait() }
        VoiceInputController.shared.transcriptOnRelease = "Can you draft this email?"
        clicky.endPushToTalk(holdID: heldID)
        await eventually { heldDraft.started }
        expect(!heldDraft.cancelled && center.activeCount == 1, "Fn-up must keep the submitted draft alive")
        clicky.cancelPushToTalk(holdID: UUID())
        expect(!heldDraft.cancelled && center.activeCount == 1, "A cancellation for another hold must not cancel the submitted query")
        heldDraft.release(.ready("Voice draft ready"))
        await eventually { center.activeCount == 0 }
        expect(center.completion?.summary == "Voice draft ready", "Released voice draft reaches terminal success")

        // Lifecycle cancellation must reach a released query even when no
        // physical hold ID remains, and cancellation reaches the nested await.
        let sleepingDraft = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await sleepingDraft.wait() }
        clicky.askAloud("Draft an email")
        await eventually { sleepingDraft.started }
        clicky.cancelPushToTalk()
        await eventually { sleepingDraft.cancelled }
        let afterSleep = center.revision
        sleepingDraft.release(.ready("Old draft after sleep"))
        await drain()
        expect(center.revision == afterSleep && center.activeCount == 0, "Sleep cancellation discards a late released draft")

        let cancelledHandle = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await cancelledHandle.wait() }
        let handleTask = Task { await clicky.handle(query: "Draft an email") }
        await eventually { cancelledHandle.started }
        handleTask.cancel()
        await eventually { cancelledHandle.cancelled && center.activeCount == 0 }
        cancelledHandle.release(.ready("Cancelled handle result"))
        await handleTask.value
        expect(center.activeCount == 0, "Cancellation of the async handle reaches the owned query task")

        let stoppedVoice = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await stoppedVoice.wait() }
        clicky.askAloud("Draft an email")
        await eventually { stoppedVoice.started }
        center.cancelSelected()
        await eventually { stoppedVoice.cancelled }
        expect(center.activeCount == 0 && center.completion?.outcome == .cancelled, "Notch Stop cancels the actual voice query owner")
        let stoppedRevision = center.revision
        stoppedVoice.release(.ready("Voice result after Stop"))
        await drain()
        expect(center.revision == stoppedRevision, "Stopped voice results cannot revive their old owner")

        let typed = CommandViewModel()
        drafts.handler = { _ in .ready("Typed email draft ready") }
        for query in ["Can you draft this email?", "/ask write this email", "/run draft an email"] {
            typed.onInputChange(query)
            typed.submit()
            await eventually { center.activeCount == 0 }
            expect(typed.state == .done, "Typed draft must finish: \(query)")
            expect(typed.log.last?.text == "Typed email draft ready", "Typed route preserves coordinator outcome")
        }
        expect(ConfirmationBus.shared.proposals.isEmpty, "Typed drafting must not publish a second send/type card")
        let draftCount = drafts.requests.count
        typed.onInputChange("/plan draft an email")
        typed.submit()
        await eventually { center.activeCount == 0 }
        expect(drafts.requests.count == draftCount, "Explicit /plan must not become a draft")
        expect(OllamaClient.shared.prompts.last?.contains("Goal: draft an email") == true, "Explicit /plan retains planning prompt")

        // A reset cancels the actual task and prevents its result from restoring
        // output or completing the next request with old text.
        let resetDraft = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await resetDraft.wait() }
        typed.onInputChange("write an email")
        typed.submit()
        await eventually { resetDraft.started }
        typed.reset()
        await eventually { resetDraft.cancelled }
        resetDraft.release(.ready("Stale typed draft"))
        await drain()
        expect(typed.state == .idle && typed.log.isEmpty && !typed.showOutput, "Typed reset must suppress late output")
        expect(center.activeCount == 0, "Typed reset leaves no active work")

        let stoppedTyped = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await stoppedTyped.wait() }
        typed.onInputChange("write an email")
        typed.submit()
        await eventually { stoppedTyped.started }
        center.cancelSelected()
        await eventually { stoppedTyped.cancelled }
        expect(typed.state == .idle && typed.log.last?.text == "Request stopped.", "Notch Stop cancels the typed await and clears running UI")
        stoppedTyped.release(.ready("Typed result after Stop"))
        await drain()
        expect(typed.log.last?.text == "Request stopped." && center.activeCount == 0, "Stopped typed result cannot restore output or activity")

        let supersededDraft = HeldReply<EmailDraftOutcome>()
        drafts.handler = { _ in await supersededDraft.wait() }
        typed.onInputChange("draft the first email")
        typed.submit()
        await eventually { supersededDraft.started }
        drafts.handler = { _ in .ready("Latest typed draft ready") }
        typed.onInputChange("draft the second email")
        typed.submit()
        await eventually { supersededDraft.cancelled && center.activeCount == 0 }
        supersededDraft.release(.ready("Superseded typed draft"))
        await drain()
        expect(typed.log.last?.text == "Latest typed draft ready", "An old typed result cannot overwrite the new request")
        expect(center.completion?.summary == "Latest typed draft ready", "Old task cleanup cannot finish or hide the newer activity")

        drafts.handler = { _ in .failed("Draft model failed") }
        typed.onInputChange("draft an email")
        typed.submit()
        await eventually { center.activeCount == 0 }
        expect(typed.state == .error && typed.log.last?.text == "Draft model failed", "Typed failure preserves coordinator reason")
        expect(center.completion?.outcome == .failure, "Typed draft failure remains a failed activity")
        print("Passed \(checks) production voice/typed routing and cancellation checks")
    }

    @MainActor private static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for request routing transition")
    }
    private static func drain() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
