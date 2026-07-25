//
//  SpeechSynthesizer.swift
//  holmes
//
//  Voice OUTPUT for the Clicky-style experience: Holmes answers OUT LOUD.
//  Two backends, chosen automatically at speak-time:
//
//    • ElevenLabs (preferred) — natural neural TTS. Requires a key
//      (Keychain / ~/.holmes/elevenlabs_key). Text is chunked into
//      sentences so speech STARTS on the first sentence while later
//      sentences are still being fetched — the reply feels immediate.
//    • Apple AVSpeechSynthesizer (fallback) — always available, no key,
//      picks a premium/enhanced macOS voice when one is installed.
//
//  Failures degrade quietly: a broken network / bad key / decode error
//  never crashes and never mixes two voices mid-utterance. If ElevenLabs
//  is configured but produces NO audio at all, the whole utterance is
//  re-spoken through Apple so the user still hears an answer.
//
//  ── Attribution ────────────────────────────────────────────────────
//  The two-backend TTS approach, ElevenLabs request shape, sentence
//  chunk-for-prompt-start strategy, and key/voice configuration
//  convention are ported/adapted from OpenClicky
//  (ElevenLabsTTSClient.swift / TTSStreamingPlaybackEngine.swift).
//  OpenClicky — MIT License — © 2025 Jason Kneen. See THIRD_PARTY_NOTICES.md.
//

import AVFoundation
import Foundation
import Observation
import os

/// Console-visible log for TTS. Filter Console.app / `log stream` on
/// subsystem `com.grain.holmes`, category `tts` to see why a request failed.
private let ttsLog = Logger(subsystem: "com.grain.holmes", category: "tts")

// MARK: - ElevenLabsConfig
// Configuration for the ElevenLabs TTS backend. Mirrors AnthropicConfig
// EXACTLY: key lives in the Keychain (never in source); a plain-text file
// fallback lets the user enable voice without a settings UI and is migrated
// into the Keychain on first read. Without a key, SpeechSynthesizer falls
// back to Apple's on-device voice.

enum ElevenLabsConfig {
    /// Keychain service + accounts for the ElevenLabs credentials.
    static let keychainService = "com.grain.holmes.elevenlabs"
    static let apiKeyAccount   = "elevenlabs_api_key"
    static let voiceIDAccount  = "elevenlabs_voice_id"

    /// Default voice — "Rachel", a natural, widely-available ElevenLabs
    /// voice that exists on every account. Overridable via `setVoiceID`.
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    /// Turbo model: low-latency, good quality, cheap — the right tradeoff
    /// for interactive spoken answers.
    static let modelID = "eleven_turbo_v2_5"

    static var apiKey: String? {
        if let key = KeychainManager.load(service: keychainService, account: apiKeyAccount),
           !key.isEmpty {
            return key
        }
        // Fallback: a plain-text key file, mirroring the Anthropic convention.
        // Lets the user enable voice without a settings UI. Migrated into the
        // Keychain on read.
        if let fileKey = keyFromFile() {
            setAPIKey(fileKey)
            return fileKey
        }
        return nil
    }

    private static func keyFromFile() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Holmes/elevenlabs_key"),
            home.appendingPathComponent(".holmes/elevenlabs_key")
        ]
        for url in candidates {
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { return key }
            }
        }
        return nil
    }

    static var isConfigured: Bool { apiKey != nil }

    /// The active voice id — a user override if one was set, else the default.
    static var voiceID: String {
        if let stored = KeychainManager.load(service: keychainService, account: voiceIDAccount) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultVoiceID
    }

    /// Fired after a key/voice write so SpeechSynthesizer can refresh its
    /// cached credentials (it no longer does 2 Keychain IPC reads per speak).
    static var onCredentialsChanged: (() -> Void)?

    static func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainManager.delete(service: keychainService, account: apiKeyAccount)
        } else {
            KeychainManager.save(trimmed, service: keychainService, account: apiKeyAccount)
        }
        onCredentialsChanged?()
    }

    static func setVoiceID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Clearing the override reverts to `defaultVoiceID`.
            KeychainManager.delete(service: keychainService, account: voiceIDAccount)
        } else {
            KeychainManager.save(trimmed, service: keychainService, account: voiceIDAccount)
        }
        onCredentialsChanged?()
    }
}

/// How a line of speech competes for the voice.
///   .utterance — an ANSWER the user asked for (teach explanations, ask
///                replies). Never auto-cancelled; queues in order.
///   .status    — run narration ("On it", "Opening Finder…"). A new status
///                REPLACES any queued-but-unstarted statuses (only the latest
///                matters) and NEVER cuts audio that is already playing.
enum SpeechPriority {
    case utterance
    case status
}

// MARK: - SpeechSynthesizer

@Observable
@MainActor
final class SpeechSynthesizer {
    static let shared = SpeechSynthesizer()

    enum Backend {
        case elevenLabs
        case apple
        case none
    }

    /// True while an utterance is being fetched or played. Observable so
    /// UI (e.g. a speaking indicator / draw-overlay) can react.
    private(set) var isSpeaking: Bool = false

    /// Which backend produced (or is producing) the current utterance.
    private(set) var activeBackend: Backend = .none

    /// Human-readable reason the last ElevenLabs attempt failed (bad key,
    /// HTTP 401/422, network, empty body …). Cleared on any successful
    /// ElevenLabs fetch and at the start of every `speak`. Nil means either
    /// "ElevenLabs isn't configured" or "the last attempt succeeded" — the
    /// Settings view pairs it with `activeBackend` so a silent Apple
    /// fallback is no longer invisible.
    private(set) var lastError: String?

    // MARK: Private state

    /// Monotonic token. Each utterance captures the value at start; `cancelAll`
    /// (or the next utterance) bumps it, which supersedes any in-flight loop
    /// without needing to thread a cancellation token through every await.
    private var activeGeneration: Int = 0

    private var currentPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private let playbackDelegate = PlaybackDelegate()

    private let appleSynth = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private let utteranceDelegate = UtteranceDelegate()

    /// In-flight ElevenLabs fetches for the CURRENT utterance — cancelled on
    /// cancelAll() so a superseded speak can't park its caller for up to 30s
    /// on an orphan download (and can't waste API spend).
    private var inflightFetches: [Task<Data?, Never>] = []

    /// Credentials cached at init and refreshed on change — the old code did
    /// two synchronous Keychain IPC reads on the main actor per utterance.
    private var cachedAPIKey: String?
    private var cachedVoiceID: String = ElevenLabsConfig.defaultVoiceID

    // MARK: The speech queue
    // FIFO with two priorities (see SpeechPriority). The queue is what fixes
    // "the voice messes itself up": the old speak() began by killing whatever
    // was playing — every two lines within a few seconds truncated each other.

    private struct PendingSpeech {
        let text: String
        let priority: SpeechPriority
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    private var queue: [PendingSpeech] = []
    private var isPumping = false

    /// Dedicated URLSession so TTS requests don't share timeouts with the
    /// Claude client.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    private init() {
        appleSynth.delegate = utteranceDelegate
        reloadCredentials()
        ElevenLabsConfig.onCredentialsChanged = { [weak self] in
            Task { @MainActor in self?.reloadCredentials() }
        }
    }

    private func reloadCredentials() {
        cachedAPIKey = ElevenLabsConfig.apiKey
        cachedVoiceID = ElevenLabsConfig.voiceID
    }

    // MARK: - Public API

    /// Fire-and-forget speech. `.status` lines coalesce (a newer status
    /// replaces queued-unstarted ones) and never interrupt playing audio;
    /// `.utterance` lines queue in order and are never auto-cancelled.
    func enqueue(_ text: String, priority: SpeechPriority = .status) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if priority == .status {
            for item in queue where item.priority == .status {
                item.continuations.forEach { $0.resume() }
            }
            queue.removeAll { $0.priority == .status }
        }
        queue.append(PendingSpeech(text: trimmed, priority: priority))
        pump()
    }

    /// Speaks `text` and returns when ITS playback finishes (or the queue is
    /// cancelled). Queues at `.utterance` priority — it no longer cuts off
    /// whatever is currently playing.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.append(PendingSpeech(text: trimmed, priority: .utterance, continuations: [continuation]))
            pump()
        }
    }

    /// USER-INTENT cancel (push-to-talk key-down, kill switch): drops the
    /// whole queue and stops audio immediately. Nothing else may cut speech.
    func cancelAll() {
        activeGeneration &+= 1
        for item in queue { item.continuations.forEach { $0.resume() } }
        queue.removeAll()
        stopInternal()
        isSpeaking = false
        activeBackend = .none
    }

    /// Back-compat alias — existing callers say stop().
    func stop() { cancelAll() }

    /// Drains the queue one item at a time. Single pump task; re-entrancy
    /// guarded by `isPumping`.
    private func pump() {
        guard !isPumping else { return }
        isPumping = true
        isSpeaking = true
        Task { @MainActor in
            while !queue.isEmpty {
                let item = queue.removeFirst()
                await speakNow(item.text)
                item.continuations.forEach { $0.resume() }
            }
            isPumping = false
            isSpeaking = false
            activeBackend = .none
        }
    }

    /// Speaks one queue item to completion. Called only from the pump, so it
    /// never races another utterance.
    private func speakNow(_ text: String) async {
        activeGeneration &+= 1
        let generation = activeGeneration
        activeBackend = .none
        lastError = nil

        if let apiKey = cachedAPIKey {
            let spokeSomething = await speakWithElevenLabs(
                text,
                apiKey: apiKey,
                voiceID: cachedVoiceID,
                generation: generation
            )
            // If ElevenLabs is configured but produced no audio at all
            // (bad key, network down, all requests failed) fall back to
            // Apple for the whole utterance — never mid-utterance, to
            // avoid two different voices in one answer.
            if !spokeSomething, generation == activeGeneration {
                await speakWithApple(text, generation: generation)
            }
        } else {
            await speakWithApple(text, generation: generation)
        }
    }

    // MARK: - ElevenLabs backend

    /// Fetches per-sentence MP3 and plays chunks in order, prefetching the
    /// next chunk while the current one plays so speech starts promptly.
    /// Returns true if at least one chunk was actually played.
    private func speakWithElevenLabs(
        _ text: String,
        apiKey: String,
        voiceID: String,
        generation: Int
    ) async -> Bool {
        let chunks = Self.chunkText(text)
        guard !chunks.isEmpty else { return false }

        activeBackend = .elevenLabs
        var playedAny = false
        inflightFetches.removeAll()

        // Kick off the first fetch immediately.
        var pendingFetch: Task<Data?, Never>? = fetchTask(
            chunks[0], apiKey: apiKey, voiceID: voiceID, generation: generation
        )

        for index in chunks.indices {
            guard generation == activeGeneration else { return playedAny }

            let currentFetch = pendingFetch

            // Prefetch the next chunk while the current one plays.
            if index + 1 < chunks.count {
                pendingFetch = fetchTask(
                    chunks[index + 1], apiKey: apiKey, voiceID: voiceID, generation: generation
                )
            } else {
                pendingFetch = nil
            }

            let data: Data?
            if let currentFetch {
                data = await currentFetch.value
            } else {
                data = nil
            }
            guard generation == activeGeneration else { return playedAny }

            guard let data else {
                if playedAny {
                    // A later chunk failed — skip it and keep the answer
                    // moving rather than switching voices mid-utterance.
                    continue
                } else {
                    // Nothing has played yet: bail so the caller can fall
                    // back to Apple for the entire utterance.
                    return false
                }
            }

            playedAny = true
            await playMP3(data, generation: generation)
        }

        return playedAny
    }

    private func fetchTask(
        _ text: String,
        apiKey: String,
        voiceID: String,
        generation: Int
    ) -> Task<Data?, Never> {
        let task = Task { await self.fetchElevenLabsMP3(text, apiKey: apiKey, voiceID: voiceID, generation: generation) }
        inflightFetches.append(task)
        return task
    }

    /// POSTs one chunk to ElevenLabs and returns the MP3 bytes, or nil on
    /// any failure (the caller degrades quietly). `generation` gates the
    /// lastError writes — a superseded fetch's failure must not clobber the
    /// state of the utterance that replaced it.
    private func fetchElevenLabsMP3(
        _ text: String,
        apiKey: String,
        voiceID: String,
        generation: Int
    ) async -> Data? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            if generation == activeGeneration {
                lastError = "Invalid ElevenLabs voice id \u{201C}\(voiceID)\u{201D}."
            }
            ttsLog.error("Invalid voice id, cannot build URL: \(voiceID, privacy: .public)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": ElevenLabsConfig.modelID,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                if generation == activeGeneration { lastError = "ElevenLabs returned no HTTP response." }
                ttsLog.error("ElevenLabs returned a non-HTTP response.")
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                // On an error the body is JSON (e.g. {"detail":{"status":
                // "invalid_api_key", ...}} for 401, or a 422 validation
                // error) — log a snippet so the reason is visible in Console
                // and surface it to the Settings view instead of silently
                // dropping to the Apple voice.
                let snippet = String(data: data.prefix(400), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary body>"
                if generation == activeGeneration {
                    lastError = "ElevenLabs HTTP \(http.statusCode): \(snippet)"
                }
                ttsLog.error("ElevenLabs TTS HTTP \(http.statusCode, privacy: .public): \(snippet, privacy: .public)")
                return nil
            }
            guard !data.isEmpty else {
                if generation == activeGeneration {
                    lastError = "ElevenLabs returned an empty audio body (HTTP \(http.statusCode))."
                }
                ttsLog.error("ElevenLabs TTS empty body, HTTP \(http.statusCode, privacy: .public).")
                return nil
            }
            // Success — retire any earlier failure so the UI reflects reality.
            if generation == activeGeneration { lastError = nil }
            return data
        } catch is CancellationError {
            // cancelAll() cancelled the fetch — silence, not an error.
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            if generation == activeGeneration {
                lastError = "ElevenLabs request failed: \(error.localizedDescription)"
            }
            ttsLog.error("ElevenLabs TTS request error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Plays a single MP3 buffer and returns when it finishes (or is
    /// stopped). Never throws; a decode failure resolves immediately.
    private func playMP3(_ data: Data, generation: Int) async {
        guard generation == activeGeneration else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard generation == activeGeneration else {
                continuation.resume()
                return
            }

            let player: AVAudioPlayer
            do {
                player = try AVAudioPlayer(data: data)
            } catch {
                // Corrupt / undecodable audio — skip quietly.
                continuation.resume()
                return
            }

            player.delegate = playbackDelegate
            player.prepareToPlay()
            currentPlayer = player
            playbackContinuation = continuation

            // Tag the callback with THIS chunk's generation. A stale delegate
            // event (the natural finish of an old chunk arriving after a new
            // utterance stored its continuation) used to resume the NEW
            // utterance's continuation early — chunks skipped, isSpeaking
            // false while audio still played. Now stale callbacks are ignored.
            playbackDelegate.onFinish = { [weak self] in
                Task { @MainActor in self?.finishPlaybackChunk(generation: generation) }
            }

            if !player.play() {
                // Engine refused to start — don't hang the loop.
                finishPlaybackChunk(generation: generation)
            }
        }
    }

    /// Resolves the current chunk's continuation exactly once and clears the
    /// player. `generation` nil = forced teardown (cancelAll); a non-nil
    /// generation that doesn't match the active one is a stale delegate
    /// callback and is dropped.
    private func finishPlaybackChunk(generation: Int? = nil) {
        if let generation, generation != activeGeneration { return }
        currentPlayer = nil
        if let continuation = playbackContinuation {
            playbackContinuation = nil
            continuation.resume()
        }
    }

    // MARK: - Apple backend

    private func speakWithApple(_ text: String, generation: Int) async {
        guard generation == activeGeneration else { return }
        activeBackend = .apple

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard generation == activeGeneration else {
                continuation.resume()
                return
            }

            let utterance = AVSpeechUtterance(string: text)
            if let voice = Self.preferredAppleVoice() {
                utterance.voice = voice
            }
            // Slightly measured, natural pacing.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.postUtteranceDelay = 0.0

            speechContinuation = continuation
            utteranceDelegate.onFinish = { [weak self] in
                Task { @MainActor in self?.finishAppleUtterance(generation: generation) }
            }
            appleSynth.speak(utterance)
        }
    }

    /// Same stale-callback discipline as finishPlaybackChunk: nil = forced
    /// teardown, mismatched generation = stale didFinish/didCancel, dropped.
    private func finishAppleUtterance(generation: Int? = nil) {
        if let generation, generation != activeGeneration { return }
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
    }

    /// Picks the best available English macOS voice: premium, then
    /// enhanced, then the system default. Prefers en-US.
    private static func preferredAppleVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        func pick(_ quality: AVSpeechSynthesisVoiceQuality) -> AVSpeechSynthesisVoice? {
            let matches = englishVoices.filter { $0.quality == quality }
            return matches.first(where: { $0.language == "en-US" }) ?? matches.first
        }

        if let premium = pick(.premium) { return premium }
        if let enhanced = pick(.enhanced) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US") ?? englishVoices.first
    }

    // MARK: - Teardown

    private func stopInternal() {
        // Cancel in-flight downloads — a superseded utterance must not park
        // its caller on a 30s orphan fetch, or bill for audio never played.
        for task in inflightFetches { task.cancel() }
        inflightFetches.removeAll()

        currentPlayer?.stop()
        finishPlaybackChunk()

        if appleSynth.isSpeaking {
            // .immediate does NOT invoke didFinish; resolve the
            // continuation ourselves so the awaiting loop unblocks.
            appleSynth.stopSpeaking(at: .immediate)
        }
        finishAppleUtterance()
    }

    // MARK: - Chunking

    /// Splits text into speech-sized chunks. Sentences are grouped up to a
    /// soft character cap so the FIRST chunk stays short (speech starts
    /// promptly) without over-fragmenting long answers. A single very long
    /// sentence is hard-split on word boundaries so no request is enormous.
    static func chunkText(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Break into sentence-ish units on terminal punctuation + newlines.
        var sentences: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { sentences = [trimmed] }

        // 2. Group sentences up to the soft cap; hard-split runaway sentences.
        //    The FIRST chunk uses a much smaller cap (one short sentence-ish
        //    piece): time-to-first-audio is the whole perceived latency, and
        //    ElevenLabs must synthesize + download an entire chunk before
        //    playback starts — a 240-char first chunk was the "voice is laggy"
        //    start delay.
        let firstCap = 100
        let softCap = 240
        let hardCap = softCap * 2
        var chunks: [String] = []
        var buffer = ""

        func currentCap() -> Int { chunks.isEmpty ? firstCap : softCap }

        func flushBuffer() {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { chunks.append(value) }
            buffer = ""
        }

        for sentence in sentences {
            if sentence.count > hardCap {
                // A single monster sentence: flush what we have, then
                // split it on word boundaries.
                flushBuffer()
                for piece in Self.splitOnWordBoundaries(sentence, cap: softCap) {
                    chunks.append(piece)
                }
                continue
            }

            if buffer.isEmpty {
                buffer = sentence
                // A long opening sentence still flushes alone so the first
                // request stays as small as its sentence allows.
                if chunks.isEmpty, buffer.count >= firstCap { flushBuffer() }
            } else if buffer.count + 1 + sentence.count <= currentCap() {
                buffer += " " + sentence
            } else {
                flushBuffer()
                buffer = sentence
            }
        }
        flushBuffer()

        return chunks.isEmpty ? [trimmed] : chunks
    }

    private static func splitOnWordBoundaries(_ text: String, cap: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if buffer.isEmpty {
                buffer = String(word)
            } else if buffer.count + 1 + word.count <= cap {
                buffer += " " + word
            } else {
                pieces.append(buffer)
                buffer = String(word)
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }
}

// MARK: - Delegates
// Small NSObject delegate shims. AVFoundation delivers these callbacks on
// its own thread; each hops back to the MainActor via the stored closure.

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

private final class UtteranceDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (@Sendable () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
