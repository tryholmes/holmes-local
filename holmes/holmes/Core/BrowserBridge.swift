import Foundation
import AppKit
import Observation

// MARK: - BrowserBridge
// The exact-context pipe: the Holmes browser extension POSTs the structured
// contents of the page the user is actually looking at, and this turns it into a
// LiveContext with confidence .exact — the only tier Holmes is allowed to quote.
//
// Security posture (this endpoint now carries the FULL DOM of every page the user
// visits — email bodies, DMs, 2FA codes, banking pages):
//   • Bound to 127.0.0.1 ONLY. The previous build bound INADDR_ANY, which published
//     every page the user browsed to anything on the local network. That is fixed
//     here and must never regress.
//   • Every request except OPTIONS (CORS preflight) and GET /health must carry
//     X-Holmes-Token matching either the token in
//     ~/Library/Application Support/Holmes/bridge_token (0600, generated once) or
//     the PAIRED token — see BridgeToken. Loopback alone is not a permission
//     boundary: any local process, including a web page's helper, can reach a
//     loopback port. The token is the real gate.
//   • Pairing is USER-ARMED, never trust-on-first-use. The extension mints its own
//     secret with crypto.randomUUID() into chrome.storage.local, which this app
//     cannot read (and shouldn't be able to), so the two ends still have to meet
//     somehow — but adopting the first secret that appears on a loopback socket
//     hands the bridge to whoever asks first, and "first" is not the extension.
//     Any local process can post, and a hostile web page could preflight and POST
//     a token of its own choosing. That would (a) permanently lock out the real
//     extension, whose token would then never match, and (b) let the page inject
//     confidence-.exact context into an agent that holds tool access. So adoption
//     happens ONLY inside the short, one-shot window the user opens in
//     Settings ▸ Privacy ▸ Pair browser extension, and never for a request whose
//     Origin is a web page. Outside that window the only accepted secrets are the
//     token Holmes issued (shown in Settings) and the one already paired.
//   • CORS is granted ONLY to chrome-extension:// / moz-extension:// origins. Page
//     JavaScript gets no Access-Control-Allow-Origin at all, so its preflight fails
//     and the POST is never sent; the extension posts through its background
//     worker, which holds host_permissions and isn't subject to CORS. The token is
//     still the real boundary — this just stops the port from advertising itself
//     to every page in the browser.
//   • Every accepted socket carries a 5s recv/send timeout and a 10s overall
//     deadline, and handlers run on a capped queue: a client that connects and
//     then stalls must not be able to park worker threads until Holmes quits.
//   • Bodies are read with a real Content-Length loop (DOM payloads are far larger
//     than the old fixed 8 KB recv, which silently truncated them into malformed
//     JSON) and capped at 512 KB.

/// Wire constants, kept OUTSIDE the @MainActor class so the socket layer (which
/// runs on background queues) can read them without an actor hop.
enum BridgeProtocol {
    /// Port the extension posts to. Loopback only.
    static let port: UInt16 = 5766
    /// Shared-secret header. The extension must send it on every request.
    static let tokenHeader = "X-Holmes-Token"
    /// Lowercased form used for header lookup (HTTP headers are case-insensitive).
    static let tokenHeaderKey = "x-holmes-token"
    /// Hard ceiling on a single payload. A full DOM extract is ~50-200 KB.
    static let maxBodyBytes = 512 * 1024
    /// Per-recv/send socket timeout. Long enough for a 512 KB body over loopback,
    /// short enough that a silent client releases its slot promptly.
    static let socketTimeoutSeconds = 5
    /// Overall deadline for reading one request, so a client that trickles a byte
    /// every four seconds can't hold a handler open indefinitely.
    static let requestDeadline: TimeInterval = 10
    /// Concurrent request handlers. The extension uses one connection at a time;
    /// this is headroom, not a throughput knob.
    static let maxConcurrentClients = 8

    // ── Browser-automation command channel ──────────────────────────
    // The Mac app is the PRODUCER: it leaves commands at GET /commands, which the
    // extension's service worker polls, executes (under its own DRAFT-NEVER-SEND
    // guard), and reports back to POST /command-result. Both paths sit behind the
    // SAME token gate as /context — a page that can't read /context can't drive
    // the browser either.
    /// Path the extension polls (GET) to drain queued commands. Token-gated.
    static let commandsPath = "/commands"
    /// Path the extension POSTs each command's structured outcome to. Token-gated.
    static let commandResultPath = "/command-result"
    /// Hard cap on commands sitting unfetched. enqueue is rejected past this so a
    /// disconnected extension can't let the queue grow without bound.
    static let maxPendingCommands = 32
    /// A command the extension never fetched is dropped after this. The enqueue
    /// await keeps its own (shorter) timeout as the real backstop; this just stops
    /// an ancient command from ever being handed to a briefly-revived worker.
    static let commandQueueTTL: TimeInterval = 30
    /// How long enqueueBrowserCommand awaits a result before giving up and
    /// returning {"error":"timeout"}, so a stalled extension can't hang a producer.
    static let commandResultTimeout: TimeInterval = 20
}

/// Cancellation handlers run outside the main actor. Mark synchronously so a
/// polling drain can refuse a cancelled command before its actor cleanup runs.
private final class BrowserCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@Observable
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()

    struct AppIdentity {
        let name: String
        let bundleIdentifier: String?
    }
    struct ContextEnvironment {
        let frontmost: () -> AppIdentity?
        let ownBundleIdentifier: String?
        let nameForBundle: (String) -> String?
        var didObserveExtensionVersion: (String) -> Void = { _ in }

        static var system: ContextEnvironment {
            ContextEnvironment(frontmost: {
                NSWorkspace.shared.frontmostApplication.map {
                    AppIdentity(name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier)
                }
            }, ownBundleIdentifier: Bundle.main.bundleIdentifier, nameForBundle: { bundle in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
            }, didObserveExtensionVersion: { ExtensionInstaller.noteBrowserVersion($0) })
        }
    }
    @ObservationIgnored private var contextEnvironment = ContextEnvironment.system

    static let port = BridgeProtocol.port
    static let tokenHeader = BridgeProtocol.tokenHeader
    static let maxBodyBytes = BridgeProtocol.maxBodyBytes

    /// Delivered on the main actor for every payload that parses into a real
    /// LiveContext. Nil-payloads (heartbeats, blank pages) never fire it.
    var onLiveContext: ((LiveContext) -> Void)?
    @ObservationIgnored private var lastPayloadCaptureAt: [String: Date] = [:]
    @ObservationIgnored private var browserBundlesByInstance: [String: String] = [:]
    @ObservationIgnored private var lastForegroundBrowserInstance: String?
    private(set) var emailComposeUnavailableReason: String?
    private(set) var extensionVersion: String?
    private static let composeReloadMessage = "Reload Holmes on chrome://extensions, then refresh Gmail to enable email drafting."

    // ── Observable state the UI reads ───────────────────────────────
    /// True while the extension is actively posting. When this is FALSE the UI
    /// must tell the user so — "the extension isn't running in Comet" is the
    /// honest alternative to Holmes inventing a description of the page.
    private(set) var isExtensionConnected = false
    /// Last time an AUTHORIZED request arrived (context post or heartbeat).
    private(set) var lastHeartbeat: Date?
    /// Last time a real POST /context arrived, as opposed to a bare /heartbeat. A page
    /// that is actively posting page context is unmistakably connected even if a
    /// heartbeat beat was dropped, so refreshConnectionState() treats this as an
    /// independent liveness signal. (ingest() also refreshes lastHeartbeat, so in
    /// practice this tracks the same recency; it is kept separate so the "a live
    /// context post keeps us connected" intent survives any future refactor that
    /// decouples the two.)
    private var lastContextPost: Date?
    /// The most recent exact context, kept so the UI can render immediately.
    private(set) var lastLiveContext: LiveContext?
    private(set) var isRunning = false
    /// Human-readable reason the bridge isn't listening (port in use, etc.).
    private(set) var lastError: String?
    /// Requests rejected for a missing/wrong token — surfaced in Settings so a
    /// misconfigured extension looks like a misconfiguration, not a dead app.
    private(set) var unauthorizedRequests = 0

    /// The shared secret Holmes issued. Shown in Settings so the user can paste
    /// it into the extension; never logged in full.
    let token: String

    /// The token the extension presented while the user had pairing armed.
    /// Surfaced in Settings so "paired with an extension" is visible state, not
    /// something the user has to infer from traffic.
    private(set) var pairedToken: String?

    /// When the user-armed pairing window closes. Nil once it has expired or been
    /// consumed. Observable so Settings can count it down.
    private(set) var pairingWindowEnds: Date?

    /// True while Holmes will adopt an unrecognized token. Only a user action in
    /// Settings can make this true, and only for `pairingWindowSeconds`.
    var isPairing: Bool {
        guard let pairingWindowEnds else { return false }
        return pairingWindowEnds > Date()
    }

    /// How long a Settings-initiated pairing window stays open. The extension
    /// posts every ~3s, so two minutes is many attempts' worth of slack while
    /// still being far too narrow to be a standing invitation.
    static let pairingWindowSeconds: TimeInterval = 120

    /// Where the token lives on disk (Settings shows this path).
    static var tokenFileURL: URL { BridgeToken.fileURL }

    /// How long we tolerate silence before treating the extension as gone.
    ///
    /// This used to be 12s, tuned to the content script's ~3s post cadence. But the
    /// content script's timer is THROTTLED whenever no browser tab is focused (the
    /// user is in Messages, WhatsApp, Xcode, …), so a single focus change could stall
    /// posts long enough to trip a 12s timeout — the badge would flap to
    /// "disconnected" and back purely on window focus. The extension now beats from
    /// its MV3 background worker on a chrome.alarms cadence (focus-independent).
    ///
    /// The regression that made the badge flap AGAIN: 45s was tuned to the alarm's
    /// documented 30s floor. But once the MV3 worker is evicted (which happens within
    /// ~30s whenever the user is not actively in a browser tab), the alarm is the ONLY
    /// thing beating — and its period is NOT reliably 30s:
    ///   • Chromium clamps `periodInMinutes: 0.5` to a full MINUTE on any build older
    ///     than Chrome 120 — which includes Comet, our primary target browser.
    ///   • Even on 120+, Chrome batches alarms and adds jitter, and the woken worker
    ///     pays a cold-start cost before its fetch leaves — so a "30s" alarm routinely
    ///     lands at 40-70s.
    /// So a single evicted-worker beat cycle would exceed a 45s timeout, flip
    /// isExtensionConnected to false, and — because HolmesBrain gates browser
    /// automation on that flag — start REFUSING browser commands with "extension
    /// disconnected", until the next alarm reconnected it. That flap is the bug.
    ///
    /// 90s is comfortably above a 60s-clamped alarm plus jitter and cold-start, so a
    /// live-but-evicted worker can never trip it, while an immediate beat on every
    /// tab/focus change (wired in background.js) still reconnects the UI the instant
    /// the user returns to the browser. A genuine disconnect surfaces in ~90-100s
    /// (with the two-tick hysteresis) — the correct trade for a status flag that other
    /// subsystems refuse work on: never wrong-negative on a live extension.
    private static let connectionTimeout: TimeInterval = 90

    private var server: BridgeServer?
    private var watchdog: Timer?
    /// Consecutive watchdog ticks that have observed a stale (no recent beat)
    /// connection. Hysteresis: once connected, we require the stale condition to hold
    /// across TWO consecutive ticks before flipping to disconnected, so a single
    /// dropped beat or a brief loopback hiccup between the worker and this socket can
    /// never flap the badge. The false→true direction stays immediate — a fresh beat
    /// is unambiguous proof of life and should reconnect the UI at once.
    private var consecutiveStaleTicks = 0
    /// Last browser we saw a post from — used to name the app in the LiveContext
    /// when the payload doesn't carry one and Holmes itself is frontmost.
    private var lastBrowserApp = "your browser"

    // ── Browser-automation command queue (producer side) ────────────
    // All @MainActor state, per the actor's invariant. The socket layer reaches
    // it through the two closures wired in start(): a synchronous main-actor hop
    // for the GET /commands drain, and a fire-and-forget hop for the result POST.
    private struct PendingBrowserCommand {
        let id: Int
        let action: String            // wire (camelCase) action name automation.js expects
        let params: [String: Any]
        let enqueuedAt: Date
        let cancellation: BrowserCommandCancellation
    }
    /// Commands waiting for the extension to fetch them via GET /commands.
    private var pendingCommands: [PendingBrowserCommand] = []
    /// Includes delivered commands while their producer still awaits a result.
    private var commandCancellations: [Int: BrowserCommandCancellation] = [:]
    /// The awaiting continuations, keyed by command id. Exactly one of {result
    /// POST, cancellation, enqueue timeout, TTL expiry} resumes each — all via removeValue, so
    /// a continuation can never be resumed twice.
    private var commandContinuations: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    /// Monotonic id source. A plain incrementing Int (not a UUID/Date) so echoed
    /// results can never collide, and so ids stay small and legible on the wire.
    private var nextCommandID = 1

    private init() {
        token = BridgeToken.loadOrCreate()
        pairedToken = BridgeToken.loadPaired()
    }

    #if DEBUG
    /// Isolated integration harness: real queue/parser, fake OS identity and no
    /// token files, listening sockets, browser access or app activation.
    init(testToken: String, environment: ContextEnvironment) {
        token = testToken
        contextEnvironment = environment
    }
    func testIngest(_ data: Data) -> LiveContext? { ingest(data) }
    func testDrainCommands(instance: String?) -> Data { drainCommandsJSON(forInstance: instance) }
    func testCommandResult(_ data: Data) { recordCommandResult(data) }
    var testPendingCommandIDs: [Int] { pendingCommands.map(\.id) }
    var testAwaitingCommandCount: Int { commandContinuations.count }
    var testTrackedCommandCount: Int { commandCancellations.count }
    #endif

    // MARK: - Lifecycle

    /// Binds + listens. Safe to call repeatedly; a second call is a no-op.
    func start() {
        guard !isRunning else { return }

        let server = BridgeServer(
            port: Self.port,
            token: token,
            pairedToken: pairedToken,
            maxBodyBytes: Self.maxBodyBytes,
            onPayload: { data in
                Task { @MainActor in BrowserBridge.shared.ingest(data) }
            },
            onHeartbeat: {
                Task { @MainActor in BrowserBridge.shared.noteHeartbeat() }
            },
            onUnauthorized: { path in
                Task { @MainActor in BrowserBridge.shared.noteUnauthorized(path) }
            },
            onPaired: { secret in
                Task { @MainActor in BrowserBridge.shared.notePaired(secret) }
            },
            onCommandsPoll: { instance in
                // Called on a background client queue. The queue is @MainActor
                // state, and GET /commands must return its bytes synchronously,
                // so hop to main and block. This can't deadlock: no main-actor
                // code ever waits on the client queue, so there is no reentrancy.
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { BrowserBridge.shared.drainCommandsJSON(forInstance: instance) }
                }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { BrowserBridge.shared.drainCommandsJSON(forInstance: instance) }
                }
            },
            onCommandResult: { data in
                Task { @MainActor in BrowserBridge.shared.recordCommandResult(data) }
            }
        )

        switch server.startListening() {
        case .success:
            self.server = server
            isRunning = true
            lastError = nil
            print("[Bridge] Listening on http://127.0.0.1:\(Self.port) (loopback only, token required)")
            print("[Bridge] Token file: \(Self.tokenFileURL.path)")
            startWatchdog()
        case .failure(let message):
            lastError = message
            print("[Bridge] NOT listening — \(message)")
        }
    }

    func stop() {
        server?.stopListening()
        server = nil
        watchdog?.invalidate()
        watchdog = nil
        isRunning = false
        isExtensionConnected = false
    }

    /// Re-evaluates `isExtensionConnected` on a timer as well as on every post, so
    /// the flag can never get stuck reading "connected" after the posts stop —
    /// that stale true is exactly what would let the UI imply Holmes can see a page
    /// it can no longer read.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in BrowserBridge.shared.refreshConnectionState() }
        }
    }

    private func refreshConnectionState() {
        let now = Date()
        // Liveness comes from EITHER signal: a recent /heartbeat, OR a recent real
        // /context POST. A page actively posting context is obviously connected even
        // if a bare heartbeat was missed, so we don't demand both. (ingest() also
        // refreshes lastHeartbeat, so this OR is belt-and-suspenders today, but it
        // keeps connectivity correct if that coupling ever changes.)
        let freshHeartbeat = lastHeartbeat.map { now.timeIntervalSince($0) < Self.connectionTimeout } ?? false
        let freshContext = lastContextPost.map { now.timeIntervalSince($0) < Self.connectionTimeout } ?? false
        let live = freshHeartbeat || freshContext

        if live {
            consecutiveStaleTicks = 0
            if !isExtensionConnected {
                isExtensionConnected = true
                print("[Bridge] Extension connected")
            }
        } else {
            // Hysteresis: require the stale condition to survive TWO consecutive ticks
            // (~one extra 5s watchdog period) before declaring the extension gone, so a
            // one-off dropped beat or transient network hiccup can't toggle the badge.
            consecutiveStaleTicks += 1
            if isExtensionConnected && consecutiveStaleTicks >= 2 {
                isExtensionConnected = false
                print("[Bridge] Extension disconnected")
            }
        }
        // An expired pairing window has to stop reading as open in Settings. The
        // socket layer enforces the deadline itself; this only republishes it.
        if let ends = pairingWindowEnds, ends <= Date() {
            pairingWindowEnds = nil
            server?.closePairingWindow()
            print("[Bridge] Pairing window closed — nothing paired")
        }
    }

    // MARK: - Pairing (user-armed)

    /// Opens the one-shot window during which an unrecognized token is adopted.
    /// ONLY a user action in Settings may call this: the extension mints its own
    /// secret, so something has to authorize it, and "whoever posts first" is not
    /// an authorization — a loopback port is reachable by every process on this
    /// Mac, and by any page that can talk to one.
    ///
    /// Arming also DROPS the current pairing, so re-installing the extension (new
    /// random secret) is a two-click recovery rather than a permanent lockout.
    func beginPairing() {
        pairedToken = nil
        BridgeToken.clearPaired()
        let deadline = Date().addingTimeInterval(Self.pairingWindowSeconds)
        pairingWindowEnds = deadline
        server?.openPairingWindow(until: deadline)
        unauthorizedRequests = 0
        print("[Bridge] Pairing armed for \(Int(Self.pairingWindowSeconds))s — the next extension to post is adopted")
    }

    /// Closes the window early (the user changed their mind).
    func cancelPairing() {
        guard pairingWindowEnds != nil else { return }
        pairingWindowEnds = nil
        server?.closePairingWindow()
        print("[Bridge] Pairing cancelled")
    }

    // MARK: - Browser-automation command queue (producer side)

    /// Enqueues one browser command for the extension to execute and suspends
    /// until its result comes back (POST /command-result), or a timeout fires.
    ///
    /// `action` is the wire (camelCase) name automation.js dispatches on
    /// ("navigate", "fillField", …); `params` are its expected keys. Returns the
    /// extension's structured outcome verbatim (`{ok, refused, reason, error, …}`),
    /// or `{"error":"timeout"}` if nothing answered within `commandResultTimeout`,
    /// or `{"error":"cancelled","cancelled":true}` when its producer stops,
    /// or `{"error": …}` if the queue is full. NEVER throws and NEVER hangs — a
    /// disconnected extension resolves to a timeout, not a stuck producer.
    func enqueueBrowserCommand(_ action: String, _ params: [String: Any]) async -> [String: Any] {
        guard !Task.isCancelled else { return Self.cancelledCommandResult }
        expireStaleCommands()
        guard pendingCommands.count < BridgeProtocol.maxPendingCommands else {
            return ["error": "browser command queue is full (\(BridgeProtocol.maxPendingCommands) pending) — the extension may be disconnected"]
        }
        let id = nextCommandID
        nextCommandID += 1
        let cancellation = BrowserCommandCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(returning: Self.cancelledCommandResult)
                    return
                }
                // Registration and enqueue are synchronous on the main actor;
                // a result cannot arrive before its continuation is registered.
                commandContinuations[id] = continuation
                commandCancellations[id] = cancellation
                pendingCommands.append(PendingBrowserCommand(id: id, action: action, params: params,
                    enqueuedAt: Date(), cancellation: cancellation))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(BridgeProtocol.commandResultTimeout * 1_000_000_000))
                    self?.timeoutCommand(id)
                }
            }
        }, onCancel: { [weak self] in
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.finishCommand(id, result: Self.cancelledCommandResult)
            }
        })
    }

    /// A real on-demand DOM observation, including an explicit absence of a
    /// composer. Never re-label the cached lastLiveContext as a fresh reading.
    func refreshEmailComposeContext() async -> LiveContext? {
        guard !Task.isCancelled else { return nil }
        guard frontmostBrowserName() != nil else {
            emailComposeUnavailableReason = "Return to the email composer to refresh its contents."
            return nil
        }
        guard let instance = lastForegroundBrowserInstance else {
            emailComposeUnavailableReason = isExtensionConnected ? Self.composeReloadMessage
                : "Connect the Holmes browser extension, then refresh Gmail to enable email drafting."
            return nil
        }
        let result = await enqueueBrowserCommand("read_email_compose", ["_browserInstanceID": instance])
        guard !Task.isCancelled, result["cancelled"] as? Bool != true else { return nil }
        guard result["ok"] as? Bool == true,
              let payload = result["payload"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            emailComposeUnavailableReason = (result["reason"] as? String) ?? Self.composeReloadMessage
            return nil
        }
        // onLiveContext runs synchronously inside ingest. An observer may publish
        // a newer context before that callback returns; the awaiting coordinator
        // must not receive the superseded observation and overwrite that update.
        guard let refreshed = ingest(data), lastLiveContext == refreshed else {
            emailComposeUnavailableReason = "The browser changed before its fresh reading arrived. Return to the composer and try again."
            return nil
        }
        emailComposeUnavailableReason = nil
        return refreshed
    }

    /// Explicit Insert only. The extension compares the exact composer and all
    /// headers and the expected body, then changes only that body. Auto generation
    /// never calls this method; a nonempty rewrite requires explicit review.
    func stageEmailDraft(_ body: String, expected: EmailComposeSnapshot) async throws -> Bool {
        _ = try await writeEmailDraft(body, subject: nil, mode: .replace, expected: expected)
        return true
    }

    /// Writes a draft in the given mode (never sends). The page validates the
    /// exact composer, keeps signature and quote, verifies, and returns an undo token.
    func writeEmailDraft(_ body: String, subject: String?, mode: EmailWriteMode,
                         expected: EmailComposeSnapshot) async throws -> EmailWriteReceipt {
        try Task.checkCancellation()
        guard expected.source == .browser, expected.bodyReadable,
              !EmailComposeSnapshot.isBlankBody(body), body.count <= 16_000,
              let app = contextEnvironment.frontmost(),
              app.bundleIdentifier == expected.appBundleIdentifier
                || app.bundleIdentifier == contextEnvironment.ownBundleIdentifier else {
            throw EmailComposeError.unavailable("Return to the original email composer before inserting the draft.")
        }
        guard let encoded = expected.identity.data(using: .utf8),
              let identity = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any],
              let instance = identity.first as? String else {
            throw EmailComposeError.unavailable("The original browser composer is unavailable.")
        }
        try Task.checkCancellation()
        var options: [String: Any] = ["mode": mode.rawValue]
        if let subject, !subject.isEmpty { options["subject"] = subject }
        let result = await enqueueBrowserCommand("fill_email_draft", ["body": body,
            "expected": expected.browserExpectation, "options": options, "_browserInstanceID": instance])
        try Task.checkCancellation()
        if result["cancelled"] as? Bool == true { throw CancellationError() }
        guard result["ok"] as? Bool == true, result["inserted"] as? Bool == true,
              result["identity"] as? String == expected.identity else {
            throw EmailComposeError.unavailable((result["reason"] ?? result["error"]) as? String
                ?? "The composer could not confirm insertion. Your draft is still available to copy.")
        }
        return EmailWriteReceipt(undoToken: result["undoToken"] as? String,
                                 subjectFilled: result["subjectFilled"] as? Bool ?? false)
    }

    /// One click undo of a verified write. The page refuses when the person has
    /// edited the email since, so their changes are never erased.
    func undoEmailDraft(token: String, expected: EmailComposeSnapshot) async throws {
        try Task.checkCancellation()
        guard expected.source == .browser, !token.isEmpty,
              let app = contextEnvironment.frontmost(),
              app.bundleIdentifier == expected.appBundleIdentifier
                || app.bundleIdentifier == contextEnvironment.ownBundleIdentifier,
              let encoded = expected.identity.data(using: .utf8),
              let identity = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any],
              let instance = identity.first as? String else {
            throw EmailComposeError.unavailable("Return to the email Holmes wrote into to undo it.")
        }
        let result = await enqueueBrowserCommand("undo_email_draft", ["token": token,
            "expected": ["identity": expected.identity], "_browserInstanceID": instance])
        try Task.checkCancellation()
        if result["cancelled"] as? Bool == true { throw CancellationError() }
        guard result["ok"] as? Bool == true, result["undone"] as? Bool == true else {
            throw EmailComposeError.unavailable((result["reason"] ?? result["error"]) as? String
                ?? "Holmes could not undo the email. Use Command Z in the email instead.")
        }
    }

    /// Drains and RETURNS the pending commands as the JSON array background.js
    /// expects — `[{"id":Int,"action":String,"params":{…}}]`, or `[]` when empty.
    /// Fetching is destructive: a command is delivered exactly once.
    private func drainCommandsJSON(forInstance instance: String?) -> Data {
        // A GET /commands only reaches here past the token gate, and the extension's
        // worker polls it every ~2s while alive. That poll is therefore an
        // independent, focus-proof proof of life: treat it as a heartbeat so an
        // actively-polling extension stays "connected" even if its bare /heartbeat
        // POSTs are somehow dropped. (Post-eviction the poll stops, so the
        // chrome.alarms heartbeat remains the real backstop — this only strengthens
        // the alive-worker case.)
        noteHeartbeat()
        expireStaleCommands()
        guard !pendingCommands.isEmpty else { return Data("[]".utf8) }
        let batch = pendingCommands.filter {
            guard !$0.cancellation.isCancelled else { return false }
            guard let target = $0.params["_browserInstanceID"] as? String else { return true }
            return target == instance
        }
        let delivered = Set(batch.map(\.id))
        pendingCommands.removeAll { delivered.contains($0.id) }
        let array: [[String: Any]] = batch.map {
            ["id": $0.id, "action": $0.action, "params": $0.params]
        }
        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array) else {
            return Data("[]".utf8)
        }
        return data
    }

    /// Records a POST /command-result body, ignoring unrequested or late results.
    /// A result POST is proof the extension is alive and executing, so it also beats the
    /// connection watchdog.
    private func recordCommandResult(_ data: Data) {
        noteHeartbeat()
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = Self.commandID(from: object["id"]) else {
            print("[Bridge] Dropped a command-result that wasn't a JSON object with an id")
            return
        }
        guard let cancellation = commandCancellations[id] else { return }
        finishCommand(id, result: cancellation.isCancelled ? Self.cancelledCommandResult : object)
    }

    private static var cancelledCommandResult: [String: Any] { ["error": "cancelled", "cancelled": true] }

    /// Removing a queued command prevents future delivery. A command already
    /// delivered may have written its body; cancellation cannot roll that back.
    private func finishCommand(_ id: Int, result: [String: Any]) {
        pendingCommands.removeAll { $0.id == id }
        commandCancellations.removeValue(forKey: id)
        commandContinuations.removeValue(forKey: id)?.resume(returning: result)
    }

    /// Resolves an awaiting continuation with a timeout and clears the command.
    /// Safe to call for an id already resolved — removeValue makes it a no-op.
    private func timeoutCommand(_ id: Int) {
        let cancelled = commandCancellations[id]?.isCancelled == true
        finishCommand(id, result: cancelled ? Self.cancelledCommandResult : ["error": "timeout"])
    }

    /// Drops commands the extension never fetched within the TTL, resolving any
    /// still-parked awaiter so a disconnected extension can't hang producers
    /// forever. (The enqueue await's own timeout is the primary backstop; this is
    /// belt-and-suspenders and also reclaims the pending slot sooner.)
    private func expireStaleCommands() {
        for id in commandCancellations.filter({ $0.value.isCancelled }).map(\.key) {
            finishCommand(id, result: Self.cancelledCommandResult)
        }
        let cutoff = Date().addingTimeInterval(-BridgeProtocol.commandQueueTTL)
        guard pendingCommands.contains(where: { $0.enqueuedAt < cutoff }) else { return }
        let stale = pendingCommands.filter { $0.enqueuedAt < cutoff }
        for command in stale {
            finishCommand(command.id, result: ["error": "expired before the extension fetched it"])
        }
    }

    /// The echoed id comes back as a JSON number (or, defensively, a string).
    /// Normalize every plausible shape to the Int we assigned.
    private static func commandID(from value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    // MARK: - Ingestion (main actor)

    private func noteHeartbeat() {
        lastHeartbeat = Date()
        // A fresh beat clears any accumulated stale count so the hysteresis window
        // always starts over from a known-good state.
        consecutiveStaleTicks = 0
        if !isExtensionConnected { isExtensionConnected = true }
    }

    private func noteUnauthorized(_ path: String) {
        unauthorizedRequests += 1
        print("[Bridge] 401 — missing/invalid \(Self.tokenHeader) on \(path)")
    }

    /// Records the secret adopted inside the user-armed window. Persisted so a
    /// Holmes restart doesn't make the user pair again, and the window is closed
    /// immediately — pairing is one-shot by construction.
    private func notePaired(_ secret: String) {
        pairingWindowEnds = nil
        guard pairedToken != secret else { return }
        pairedToken = secret
        BridgeToken.savePaired(secret)
        print("[Bridge] Paired with an extension (token …\(secret.suffix(4)))")
    }

    /// Parses the payload ON THE MAIN ACTOR (so it can read the frontmost app) and
    /// converts it into an exact LiveContext. JSON is re-decoded here rather than
    /// on the socket thread so only Sendable `Data` crosses the boundary.
    @discardableResult private func ingest(_ data: Data) -> LiveContext? {
        noteHeartbeat()
        // Any POST to /context — even one we later drop (background tab, not frontmost)
        // — is proof the extension is alive and posting, so it counts as an independent
        // liveness signal for refreshConnectionState().
        lastContextPost = Date()

        guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("[Bridge] Dropped a payload that wasn't a JSON object (\(data.count) bytes)")
            return nil
        }

        // A background or hidden tab is not what the user is doing right now.
        // The extension labels these explicitly; narrating one would describe a
        // page the user cannot even see. The heartbeat above still counted, so
        // connectivity stays accurate.
        if let isActiveTab = payload["isActiveTab"] as? Bool, !isActiveTab { return nil }
        if let visible = payload["visible"] as? Bool, !visible { return nil }
        if (payload["emailComposeProtocolVersion"] as? Int ?? 0) < 1 {
            emailComposeUnavailableReason = Self.composeReloadMessage
        }
        let instanceID = payload["browserInstanceId"] as? String ?? ""
        if payload["capturedAt"] != nil {
            guard let date = EmailComposeSnapshot.browserCaptureDate(payload["capturedAt"]),
                  date > (lastPayloadCaptureAt[instanceID] ?? .distantPast) else { return nil }
            lastPayloadCaptureAt[instanceID] = date
        }

        // The extension can only guess its macOS app name from the User-Agent
        // ("Comet" vs "Chrome" is a coin flip there), so prefer the real
        // frontmost app and keep the guess as the fallback.
        // The content script keeps posting for as long as its tab is the ACTIVE
        // tab of its window — which stays true after the user cmd-tabs away to
        // Xcode. Those posts describe a page the user is no longer looking at, so
        // they are dropped rather than relabelled with the browser they left:
        // applying one would put the highest-trust tier on the wrong screen AND
        // refresh the precedence clock from a stale source (HolmesAgent keys its
        // browser-outranks-OCR gate on the time of the last exact context).
        guard let frontmost = frontmostBrowserName() else {
            // The heartbeat above already counted, so connectivity stays accurate.
            return nil
        }
        payload["app"] = frontmost
        let foregroundApp = contextEnvironment.frontmost()
        if !instanceID.isEmpty {
            if foregroundApp?.bundleIdentifier != contextEnvironment.ownBundleIdentifier {
                guard let bundle = foregroundApp?.bundleIdentifier else { return nil }
                if payload["focused"] as? Bool == true {
                    // The DOM document has OS focus, so this is the browser that
                    // actually owns this extension instance (Comet and Chrome
                    // can share a User-Agent but never an instance identity).
                    browserBundlesByInstance[instanceID] = bundle
                }
                guard browserBundlesByInstance[instanceID] == bundle else { return nil }
                lastForegroundBrowserInstance = instanceID
            } else {
                // Holmes's review card owns focus. Keep only the previously
                // identified originating browser, not a background browser's tab.
                guard browserBundlesByInstance[instanceID] != nil,
                      instanceID == lastForegroundBrowserInstance else { return nil }
            }
        }
        if foregroundApp?.bundleIdentifier != contextEnvironment.ownBundleIdentifier {
            payload["appBundleIdentifier"] = foregroundApp?.bundleIdentifier
        } else if let bundle = browserBundlesByInstance[instanceID] {
            payload["appBundleIdentifier"] = bundle
            if let name = contextEnvironment.nameForBundle(bundle) {
                payload["app"] = name
            }
        }

        guard let context = LiveContextBuilder.fromBrowser(payload) else {
            // Not an error: heartbeats and content-free pages land here. Holmes
            // simply keeps the previous context rather than inventing one.
            return nil
        }

        if (payload["emailComposeProtocolVersion"] as? Int ?? 0) >= 1,
           let version = payload["extensionVersion"] as? String,
           version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil {
            contextEnvironment.didObserveExtensionVersion(version)
            extensionVersion = version
            emailComposeUnavailableReason = nil
        }

        lastLiveContext = context
        onLiveContext?(context)
        print("[Bridge] \(context.confidence.rawValue) · \(context.headline)")
        return context
    }

    /// The honest context to show when the user is in a browser but the extension
    /// isn't posting — names the missing piece instead of guessing at the page.
    func unavailableContext(window: String = "") -> LiveContext {
        LiveContextBuilder.extensionUnavailable(app: lastBrowserApp, window: window)
    }

    /// The frontmost browser, or nil when the user is in some OTHER app — in which
    /// case the posting tab is not what they are doing and the payload must be
    /// dropped, not relabelled with the browser they left.
    private func frontmostBrowserName() -> String? {
        let name = contextEnvironment.frontmost()?.name ?? ""
        let lower = name.lowercased()
        if Self.isBrowserName(lower) {
            lastBrowserApp = name
            return name
        }
        // Holmes's own panel is frontmost — the browser behind it still owns the
        // page the user is reading, so keep narrating it.
        if lower.contains("holmes") { return lastBrowserApp }
        return nil
    }

    private nonisolated static let knownBrowsers: Set<String> = ["comet", "safari", "chrome", "chromium", "firefox", "arc",
                                                     "brave", "edge", "opera", "vivaldi", "orion",
                                                     "dia", "zen"]

    /// Whole-word match on the app name. A substring test relabelled Obsi-dia-n,
    /// Zen-desk and Arc-hive Utility as browsers and published a background
    /// tab's DOM as the user's exact context.
    nonisolated static func isBrowserName(_ lowercasedName: String) -> Bool {
        let words = lowercasedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains(where: { knownBrowsers.contains($0) })
    }
}

// MARK: - BridgeToken
// Two secrets, both at ~/Library/Application Support/Holmes with 0600 permissions:
//   • bridge_token — the one Holmes ISSUES. Generated once with a UUID and reused
//     forever, so the user can paste it into the extension a single time.
//   • paired_token — the one the extension PRESENTED inside a pairing window the
//     user opened in Settings. The extension mints its own secret into
//     chrome.storage.local, which no macOS app can read, so this is how the two
//     ends meet without making the user copy anything — but the adoption is
//     authorized by a human, not by being first to the socket. Once written, only
//     that token (or the issued one) is accepted, until the user arms pairing
//     again (which clears it).

enum BridgeToken {
    static var fileURL: URL { directory.appendingPathComponent("bridge_token", isDirectory: false) }
    static var pairedFileURL: URL { directory.appendingPathComponent("paired_token", isDirectory: false) }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Holmes", isDirectory: true)
    }

    /// The extension's adopted secret, or nil when nothing has paired yet.
    static func loadPaired() -> String? {
        guard let data = try? Data(contentsOf: pairedFileURL),
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 16
        else { return nil }
        return value
    }

    static func savePaired(_ secret: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        // Replace rather than append: exactly one extension is paired at a time.
        try? fm.removeItem(at: pairedFileURL)
        if !fm.createFile(atPath: pairedFileURL.path, contents: Data(secret.utf8),
                          attributes: [.posixPermissions: 0o600]) {
            print("[Bridge] WARNING: couldn't persist the pairing at \(pairedFileURL.path) — it will be re-established next launch")
        }
    }

    /// Forgets the current pairing. Called when the user arms a new pairing window
    /// so a re-installed extension (which has a brand-new random secret) can claim
    /// the bridge instead of being locked out by the old one.
    static func clearPaired() {
        try? FileManager.default.removeItem(at: pairedFileURL)
    }

    static func loadOrCreate() -> String {
        let fm = FileManager.default
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }

        if let data = try? Data(contentsOf: url),
           let existing = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 16 {
            // Re-assert 0600 in case the file was created by an older build (or
            // restored from a backup) with looser permissions.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }

        let fresh = UUID().uuidString
        if !fm.createFile(atPath: url.path, contents: Data(fresh.utf8),
                          attributes: [.posixPermissions: 0o600]) {
            print("[Bridge] WARNING: couldn't persist the bridge token at \(url.path) — using an in-memory token for this session")
        }
        return fresh
    }
}

// MARK: - BridgeServer
// The raw BSD-socket HTTP layer (no entitlements needed; the app is unsandboxed).
// Deliberately OUTSIDE the main actor: accept()/recv() block. It authenticates,
// reads a complete request, replies, and hands the raw bytes to the main actor —
// it never touches Holmes state itself.

private final class BridgeServer: @unchecked Sendable {

    enum StartResult {
        case success
        case failure(String)
    }

    private let port: UInt16
    private let token: String
    private let maxBodyBytes: Int
    private let onPayload: @Sendable (Data) -> Void
    private let onHeartbeat: @Sendable () -> Void
    private let onUnauthorized: @Sendable (String) -> Void
    private let onPaired: @Sendable (String) -> Void
    /// Synchronously drains + returns the queued commands as the JSON array
    /// background.js expects. Called on the client queue; hops to the main actor.
    private let onCommandsPoll: @Sendable (String?) -> Data
    /// Hands off a POST /command-result body (fire-and-forget, like onPayload).
    private let onCommandResult: @Sendable (Data) -> Void

    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false
    /// The extension's own secret. Read and written under `lock` because every
    /// connection is handled on its own queue.
    private var pairedToken: String?
    /// Deadline of the user-armed pairing window. Nil (or past) means the ONLY
    /// accepted secrets are the issued token and the one already paired — no
    /// caller can talk its way into the bridge on its own initiative.
    private var pairingWindowEnds: Date?

    /// Handlers run here rather than on the shared global pool. A stalled socket
    /// holds a slot, and the semaphore caps how many can stall at once — the
    /// global pool is also OCR's and vision encoding's, and starving it would take
    /// the whole perception loop down with the bridge.
    private let clientQueue = DispatchQueue(label: "com.holmes.bridge.clients",
                                            qos: .userInitiated,
                                            attributes: .concurrent)
    private let clientSlots = DispatchSemaphore(value: BridgeProtocol.maxConcurrentClients)

    init(port: UInt16,
         token: String,
         pairedToken: String?,
         maxBodyBytes: Int,
         onPayload: @escaping @Sendable (Data) -> Void,
         onHeartbeat: @escaping @Sendable () -> Void,
         onUnauthorized: @escaping @Sendable (String) -> Void,
         onPaired: @escaping @Sendable (String) -> Void,
         onCommandsPoll: @escaping @Sendable (String?) -> Data,
         onCommandResult: @escaping @Sendable (Data) -> Void) {
        self.port = port
        self.token = token
        self.pairedToken = pairedToken
        self.maxBodyBytes = maxBodyBytes
        self.onPayload = onPayload
        self.onHeartbeat = onHeartbeat
        self.onUnauthorized = onUnauthorized
        self.onPaired = onPaired
        self.onCommandsPoll = onCommandsPoll
        self.onCommandResult = onCommandResult
    }

    // MARK: Socket lifecycle

    /// Binds + listens synchronously so the caller learns immediately whether the
    /// bridge is really up, then accepts on a background queue.
    func startListening() -> StartResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure("socket() failed: \(errno)") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // LOOPBACK ONLY. Never INADDR_ANY: this socket carries the full contents of
        // every page the user visits, and INADDR_ANY would serve it to the network.
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return .failure("bind() failed on 127.0.0.1:\(port) (errno \(errno)) — is another Holmes running?")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            return .failure("listen() failed: \(errno)")
        }

        lock.lock()
        serverFD = fd
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        return .success
    }

    func stopListening() {
        lock.lock()
        running = false
        let fd = serverFD
        serverFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private var listeningFD: Int32 {
        lock.lock(); defer { lock.unlock() }
        return serverFD
    }

    private func acceptLoop() {
        while isRunning {
            let fd = listeningFD
            guard fd >= 0 else { break }
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                if isRunning { continue } else { break }
            }
            // SO_NOSIGPIPE: a browser that disconnects mid-write must not raise
            // SIGPIPE and kill the whole app — send() returns EPIPE instead.
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Receive/send deadlines. Without them recv() blocks forever, so a
            // client that connects and says nothing — or promises a Content-Length
            // it never delivers — parks a worker thread until Holmes quits, and a
            // few dozen of those are enough to stop the bridge accepting real
            // extension traffic. EAGAIN from an expired timeout is treated as a
            // hard failure by readRequest.
            var timeout = timeval(tv_sec: BridgeProtocol.socketTimeoutSeconds, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Back-pressure belongs HERE, before the dispatch: an async block that
            // waits on the semaphore would just move the thread explosion into the
            // client queue. Blocking the accept loop instead means a flood of
            // stalled connections queues in the listen backlog and dies there.
            let slots = clientSlots
            slots.wait()
            clientQueue.async { [weak self] in
                // Held by the closure, not by self, so the permit is returned even
                // if the server was torn down while this connection was queued.
                defer { slots.signal() }
                guard let self else {
                    close(clientFD)
                    return
                }
                self.handleClient(clientFD)
            }
        }
    }

    // MARK: HTTP

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]   // keys lowercased
        let body: Data
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let request = readRequest(fd) else { return }

        // Path without a query string — the extension may append cache-busters.
        let path = request.path.components(separatedBy: "?").first ?? request.path
        let origin = request.headers["origin"]

        // CORS preflight must NOT require the token: the browser sends preflights
        // without custom headers, so demanding one here would block every request.
        // It DOES require an extension origin, though — answering "*" here is what
        // let an ordinary page clear the preflight and then post whatever it liked.
        if request.method == "OPTIONS" {
            write(fd, status: "204 No Content", headers: corsHeaders(origin: origin), body: Data())
            return
        }

        // Liveness probe carrying no user data — lets the extension tell "Holmes
        // isn't running" apart from "my token is wrong" and show the right message.
        if request.method == "GET" && path == "/health" {
            writeJSON(fd, status: "200 OK", origin: origin,
                      object: ["ok": true, "service": "holmes-bridge", "tokenRequired": true])
            return
        }

        guard tokenMatches(request.headers[BridgeProtocol.tokenHeaderKey], origin: origin) else {
            onUnauthorized(path)
            writeJSON(fd, status: "401 Unauthorized", origin: origin, object: [
                "error": "Missing or invalid \(BridgeProtocol.tokenHeader)",
                "hint": "Open Holmes → Settings → Privacy → Pair browser extension, then post again within two minutes (or send the token shown there)."
            ])
            return
        }

        // Heartbeats keep `isExtensionConnected` true while the user reads a page
        // that produces no new context.
        if path == "/heartbeat" {
            onHeartbeat()
            writeJSON(fd, status: "200 OK", origin: origin, object: ["ok": true])
            return
        }

        // Browser-automation command channel — behind the SAME token gate as
        // /context (both paths are only reachable past the guard above).
        //   GET  /commands       → drain + return the queued commands as JSON.
        //   POST /command-result → hand the structured outcome to the producer.
        if request.method == "GET" && path == BridgeProtocol.commandsPath {
            var headers = corsHeaders(origin: origin)
            headers["Content-Type"] = "application/json"
            write(fd, status: "200 OK", headers: headers, body: onCommandsPoll(request.headers["x-holmes-browser-instance"]))
            return
        }
        if request.method == "POST" && path == BridgeProtocol.commandResultPath {
            onCommandResult(request.body)
            writeJSON(fd, status: "200 OK", origin: origin, object: ["ok": true])
            return
        }

        guard request.method == "POST" else {
            writeJSON(fd, status: "405 Method Not Allowed", origin: origin,
                      object: ["error": "POST JSON to /context"])
            return
        }
        guard path == "/context" || path == "/live" || path == "/" else {
            writeJSON(fd, status: "404 Not Found", origin: origin,
                      object: ["error": "Unknown path \(path)"])
            return
        }
        guard !request.body.isEmpty else {
            writeJSON(fd, status: "400 Bad Request", origin: origin, object: ["error": "Empty body"])
            return
        }
        // Validate it's JSON here so a malformed payload gets a real 400 instead of
        // being silently dropped on the main actor.
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body),
              parsed is [String: Any] else {
            writeJSON(fd, status: "400 Bad Request", origin: origin,
                      object: ["error": "Body must be a JSON object"])
            return
        }

        onPayload(request.body)
        writeJSON(fd, status: "200 OK", origin: origin, object: ["ok": true])
    }

    // MARK: Authentication

    /// Accepts the issued token or the already-paired one. A secret Holmes has
    /// never seen is adopted ONLY inside the window the user armed in Settings —
    /// see the pairing note at the top of this file. Every comparison is
    /// constant-time so the port can't be used to guess a token one byte at a time.
    private func tokenMatches(_ provided: String?, origin: String?) -> Bool {
        guard let provided else { return false }
        let candidate = provided.trimmingCharacters(in: .whitespaces)
        if constantTimeEqual(candidate, token) { return true }

        lock.lock()
        let known = pairedToken
        let pairingOpen = (pairingWindowEnds.map { $0 > Date() }) ?? false
        lock.unlock()

        if let known { return constantTimeEqual(candidate, known) }

        // Unknown secret, and the user hasn't armed pairing: reject. This is the
        // whole fix — adopting here on first contact meant any local process, or
        // any page that could clear the preflight, could claim the bridge, lock the
        // real extension out permanently, and then feed .exact context straight
        // into an agent that holds tool access.
        guard pairingOpen else { return false }

        // Shape check, so a stray probe with an empty or junk header can't consume
        // the armed window.
        guard (16...256).contains(candidate.count),
              candidate.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
        else { return false }

        // Even inside the window, page JavaScript can never pair: an http(s)
        // Origin means the request came from a site, not from the Holmes
        // extension's background worker. No Origin at all is fine — that is a
        // native client, which the user armed the window for.
        guard Self.mayPair(origin: origin) else {
            print("[Bridge] Refused to pair with origin \(origin ?? "?") — only extension origins may pair")
            return false
        }

        lock.lock()
        // Re-check under the lock: two concurrent requests must not both pair.
        if let raced = pairedToken {
            lock.unlock()
            return constantTimeEqual(candidate, raced)
        }
        guard (pairingWindowEnds.map { $0 > Date() }) ?? false else {
            lock.unlock()
            return false
        }
        pairedToken = candidate
        pairingWindowEnds = nil   // one-shot: the window closes the moment it is used
        lock.unlock()

        onPaired(candidate)
        return true
    }

    /// Opens the user-armed adoption window (called from Settings).
    func openPairingWindow(until deadline: Date) {
        lock.lock()
        pairedToken = nil
        pairingWindowEnds = deadline
        lock.unlock()
    }

    /// Closes it — on cancel, on expiry, or after a successful pairing.
    func closePairingWindow() {
        lock.lock()
        pairingWindowEnds = nil
        lock.unlock()
    }

    /// Origins allowed to pair. NO Origin header at all means a native client
    /// (curl, another Mac app) — permitted, because the user armed the window for
    /// exactly that. Any browser-supplied origin must be an extension: a site
    /// origin is page JavaScript, and "null" is an opaque browser origin (sandboxed
    /// iframe, file://), which is page JavaScript wearing a disguise.
    private static func mayPair(origin: String?) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces),
              !origin.isEmpty else { return true }
        return isExtensionOrigin(origin)
    }

    /// A browser extension's own origin — the only thing the bridge speaks CORS to.
    private static func isExtensionOrigin(_ origin: String) -> Bool {
        let lower = origin.lowercased()
        return lower.hasPrefix("chrome-extension://")
            || lower.hasPrefix("moz-extension://")
            || lower.hasPrefix("safari-web-extension://")
            || lower.hasPrefix("extension://")
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let candidate = Array(lhs.utf8)
        let expected = Array(rhs.utf8)
        guard candidate.count == expected.count, !expected.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in 0..<expected.count {
            difference |= candidate[index] ^ expected[index]
        }
        return difference == 0
    }

    /// Reads a COMPLETE HTTP/1.1 request: headers first, then exactly
    /// Content-Length bytes of body. The old single 8 KB recv truncated real DOM
    /// payloads into invalid JSON — the whole reason large pages "didn't work".
    ///
    /// Two independent stops keep a slow client from owning this handler forever:
    /// the per-recv timeout set on the socket (an expired one returns -1/EAGAIN,
    /// which is treated as a hard failure) and the overall deadline below, which
    /// catches the client that trickles one byte per timeout window.
    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(BridgeProtocol.requestDeadline)

        // 1 — read until end-of-headers.
        while headerEnd == nil {
            guard Date() < deadline else { return nil }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil && buffer.count > 64 * 1024 { return nil }  // absurd header block
        }
        guard let end = headerEnd,
              let headerText = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        // Split each header on its FIRST colon only; a value-less header must not crash.
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0, contentLength <= maxBodyBytes else {
            writeJSON(fd, status: "413 Payload Too Large", origin: headers["origin"],
                      object: ["error": "Body exceeds \(maxBodyBytes) bytes"])
            return nil
        }

        // 2 — read the body until Content-Length is satisfied. A stall or a close
        // before that point yields a truncated payload, which is not a request:
        // drop the connection rather than handing half a DOM to the parser.
        var body = Data(buffer[end.upperBound...])
        while body.count < contentLength {
            guard Date() < deadline else { return nil }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            body.append(contentsOf: chunk[0..<n])
            if body.count > maxBodyBytes {
                writeJSON(fd, status: "413 Payload Too Large", origin: headers["origin"],
                          object: ["error": "Body exceeds \(maxBodyBytes) bytes"])
                return nil
            }
        }
        if contentLength > 0 { body = body.prefix(contentLength) }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: Responses

    /// CORS is granted to browser EXTENSIONS only, by reflecting their own origin.
    /// The previous "*" let any page on the internet clear a preflight against this
    /// port and then POST with a token of its choosing; page JavaScript now gets no
    /// Access-Control-Allow-Origin at all, so its preflight fails and the request is
    /// never sent. The extension posts through its background worker, which holds
    /// host_permissions and isn't subject to CORS in the first place.
    /// `Vary: Origin` keeps any intermediary from caching one origin's answer for
    /// another. The token remains the real boundary; this just stops the bridge
    /// advertising itself to every page in the browser.
    private func corsHeaders(origin: String?) -> [String: String] {
        var headers = ["Vary": "Origin"]
        guard let origin = origin?.trimmingCharacters(in: .whitespaces),
              !origin.isEmpty, Self.isExtensionOrigin(origin) else { return headers }
        headers["Access-Control-Allow-Origin"] = origin
        headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, \(BridgeProtocol.tokenHeader), X-Holmes-Browser-Instance"
        headers["Access-Control-Max-Age"] = "600"
        return headers
    }

    private func writeJSON(_ fd: Int32, status: String, origin: String?, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var headers = corsHeaders(origin: origin)
        headers["Content-Type"] = "application/json"
        write(fd, status: status, headers: headers, body: body)
    }

    private func write(_ fd: Int32, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = send(fd, base + sent, out.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
