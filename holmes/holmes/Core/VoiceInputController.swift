//
//  VoiceInputController.swift
//  holmes
//
//  Push-to-talk (hold-to-talk) speech input using Apple's on-device Speech
//  framework. No API key, no network round-trip: SFSpeechRecognizer runs the
//  transcription on-device whenever the model supports it, streaming live
//  partial results while the user holds the hotkey and delivering the best
//  final transcript on release.
//
//  The push-to-talk dictation approach here — live SFSpeechAudioBufferRecognition
//  streaming, the on-device recognition flag, and the final-transcript fallback
//  timer that guarantees delivery even when SFSpeech never emits `isFinal` — is
//  ported from OpenClicky's BuddyDictationManager / AppleSpeechTranscriptionProvider
//  and adapted to Holmes's single-provider, @MainActor @Observable conventions.
//
//  Derived from OpenClicky (MIT License, © 2025 Jason Kneen).
//  See THIRD_PARTY_NOTICES.md.
//

import AVFoundation
import Foundation
import Observation
import Speech

/// Hold-to-talk microphone dictation, driven entirely by the Speech framework.
///
/// The hotkey wiring is the integrator's job — this type only exposes
/// `startListening()` / `stopListening()` / `toggle()` for a shortcut monitor to
/// call on key-down / key-up. `isListening` and `partialTranscript` are
/// observable so a SwiftUI overlay can mirror the live transcription; the
/// finished text arrives once through `onFinalTranscript`.
@Observable
@MainActor
final class VoiceInputController {

    // MARK: Shared

    static let shared = VoiceInputController()

    // MARK: Observable state

    /// True from the moment `startListening()` begins capturing until the
    /// session ends (either `stopListening()` finalizes or an error tears it
    /// down). Flips to false the instant capture stops, before the final
    /// transcript is delivered, so UI can react on key-release without waiting
    /// for SFSpeech to flush.
    private(set) var isListening = false

    /// The most recent partial transcription, updated live while listening.
    /// Cleared to empty when a session ends.
    private(set) var partialTranscript = ""

    /// Fired exactly once per session with the final, non-empty transcript.
    /// Not fired when nothing intelligible was said.
    @ObservationIgnored
    var onFinalTranscript: ((String) -> Void)?

    // MARK: Private machinery

    @ObservationIgnored private let recognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasInstalledTap = false

    /// Set while `stopListening()` waits for SFSpeech to emit the final result.
    @ObservationIgnored private var isFinalizing = false
    /// Guards `deliverFinal(_:)` so the final transcript fires at most once,
    /// whether it arrives via `isFinal`, an error, or the fallback timer.
    @ObservationIgnored private var hasDeliveredFinal = false
    @ObservationIgnored private var latestTranscript = ""
    /// Guarantees delivery if SFSpeech never emits `isFinal` after `endAudio()`.
    @ObservationIgnored private var finalizeFallback: DispatchWorkItem?

    /// How long to wait after `endAudio()` for a real `isFinal` result before
    /// falling back to the latest partial transcript.
    @ObservationIgnored private let finalTranscriptFallbackDelay: TimeInterval = 1.5

    private init() {}

    // MARK: Permissions

    /// Requests microphone and speech-recognition authorization. Returns true
    /// only when BOTH are granted. Safe to call repeatedly; already-granted
    /// permissions resolve immediately without re-prompting.
    func requestPermission() async -> Bool {
        guard await requestMicrophoneAccess() else { return false }
        return await requestSpeechRecognitionAccess()
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private var hasRequiredPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: Control

    /// Begins live on-device transcription from the microphone. Idempotent
    /// against double-start (a second call while already listening is ignored).
    /// Returns silently — never crashes — if permissions are missing, the
    /// recognizer is unavailable, or there is no usable audio input.
    func startListening() {
        guard !isListening else { return }

        // Clear any session still finalizing from a previous release so its
        // fallback timer / task can't bleed into this one.
        finalizeFallback?.cancel()
        finalizeFallback = nil
        teardownAudioAndTask()

        guard hasRequiredPermissions else {
            // Integrator is expected to call requestPermission() up front.
            print("VoiceInputController: microphone or speech-recognition permission not granted; ignoring start.")
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            print("VoiceInputController: speech recognizer unavailable; ignoring start.")
            return
        }

        // Fresh session state.
        latestTranscript = ""
        partialTranscript = ""
        hasDeliveredFinal = false
        isFinalizing = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero sample-rate means there is no usable input device; installing a
        // tap with that format would throw an ObjC exception, so bail cleanly.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("VoiceInputController: no usable audio input device; ignoring start.")
            self.request = nil
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Runs on the realtime audio thread. `append` is thread-safe and we
            // touch no actor-isolated state here.
            request.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("VoiceInputController: failed to start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
            self.request = nil
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Called on an arbitrary queue. Extract Sendable values here, then
            // hop to the main actor to mutate observable state.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errored = error != nil
            Task { @MainActor in
                self?.handleRecognition(text: text, isFinal: isFinal, errored: errored)
            }
        }

        isListening = true
    }

    /// Ends capture and fires `onFinalTranscript` with the best final text.
    /// Idempotent: a call when not listening is ignored.
    func stopListening() {
        guard isListening else { return }

        isListening = false
        isFinalizing = true

        // Stop feeding audio, then close the request so SFSpeech emits its final
        // result. Keep the recognition task alive to flush that result.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeTapIfNeeded()
        request?.endAudio()

        // Guarantee delivery even if `isFinal` never arrives.
        finalizeFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.deliverFinal(self.latestTranscript)
            }
        }
        finalizeFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + finalTranscriptFallbackDelay, execute: fallback)
    }

    /// Push-to-talk convenience: start if idle, stop if listening.
    func toggle() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    // MARK: Recognition handling

    private func handleRecognition(text: String?, isFinal: Bool, errored: Bool) {
        // Ignore callbacks from a session we've already torn down.
        guard task != nil else { return }

        if let text {
            latestTranscript = text
            partialTranscript = text
        }

        if isFinal {
            deliverFinal(latestTranscript)
            return
        }

        if errored {
            // An error can arrive as the natural end-of-stream after endAudio(),
            // or mid-session (e.g. the recognizer dropped). Either way, finish
            // gracefully with whatever we have rather than leaving a live tap.
            deliverFinal(latestTranscript)
        }
    }

    private func deliverFinal(_ text: String) {
        guard !hasDeliveredFinal else { return }
        hasDeliveredFinal = true

        finalizeFallback?.cancel()
        finalizeFallback = nil

        teardownAudioAndTask()

        isListening = false
        isFinalizing = false
        partialTranscript = ""

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }
        onFinalTranscript?(finalText)
    }

    // MARK: Teardown

    private func teardownAudioAndTask() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeTapIfNeeded()
        task?.cancel()
        task = nil
        request = nil
    }

    private func removeTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
    }
}
