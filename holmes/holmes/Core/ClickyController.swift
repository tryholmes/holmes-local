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
//    • VisualGuidance        — screenshot → Claude → spoken answer + annotations.
//    • VisualGuidanceOverlay — draws those annotations on the real screen.
//    • SpeechSynthesizer     — speaks the answer (ElevenLabs, else Apple voice).
//    • HolmesBrain           — the existing computer-control agent (the DO path).
//    • ScreenGlowController   — the ambient thinking/ready edge glow + haptics.
//
//  The router has Clicky's two modes: ASK/TEACH (answer + draw, never clicks) and
//  AGENT (HolmesBrain drives the Mac). Only the AGENT branch touches computer
//  control, and that path self-enforces the ComputerUseEngine master switch — the
//  ASK/TEACH branch needs only Screen Recording for the screenshot.
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

/// The Clicky loop. `start()` (called once from `AppDelegate`) wires voice input
/// into the router and warms up permissions. Push-to-talk is true hold-to-talk:
/// holding the Fn (globe) key calls `beginPushToTalk()` on key-down and
/// `endPushToTalk()` on key-up (see HotkeyManager's `.function`-flag monitor).
/// `togglePushToTalk()` remains for any press-to-start / press-to-stop caller
/// (e.g. a UI button). Typed input calls `handle(query:)` directly, so the whole
/// experience works with or without voice.
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

    private init() {}

    // MARK: - Lifecycle

    /// Wires voice input into the router and requests mic/speech permission once,
    /// so the first hold doesn't silently no-op on a not-yet-determined grant.
    /// Idempotent — safe to call more than once.
    func start() {
        guard !isConfigured else { return }
        isConfigured = true

        // A finished dictation drives the same router as typed input.
        VoiceInputController.shared.onFinalTranscript = { [weak self] transcript in
            guard let self else { return }
            Task { @MainActor in await self.handle(query: transcript) }
        }

        // Warm up permission up front (no-op if already granted / denied).
        Task { @MainActor in _ = await VoiceInputController.shared.requestPermission() }
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

    /// Key-DOWN: begin capturing. Ducks any answer currently being spoken (so the
    /// mic doesn't hear Holmes and the user isn't talked over) and clears a stale
    /// guidance overlay from a previous answer. Live state is observable via
    /// `VoiceInputController.shared.isListening` / `.partialTranscript` for any UI
    /// that wants to mirror the "listening…" indicator.
    func beginPushToTalk() {
        SpeechSynthesizer.shared.stop()
        VisualGuidanceOverlay.shared.hide()
        VoiceInputController.shared.startListening()
    }

    /// Key-UP: end capture. `stopListening()` fires `onFinalTranscript`, which
    /// routes the transcript into `handle(query:)`.
    func endPushToTalk() {
        VoiceInputController.shared.stopListening()
    }

    /// Press-to-start / press-to-stop, for a hotkey layer that only sees key-down
    /// (Carbon `RegisterEventHotKey`). First press begins, second press ends.
    func togglePushToTalk() {
        if VoiceInputController.shared.isListening {
            endPushToTalk()
        } else {
            beginPushToTalk()
        }
    }

    // MARK: - Text entry (works without voice)

    /// Fire-and-forget entry point for typed questions (e.g. the command bar).
    /// Routes through the same two-mode router as voice.
    func askAloud(_ text: String) {
        Task { @MainActor in await handle(query: text) }
    }

    // MARK: - Router (Clicky's two modes)

    /// Routes a query to either the ASK/TEACH pipeline (answer aloud + draw on
    /// screen) or the AGENT pipeline (HolmesBrain drives the Mac). This is the one
    /// place voice and text converge.
    func handle(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if Self.isAgentIntent(trimmed) {
            await runAgent(goal: trimmed)
        } else {
            await runAskTeach(question: trimmed)
        }
    }

    // MARK: - ASK / TEACH (answer + draw; never clicks)

    /// Sees the screen, asks Claude for a spoken answer plus optional draw-on-screen
    /// annotations, then speaks the answer and paints the annotations. Needs only
    /// Screen Recording — no computer-control permission, because it never clicks.
    private func runAskTeach(question: String) async {
        guard AnthropicConfig.isConfigured else {
            await speakIfEnabled("I need an Anthropic API key first. You can add one in Holmes settings.")
            return
        }

        ScreenGlowController.shared.set(state: .thinking)

        // Ground the answer in the current live context so it stays pinned to the
        // screen the user is actually looking at, never drifting to an off-screen topic.
        let grounding = HolmesAgent.shared.currentContext.description
        guard let result = await VisualGuidance.answer(question: question, context: grounding) else {
            ScreenGlowController.shared.set(state: .off)
            await speakIfEnabled("I couldn't get a read on your screen just now. Mind asking me again?")
            return
        }

        ScreenGlowController.shared.set(state: .ready)

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

        if !result.spokenAnswer.isEmpty {
            await speakIfEnabled(result.spokenAnswer)
        }
    }

    // MARK: - AGENT (does the task; computer control)

    /// Hands the goal to the existing computer-control agent. That path
    /// self-enforces the `ComputerUseEngine.isEnabled` master switch (and the
    /// per-action re-confirmation for irreversible steps) — this router never
    /// weakens it and never force-enables it. A short spoken confirmation bookends
    /// the run.
    private func runAgent(goal: String) async {
        guard AnthropicConfig.isConfigured else {
            await speakIfEnabled("I need an Anthropic API key first. You can add one in Holmes settings.")
            return
        }

        ScreenGlowController.shared.set(state: .thinking)

        // Acknowledge immediately, but don't block the task on the ack — let "On it."
        // play WHILE the agent gets to work. The closing line supersedes it cleanly.
        if speakAnswersEnabled {
            Task { @MainActor in SpeechSynthesizer.shared.enqueue("On it.", priority: .status) }
        }

        let result = await HolmesBrain.shared.run(goal: goal, narrateAloud: false) { _ in
            // Voice flow doesn't need the live transcript; the command bar has its
            // own log path for that. narrateAloud:false — this router speaks its
            // own "On it."/"All done." bookends below, so run() must not double up.
        }

        ScreenGlowController.shared.set(state: .ready)

        switch result {
        case .notConfigured:
            await speakIfEnabled("I need an Anthropic API key first. You can add one in Holmes settings.")
        case .text:
            // A short confirmation, not the whole transcript. If computer control
            // was off, HolmesBrain already narrated that in-run; this just closes
            // the loop.
            await speakIfEnabled("All done.")
        }
    }

    // MARK: - Helpers

    /// Speaks `text` only when "Speak answers" is on. Awaits completion so callers
    /// can sequence spoken lines without overlap.
    private func speakIfEnabled(_ text: String) async {
        guard speakAnswersEnabled else { return }
        await SpeechSynthesizer.shared.speak(text)
    }

    /// Heuristic: does the user want Holmes to DO the task (agent / computer
    /// control) rather than answer a question about the screen? Clicky's rule is
    /// "say 'agent' and it does it"; we also catch the common imperative phrasings.
    static func isAgentIntent(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }

        // Clicky's model is "say 'agent' and it does the task"; the DEFAULT is
        // ask/teach. The risk is asymmetric — a false AGENT drives the user's Mac,
        // a false ASK merely answers — so this defaults to ASK and only escalates
        // to AGENT on an unambiguous act-now signal.

        // (1) A QUESTION always answers, even if it happens to contain an action
        //     word ("how do I go to my downloads?", "can you explain this for me?").
        //     This guard runs first precisely to stop those from being misrouted.
        let firstWord = String(q.split(whereSeparator: { $0 == " " || $0 == "," }).first ?? "")
        let questionLeads: Set<String> = [
            "what", "whats", "what's", "how", "why", "where", "when", "who", "which",
            "can", "could", "would", "should", "is", "are", "do", "does", "did",
            "explain", "tell", "show", "describe", "summarize", "summarise", "help"
        ]
        if q.hasSuffix("?") || questionLeads.contains(firstWord) { return false }

        // (2) Explicit agent trigger — the sanctioned "agent, book me a table…".
        if q == "agent" || q.hasPrefix("agent ") || q.hasPrefix("agent,")
            || q.hasPrefix("hey clicky agent") || q.contains("holmes agent") {
            return true
        }

        // (3) A bare imperative that clearly asks Holmes to ACT now — only when the
        //     sentence STARTS with an action verb (not merely contains one) and it
        //     wasn't a question. Kept tight to avoid capturing statements.
        let leadingActVerbs: Set<String> = [
            "click", "type", "open", "book", "fill", "send", "buy", "order",
            "purchase", "install", "schedule", "compose", "navigate", "select",
            "press", "drag", "scroll", "paste", "submit", "download"
        ]
        if leadingActVerbs.contains(firstWord) { return true }

        // (4) Explicit "do it / do this for me" hand-off.
        if q.hasPrefix("do this") || q.hasPrefix("do it") || q.hasPrefix("just do") {
            return true
        }

        // Anything else → ask/teach (answer + draw). Safe default: never drives the Mac.
        return false
    }
}
