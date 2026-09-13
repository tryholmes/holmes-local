//
//  VoiceInputController.swift
//  holmes
//
//  Push-to-talk (hold-to-talk) speech input using Apple's on-device Speech
//  framework. Unsupported on-device recognizers are refused. It streams live
//  partial results while the user holds the hotkey and delivers the best
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

/// State carried across permission waits and asynchronous recognition callbacks.
/// Every physical hold has its own ID; a released/cancelled/previous hold cannot
/// start, finish, or overwrite the next one.
struct VoiceHoldSession {
    enum Phase { case waitingForPermission, recording, awaitingRelease, finalizing }
    private(set) var holdID: UUID?
    private(set) var phase: Phase?

    mutating func begin(_ id: UUID) {
        holdID = id
        phase = .waitingForPermission
    }

    mutating func authorize(_ id: UUID, isHeld: Bool, permissionGranted: Bool) -> Bool {
        guard holdID == id, phase == .waitingForPermission else { return false }
        guard isHeld, permissionGranted else { cancel(id); return false }
        phase = .recording
        return true
    }

    /// Returns true only when there is captured speech to finalize.
    mutating func release(_ id: UUID) -> Bool {
        guard holdID == id else { return false }
        switch phase {
        case .recording, .awaitingRelease:
            phase = .finalizing
            return true
        case .waitingForPermission:
            cancel(id)
            return false
        default:
            return false
        }
    }

    func acceptsRecognition(_ id: UUID) -> Bool {
        holdID == id && (phase == .recording || phase == .finalizing)
    }

    /// The recognizer can finish early; keep its transcript until Fn is released.
    mutating func recognitionEnded(_ id: UUID) {
        guard holdID == id, phase == .recording else { return }
        phase = .awaitingRelease
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard holdID == id, phase == .finalizing else { return false }
        cancel(id)
        return true
    }

    mutating func cancel(_ id: UUID? = nil) {
        if let id, holdID != id { return }
        holdID = nil
        phase = nil
    }
}

/// The audio callback runs outside the main actor. Closing this gate and checking
/// the hardware key for EVERY buffer prevent queued audio entering recognition
/// after release, even while the main run loop is occupied.
final class VoiceAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private let isHeld: () -> Bool

    init(isHeld: @escaping () -> Bool) { self.isHeld = isHeld }

    func whileHeld(_ consume: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        guard isHeld() else { isOpen = false; return }
        consume()
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }
}

/// One microphone owner. Only a current physical Fn hold can request capture;
/// the UI observes its state and never creates another recorder.
@Observable
@MainActor
final class VoiceInputController {

    // MARK: Shared

    static let shared = VoiceInputController()

    // MARK: Observable state

    /// True only while the microphone engine is capturing a physical Fn hold.
    private(set) var isListening = false
    private(set) var partialTranscript = ""
    @ObservationIgnored var onFinalTranscript: ((String) -> Void)?

    // Hardware is created lazily after an authorized hold, never at app launch.
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasInstalledTap = false
    @ObservationIgnored private var audioGate: VoiceAudioGate?
    @ObservationIgnored private var session = VoiceHoldSession()
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var permissionRequest: Task<Bool, Never>?
    @ObservationIgnored private var latestTranscript = ""
    @ObservationIgnored private var finalizeFallback: Task<Void, Never>?
    private let finalTranscriptFallbackDelay: UInt64 = 1_500_000_000

    private init() {}

    // MARK: Permissions

    /// Requests microphone and speech-recognition authorization. Returns true
    /// only when BOTH are granted. Safe to call repeatedly; already-granted
    /// permissions resolve immediately without re-prompting.
    func requestPermission() async -> Bool {
        if let permissionRequest { return await permissionRequest.value }
        let request = Task { @MainActor in
            guard await self.requestMicrophoneAccess() else { return false }
            return await self.requestSpeechRecognitionAccess()
        }
        permissionRequest = request
        let granted = await request.value
        permissionRequest = nil
        return granted
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

    /// A permission dialog can outlive the key press. Authorize this exact hold
    /// again after the await, before creating an engine or accessing its input.
    func beginListening(holdID: UUID) {
        guard HotkeyManager.shared.isPushToTalkHeld(holdID) else { return }
        guard session.holdID != holdID else { return }
        cancelListening()
        session.begin(holdID)
        permissionTask = Task { @MainActor in
            let granted = await requestPermission()
            guard !Task.isCancelled else { return }
            guard session.authorize(holdID,
                                    isHeld: HotkeyManager.shared.isPushToTalkHeld(holdID),
                                    permissionGranted: granted) else { return }
            startCapture(holdID: holdID)
        }
    }

    private func startCapture(holdID: UUID) {
        guard session.holdID == holdID, hasRequiredPermissions,
              HotkeyManager.shared.isPushToTalkHeld(holdID) else {
            cancelListening(holdID: holdID)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            print("VoiceInputController: on-device speech recognition unavailable; capture refused.")
            cancelListening(holdID: holdID)
            return
        }
        self.recognizer = recognizer
        latestTranscript = ""
        partialTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true
        self.request = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              HotkeyManager.shared.isPushToTalkHeld(holdID) else {
            cancelListening(holdID: holdID)
            return
        }

        let gate = VoiceAudioGate { HotkeyManager.isPhysicalFnDown }
        audioGate = gate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            gate.whileHeld { request.append(buffer) }
        }
        hasInstalledTap = true
        engine.prepare()
        guard HotkeyManager.shared.isPushToTalkHeld(holdID) else {
            cancelListening(holdID: holdID)
            return
        }
        do {
            try engine.start()
        } catch {
            print("VoiceInputController: failed to start audio engine: \(error.localizedDescription)")
            cancelListening(holdID: holdID)
            return
        }
        guard HotkeyManager.shared.isPushToTalkHeld(holdID) else {
            cancelListening(holdID: holdID)
            return
        }
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errored = error != nil
            Task { @MainActor in
                self?.handleRecognition(holdID: holdID, text: text, isFinal: isFinal, errored: errored)
            }
        }
    }

    /// Release stops the hardware immediately. Recognition may flush already
    /// captured speech, but can neither receive new buffers nor reopen capture.
    func stopListening(holdID: UUID) {
        guard session.holdID == holdID else { return }
        let recognitionAlreadyEnded = session.phase == .awaitingRelease
        guard session.release(holdID) else {
            if session.holdID == nil { cancelListening() }
            return
        }
        stopAudio()
        request?.endAudio()
        if recognitionAlreadyEnded {
            deliverFinal(latestTranscript, holdID: holdID)
            return
        }
        finalizeFallback?.cancel()
        finalizeFallback = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: finalTranscriptFallbackDelay) }
            catch { return }
            deliverFinal(latestTranscript, holdID: holdID)
        }
    }

    /// Sleep, termination, or a superseding hold discards the old transcript.
    func cancelListening(holdID: UUID? = nil) {
        if let holdID, session.holdID != holdID { return }
        session.cancel(holdID)
        permissionTask?.cancel()
        permissionTask = nil
        finalizeFallback?.cancel()
        finalizeFallback = nil
        teardownAudioAndTask()
        latestTranscript = ""
        partialTranscript = ""
    }

    // MARK: Recognition handling

    private func handleRecognition(holdID: UUID, text: String?, isFinal: Bool, errored: Bool) {
        guard session.acceptsRecognition(holdID), task != nil else { return }
        if let text {
            latestTranscript = text
            partialTranscript = text
        }
        guard isFinal || errored else { return }
        stopAudio()
        if session.phase == .finalizing {
            deliverFinal(latestTranscript, holdID: holdID)
        } else {
            // No action is submitted before the physical hold is released.
            session.recognitionEnded(holdID)
            task?.cancel()
            task = nil
            request = nil
        }
    }

    private func deliverFinal(_ text: String, holdID: UUID) {
        guard session.finish(holdID) else { return }
        finalizeFallback?.cancel()
        finalizeFallback = nil
        teardownAudioAndTask()
        partialTranscript = ""
        latestTranscript = ""
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }
        onFinalTranscript?(finalText)
    }

    // MARK: Teardown

    private func stopAudio() {
        audioGate?.close()
        audioGate = nil
        if let audioEngine {
            if audioEngine.isRunning { audioEngine.stop() }
            if hasInstalledTap { audioEngine.inputNode.removeTap(onBus: 0) }
        }
        hasInstalledTap = false
        audioEngine = nil
        isListening = false
    }

    private func teardownAudioAndTask() {
        stopAudio()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }
}
