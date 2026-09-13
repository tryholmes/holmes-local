//
//  ClickyController.swift
//  holmes
//
//  The "Clicky" product loop: press a hotkey, Holmes SEES your screen, you ask
//  OUT LOUD, and it ANSWERS out loud AND DRAWS on your screen to point the way —
//  or, if you tell it to DO the task ("agent…", "click…", "book…"), it hands off
//  to the computer-control agent.
//
//  This is the integrator that ties the built subsystems together:
//    • VoiceInputController  — push-to-talk, on-device speech → text.
//    • VisualGuidance        — screenshot → local model → spoken answer + annotations.
//    • VisualGuidanceOverlay — draws those annotations on the real screen.
//    • SpeechSynthesizer     — speaks the answer (ElevenLabs, else Apple voice).
//    • HolmesBrain           — the existing computer-control agent (the DO path).
//    • ScreenGlowController   — the ambient thinking/ready edge glow + haptics.
//
//  Explicit app-opening requests use macOS's native launcher. Other requests
//  use ASK/TEACH (answer + draw) or AGENT (HolmesBrain drives the Mac). Mouse and
//  keyboard actions remain behind ComputerUseEngine's master switch; ASK/TEACH
//  needs Screen Recording for the screenshot.
//
//  ── Attribution ────────────────────────────────────────────────────
//  The companion loop this orchestrates — global hotkey → dictate → decide
//  answer-and-point vs. do-the-task → speak + draw — is modeled on OpenClicky's
//  CompanionManager. OpenClicky — MIT License — © 2025 Jason Kneen.
//  See THIRD_PARTY_NOTICES.md.
//

import AVFoundation
import Foundation
import Speech

/// The Clicky loop. Startup only wires the transcript router. Capture requires
/// a current physical Fn hold; typed questions use the same answer/action router.
@MainActor
final class ClickyController {
    static let shared = ClickyController()

    // MARK: - Persisted preferences (honored here, toggled in Settings)

    enum Defaults {
        /// "Draw guidance on screen" — default ON.
        static let drawGuidance = "com.grain.holmes.clicky.drawGuidance"
        /// "Speak answers" — default ON.
        static let speakAnswers = "com.grain.holmes.clicky.speakAnswers"
        /// "Show Clicky on screen" — the glowing pointer ring drawn at each click/
        /// type point while Clicky acts. Default ON. Read by ComputerUseEngine.
        static let showPointer = "com.grain.holmes.clicky.showPointer"
        /// "Clicky narrates actions" — spoken step-by-step narration during agent /
        /// autonomous runs. Default ON. Read by AutonomousActionRunner + HolmesBrain.
        static let narrateActions = "com.grain.holmes.clicky.narrateActions"
    }

    /// Whether to draw the on-screen annotations. Defaults to true when unset.
    var drawGuidanceEnabled: Bool {
        UserDefaults.standard.object(forKey: Defaults.drawGuidance) as? Bool ?? true
    }

    /// Whether to speak answers aloud. Defaults to true when unset.
    var speakAnswersEnabled: Bool {
        UserDefaults.standard.object(forKey: Defaults.speakAnswers) as? Bool ?? true
    }

    /// Whether to draw the pointer ring as Clicky acts. Defaults to true when unset.
    var showPointerEnabled: Bool {
        UserDefaults.standard.object(forKey: Defaults.showPointer) as? Bool ?? true
    }

    /// Whether Clicky narrates what it's doing, step by step. Defaults to true.
    var narrateActionsEnabled: Bool {
        UserDefaults.standard.object(forKey: Defaults.narrateActions) as? Bool ?? true
    }

    private var isConfigured = false
    private var queryTask: Task<Void, Never>?
    private var queryGeneration = UUID()
    private var activityID: UUID?
    private var voiceHoldID: UUID?
    private var queryHoldID: UUID?

    private init() {}

    // MARK: - Lifecycle

    /// Wires voice input without creating audio hardware or prompting permissions.
    /// Idempotent — safe to call more than once.
    func start() {
        guard !isConfigured else { return }
        isConfigured = true

        // A finished dictation drives the same router as typed input.
        VoiceInputController.shared.onFinalTranscript = { [weak self] transcript in
            guard let self else { return }
            let holdID = self.voiceHoldID
            self.voiceHoldID = nil
            self.startQuery(transcript, holdID: holdID)
        }

    }

    /// Requests microphone + speech-recognition permission. Exposed so the Settings
    /// UI can offer an explicit "Enable microphone" button. Returns true only when
    /// BOTH are granted.
    func requestVoicePermission() async -> Bool {
        await VoiceInputController.shared.requestPermission()
    }

    /// True only when BOTH microphone and speech-recognition are already
    /// authorized. Read by the Settings UI to show a live permission status
    /// without prompting.
    var voicePermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Push-to-talk

    /// Only the physical hold that raised this callback may open the mic.
    /// Recheck after the AppDelegate's main-actor hop: the key may already be up.
    func beginPushToTalk(holdID: UUID) {
        guard HotkeyManager.shared.isPushToTalkHeld(holdID) else { return }
        cancelPendingQuery()
        voiceHoldID = holdID
        VoiceInputController.shared.beginListening(holdID: holdID)
    }

    func endPushToTalk(holdID: UUID) {
        VoiceInputController.shared.stopListening(holdID: holdID)
    }

    func cancelPushToTalk(holdID: UUID? = nil) {
        if let holdID, voiceHoldID != holdID, queryHoldID != holdID { return }
        voiceHoldID = nil
        VoiceInputController.shared.cancelListening(holdID: holdID)
        cancelPendingQuery()
    }

    // MARK: - Text entry (works without voice)

    /// Fire-and-forget entry point for typed questions (e.g. the command bar).
    /// Routes through the same two-mode router as voice.
    func askAloud(_ text: String) {
        _ = startQuery(text)
    }

    // MARK: - Router (Clicky's two modes)

    /// Handles explicit native app launches first, then routes questions to
    /// ASK/TEACH and other action requests to the AGENT pipeline.
    func handle(query: String) async {
        guard let task = startQuery(query) else { return }
        let generation = queryGeneration
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor in
                guard self.queryGeneration == generation else { return }
                self.cancelPendingQuery()
            }
        }
    }

    /// Cancelling after Fn-up still owns the released query, so a late model
    /// reply cannot restore speech, drawings, or a draft after sleep/new input.
    func cancelPendingQuery() {
        queryGeneration = UUID()
        queryTask?.cancel()
        queryTask = nil
        queryHoldID = nil
        if let activityID { WorkActivityCenter.shared.cancel(activityID) }
        activityID = nil
        SpeechSynthesizer.shared.stop()
        VisualGuidanceOverlay.shared.hide()
        ScreenGlowController.shared.set(state: .off)
    }

    @discardableResult
    private func startQuery(_ query: String, holdID: UUID? = nil) -> Task<Void, Never>? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        cancelPendingQuery()
        queryHoldID = holdID
        let generation = queryGeneration
        let id = WorkActivityCenter.shared.begin(title: "Your request", detail: trimmed, origin: .user)
        activityID = id
        let task = Task { @MainActor in
            await WorkActivityScope.$id.withValue(id) {
                await route(query: trimmed, generation: generation)
            }
            guard queryGeneration == generation else { return }
            if WorkActivityCenter.shared.isActive(id) {
                WorkActivityCenter.shared.cancel(id)
            }
            queryTask = nil
            queryHoldID = nil
            activityID = nil
        }
        queryTask = task
        WorkActivityCenter.shared.setCancellationHandler(id) { [weak self] in
            guard let self, self.queryGeneration == generation else { return }
            self.cancelPendingQuery()
        }
        return task
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        guard queryGeneration == generation, !Task.isCancelled, let activityID else { return false }
        return WorkActivityCenter.shared.isActive(activityID)
    }

    private func route(query trimmed: String, generation: UUID) async {
        guard isCurrent(generation) else { return }

        // Drafting produces an editable card and never falls through to screen
        // teaching or the computer-control agent, including missing-context errors.
        if EmailDraftCoordinator.shared.canHandle(trimmed) {
            ScreenGlowController.shared.set(state: .thinking)
            let result = await EmailDraftCoordinator.shared.request(instruction: trimmed)
            guard isCurrent(generation) else { return }
            switch result {
            case .ready(let summary):
                await completeQuery(summary, outcome: .success, generation: generation)
            case .needsContext(let message), .failed(let message):
                await completeQuery(message, outcome: .failure, generation: generation)
            case .cancelled:
                await completeQuery("Request cancelled", outcome: .cancelled, generation: generation)
            }
            return
        }

        // Opening an explicitly requested app is a native macOS operation. It
        // needs neither the model nor permission to post mouse/keyboard events.
        // Do this before the question heuristic, so "can you open Spotify?"
        // actually opens Spotify instead of asking the model to describe it.
        if let appName = AppLaunchIntent.appName(in: trimmed) {
            ScreenGlowController.shared.set(state: .thinking)
            let result = await AppLauncher.launch(named: appName)
            guard isCurrent(generation) else { return }
            await completeQuery(result.message, outcome: result.succeeded ? .success : .failure, generation: generation)
            return
        }

        if Self.isAgentIntent(trimmed) {
            await runAgent(goal: trimmed, generation: generation)
        } else {
            await runAskTeach(question: trimmed, generation: generation)
        }
    }

    // MARK: - ASK / TEACH (answer + draw; never clicks)

    /// Sees the screen, asks the local model for a spoken answer plus optional draw-on-screen
    /// annotations, then speaks the answer and paints the annotations. Needs only
    /// Screen Recording — no computer-control permission, because it never clicks.
    private func runAskTeach(question: String, generation: UUID) async {
        guard OllamaConfig.isConfigured else {
            await completeQuery(Self.notReadySpoken, outcome: .failure, generation: generation)
            return
        }

        ScreenGlowController.shared.set(state: .thinking)

        // Ground the answer in the current live context so it stays pinned to the
        // screen the user is actually looking at, never drifting to an off-screen topic.
        let grounding = HolmesAgent.shared.currentContext.description
        let result: VisualGuidance.Result
        do {
            result = try await VisualGuidance.answerResult(question: question, context: grounding)
        } catch is CancellationError {
            guard isCurrent(generation) else { return }
            await completeQuery("Request cancelled", outcome: .cancelled, generation: generation)
            return
        } catch {
            guard isCurrent(generation) else { return }
            await completeQuery(error.localizedDescription, outcome: .failure, generation: generation)
            return
        }
        guard isCurrent(generation) else { return }

        // Draw first (instant visual), then speak (which blocks until the answer
        // finishes playing). Hold the drawing at least as long as we expect the
        // answer to take to say (~15 chars/sec + a buffer), so the guidance stays
        // on screen while Holmes talks; it also hides on the next key/click.
        if drawGuidanceEnabled, !result.annotations.isEmpty {
            let spokenSeconds = Double(result.spokenAnswer.count) / 15.0 + 2.5
            VisualGuidanceOverlay.shared.show(
                result.annotations,
                mappedFrom: result.capture,
                autoHideAfter: max(6, spokenSeconds)
            )
        }

        await completeQuery(result.spokenAnswer.isEmpty ? "Guidance is ready on your screen" : result.spokenAnswer,
                            outcome: .success, generation: generation)
    }

    // MARK: - AGENT (does the task; computer control)

    /// Hands the goal to the existing computer-control agent. That path
    /// self-enforces the `ComputerUseEngine.isEnabled` master switch (and the
    /// per-action re-confirmation for irreversible steps) — this router never
    /// weakens it and never force-enables it. A short spoken confirmation bookends
    /// the run.
    private func runAgent(goal: String, generation: UUID) async {
        guard OllamaConfig.isConfigured else {
            await completeQuery(Self.notReadySpoken, outcome: .failure, generation: generation)
            return
        }

        ScreenGlowController.shared.set(state: .thinking)

        // Acknowledge immediately, but don't block the task on the ack — let "On it."
        // play WHILE the agent gets to work. The closing line supersedes it cleanly.
        if speakAnswersEnabled {
            SpeechSynthesizer.shared.enqueue("On it.", priority: .status)
        }

        let result = await HolmesBrain.shared.run(goal: goal, narrateAloud: false) { _ in
            // Voice flow doesn't need the live transcript; the command bar has its
            // own log path for that. narrateAloud:false — this router speaks its
            // own "On it."/"All done." bookends below, so run() must not double up.
        }

        guard isCurrent(generation) else { return }

        switch result {
        case .notConfigured:
            await completeQuery(Self.notReadySpoken, outcome: .failure, generation: generation)
        case .failed(let message):
            await completeQuery(message, outcome: .failure, generation: generation)
        case .cancelled:
            await completeQuery("Request cancelled", outcome: .cancelled, generation: generation)
        case .text(let message):
            await completeQuery(String(message.prefix(400)), outcome: .success, generation: generation)
        }
    }

    // MARK: - Helpers

    /// What Clicky says when the local model can't answer yet. Spoken, so it
    /// names the actual problem (Ollama not running / model not downloaded) in
    /// one plain sentence and points at the Settings pane that fixes it.
    private static var notReadySpoken: String {
        let why = OllamaConfig.lastProblem ?? "The local model isn't ready"
        return "\(why). You can fix that in Holmes settings, under Local Model."
    }

    /// The notch always receives an outcome, including when speech is disabled.
    /// Keep the owner alive through TTS so a new hold can cancel playback too.
    private func completeQuery(_ text: String, outcome: WorkActivityCenter.Outcome, generation: UUID) async {
        guard isCurrent(generation), let activityID else { return }
        ScreenGlowController.shared.set(state: outcome == .success ? .ready : .off)
        WorkActivityCenter.shared.update(activityID, phase: speakAnswersEnabled ? .speaking : .working, detail: text)
        if speakAnswersEnabled, outcome != .cancelled {
            await SpeechSynthesizer.shared.speak(text)
        }
        guard isCurrent(generation) else { return }
        WorkActivityCenter.shared.finish(activityID, outcome: outcome, summary: text)
    }

    /// Heuristic: does the user want Holmes to DO the task (agent / computer
    /// control) rather than answer a question about the screen? Clicky's rule is
    /// "say 'agent' and it does it"; we also catch the common imperative phrasings.
    static func isAgentIntent(_ query: String) -> Bool {
        ActionRequestIntent.matches(query)
    }
}
