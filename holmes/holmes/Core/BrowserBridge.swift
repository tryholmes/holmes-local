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
    /// Hard ceiling on a single page context payload. A full DOM extract is ~50-200 KB.
    static let maxBodyBytes = 512 * 1024
    /// Ceiling for POST /command-result. Results legitimately carry screenshots and
    /// large extracts, which the 512 KB context cap rejected and the extension then
    /// reported as a timeout. Still bounded so a runaway result cannot exhaust memory.
    static let maxCommandResultBytes = 16 * 1024 * 1024
    /// An oversize body is read and discarded up to this many bytes before the 413
    /// goes out, so the client sees the status instead of a reset connection.
    /// Anything larger is refused without draining.
    static let maxDrainBytes = 64 * 1024 * 1024
    /// Per-recv/send socket timeout. Long enough for a 512 KB body over loopback,
    /// short enough that a silent client releases its slot promptly.
    static let socketTimeoutSeconds = 5
    /// Overall deadline for reading one request, so a client that trickles a byte
    /// every four seconds can't hold a handler open indefinitely.
    static let requestDeadline: TimeInterval = 10
    /// Concurrent request handlers. The extension uses one connection at a time;
    /// this is headroom, not a throughput knob.
    static let maxConcurrentClients = 8
    /// How long the accept loop waits for a free handler before answering 503.
    static let slotWaitSeconds: Double = 2
    /// Paired extension tokens kept at once (one per browser or profile). Pairing
    /// one more than this forgets the least recently seen.
    static let maxPairedExtensions = 8

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
    /// How long a command may sit UNFETCHED before the producer gives up with the
    /// distinct `extension_asleep` error. An MV3 worker that was evicted is only
    /// woken by its alarm or a content script ping, so this is deliberately longer
    /// than the result timeout: slow pickup is a different failure from a command
    /// that was received and never answered.
    static let commandUndeliveredTimeout: TimeInterval = 45
    /// Kept for callers that still read the old name. Same value as above.
    static let commandQueueTTL: TimeInterval = commandUndeliveredTimeout
    /// How long enqueueBrowserCommand awaits a result AFTER the extension fetched
    /// the command, before returning {"error":"timeout"}. Measured from delivery,
    /// not enqueue, so time spent waiting for a sleeping worker never eats into
    /// the time the page has to run the action.
    static let commandResultTimeout: TimeInterval = 20
    /// Longest a GET /commands long poll is held open. It returns the moment a
    /// command for that browser is enqueued. Kept under 30s because Chrome kills
    /// an MV3 worker whose fetch has waited 30s for a response.
    static let longPollMaxSeconds: TimeInterval = 22
    /// Long polls each hold a handler slot, so only a few may wait at once; any
    /// extra poll is answered immediately instead of starving heartbeats.
    static let maxConcurrentLongPolls = 3
    /// A browser instance that has not polled or beaten within this window is not
    /// considered when routing a command that names no browser.
    static let instanceFreshness: TimeInterval = 40
    /// Request header the extension sets to ask for a long poll (seconds).
    static let longPollHeaderKey = "x-holmes-long-poll"
    static let instanceHeaderKey = "x-holmes-browser-instance"
    static let focusedHeaderKey = "x-holmes-browser-focused"
}

/// Exponential backoff with a ceiling. Used for accept() failures (so a broken
/// listening socket cannot spin a core at 100%) and for retrying bind().
struct BridgeBackoff {
    let base: TimeInterval
    let cap: TimeInterval
    private(set) var consecutiveFailures = 0

    init(base: TimeInterval, cap: TimeInterval) {
        self.base = base
        self.cap = cap
    }

    /// Records one failure and returns how long to wait before trying again.
    mutating func failure() -> TimeInterval {
        consecutiveFailures += 1
        let exponent = Double(min(consecutiveFailures - 1, 30))
        return min(cap, base * pow(2, exponent))
    }

    mutating func success() { consecutiveFailures = 0 }
}

/// One authorized request that proves an extension is alive, handed from the
/// socket layer to the main actor: which token authenticated it, the browser
/// instance and focus it reported, and (for heartbeats) its body.
struct BridgeSighting: Sendable {
    let token: String
    let instance: String?
    let focused: Bool?
    let body: Data?
}

/// The browser command queue, shared by the main actor (producer) and the socket
/// layer (GET /commands). Guarded by a condition lock instead of main actor
/// isolation: a poll must never wait on a busy main thread, and a long poll has to
/// sleep until a command arrives without holding anything but its own socket.
final class BrowserCommandQueue: @unchecked Sendable {
    struct Delivery {
        let id: Int
        let action: String
        let params: [String: Any]
    }

    enum State: Equatable {
        case pending(since: Date)
        case delivered(since: Date)
    }

    private struct Entry {
        let id: Int
        let action: String
        let params: [String: Any]
        let target: String?
        let enqueuedAt: Date
        var deliveredAt: Date?
        let cancellation: BrowserCommandCancellation
    }

    private struct Sighting {
        var lastSeen: Date
        var activeAt: Date
    }

    /// Random per app launch. Echoed by the extension so a result for command 7 of
    /// a previous launch can never complete command 7 of this one, and so the
    /// worker's idempotency cache never replays an old launch's result.
    let session: String
    private let condition = NSCondition()
    private var pending: [Entry] = []
    private var delivered: [Int: Entry] = [:]
    private var sightings: [String: Sighting] = [:]
    private var activeLongPolls = 0
    private let maxPending: Int
    private let longPollCap: TimeInterval

    init(session: String = UUID().uuidString,
         maxPending: Int = BridgeProtocol.maxPendingCommands,
         longPollCap: TimeInterval = BridgeProtocol.longPollMaxSeconds) {
        self.session = session
        self.maxPending = maxPending
        self.longPollCap = longPollCap
    }

    var pendingIDs: [Int] {
        condition.lock(); defer { condition.unlock() }
        return pending.map(\.id)
    }

    var deliveredIDs: [Int] {
        condition.lock(); defer { condition.unlock() }
        return delivered.keys.sorted()
    }

    /// False when the queue is full. Wakes every waiting long poll.
    func enqueue(id: Int, action: String, params: [String: Any], cancellation: BrowserCommandCancellation) -> Bool {
        condition.lock(); defer { condition.unlock() }
        pending.removeAll { $0.cancellation.isCancelled }
        guard pending.count < maxPending else { return false }
        pending.append(Entry(id: id, action: action, params: params,
                             target: params["_browserInstanceID"] as? String,
                             enqueuedAt: Date(), deliveredAt: nil, cancellation: cancellation))
        condition.broadcast()
        return true
    }

    func state(of id: Int) -> State? {
        condition.lock(); defer { condition.unlock() }
        if let entry = delivered[id], let at = entry.deliveredAt { return .delivered(since: at) }
        if let entry = pending.first(where: { $0.id == id }) { return .pending(since: entry.enqueuedAt) }
        return nil
    }

    func remove(_ id: Int) {
        condition.lock(); defer { condition.unlock() }
        pending.removeAll { $0.id == id }
        delivered.removeValue(forKey: id)
    }

    /// The worker reported that a delivered command actually started running (it
    /// may have waited behind another command for the same tab). Restart the result
    /// clock so queueing inside the browser is not counted against the page.
    func markStarted(_ id: Int) {
        condition.lock(); defer { condition.unlock() }
        if delivered[id] != nil { delivered[id]?.deliveredAt = Date() }
    }

    /// Puts delivered commands back at the front of the queue, e.g. when the poll
    /// response could not be written because the extension hung up.
    func requeue(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        condition.lock(); defer { condition.unlock() }
        var restored: [Entry] = []
        for id in ids {
            guard var entry = delivered.removeValue(forKey: id), !entry.cancellation.isCancelled else { continue }
            entry.deliveredAt = nil
            restored.append(entry)
        }
        pending.insert(contentsOf: restored.sorted { $0.id < $1.id }, at: 0)
        condition.broadcast()
    }

    /// Records that a browser instance is alive (it polled or beat). `focused`
    /// is the worker's own report that one of its windows has OS focus.
    func noteSeen(instance: String?, focused: Bool?) {
        guard let instance, !instance.isEmpty else { return }
        condition.lock(); defer { condition.unlock() }
        noteSeenLocked(instance: instance, focused: focused, at: Date())
    }

    /// The app saw this instance's page while its browser was the frontmost app.
    func noteForeground(instance: String, at date: Date = Date()) {
        guard !instance.isEmpty else { return }
        condition.lock(); defer { condition.unlock() }
        var sighting = sightings[instance] ?? Sighting(lastSeen: date, activeAt: date)
        sighting.lastSeen = max(sighting.lastSeen, date)
        sighting.activeAt = max(sighting.activeAt, date)
        sightings[instance] = sighting
        condition.broadcast()
    }

    /// Seeds a remembered instance (from a previous launch) with a tiny preference
    /// over instances that have never been in front, without marking it alive.
    func rememberInstance(_ instance: String) {
        guard !instance.isEmpty else { return }
        condition.lock(); defer { condition.unlock() }
        if sightings[instance] == nil {
            sightings[instance] = Sighting(lastSeen: .distantPast, activeAt: Date(timeIntervalSince1970: 1))
        }
    }

    /// The browser instance a command without `_browserInstanceID` goes to: the
    /// live instance most recently in front, falling back to the most recently
    /// seen one. Nil when no instance is known to be alive.
    /// True when this instance polled, beat or posted context within the freshness
    /// window during this launch. A remembered instance from a previous launch is not.
    func isFresh(_ instance: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let sighting = sightings[instance] else { return false }
        return Date().timeIntervalSince(sighting.lastSeen) < BridgeProtocol.instanceFreshness
    }

    var preferredInstance: String? {
        condition.lock(); defer { condition.unlock() }
        return routeTargetLocked(now: Date())
    }

    /// Drains the commands deliverable to `instance`. With `wait > 0` this is a
    /// long poll: it blocks (without touching the main thread) until a command
    /// arrives, the wait elapses, or `clientGone` reports the extension hung up.
    func drain(instance: String?, focused: Bool?, wait: TimeInterval,
               clientGone: () -> Bool = { false }) -> [Delivery] {
        drainDetailed(instance: instance, focused: focused, wait: wait, clientGone: clientGone).batch
    }

    /// Same as drain, plus whether the request was actually held as a long poll.
    /// A poll refused a hold (the long poll cap was reached) must not be told it
    /// was held, or the worker would re-poll at once and spin.
    func drainDetailed(instance: String?, focused: Bool?, wait: TimeInterval,
                       clientGone: () -> Bool = { false }) -> (batch: [Delivery], held: Bool) {
        condition.lock()
        let start = Date()
        if let instance, !instance.isEmpty { noteSeenLocked(instance: instance, focused: focused, at: start) }
        var deadline = start
        var holdsLongPoll = false
        if wait > 0 && activeLongPolls < BridgeProtocol.maxConcurrentLongPolls {
            activeLongPolls += 1
            holdsLongPoll = true
            deadline = start.addingTimeInterval(min(wait, longPollCap))
        }
        defer {
            if holdsLongPoll { activeLongPolls -= 1 }
            condition.unlock()
        }
        while true {
            let batch = takeDeliverableLocked(instance: instance)
            if !batch.isEmpty { return (batch, holdsLongPoll) }
            let now = Date()
            if now >= deadline { return ([], holdsLongPoll) }
            _ = condition.wait(until: min(deadline, now.addingTimeInterval(0.5)))
            if clientGone() { return ([], holdsLongPoll) }
            if let instance, !instance.isEmpty {
                noteSeenLocked(instance: instance, focused: nil, at: Date())
            }
        }
    }

    static func encode(_ batch: [Delivery], session: String) -> Data {
        let array: [[String: Any]] = batch.map {
            ["id": $0.id, "action": $0.action, "params": $0.params, "session": session]
        }
        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array) else {
            return Data("[]".utf8)
        }
        return data
    }

    private func noteSeenLocked(instance: String, focused: Bool?, at date: Date) {
        var sighting = sightings[instance] ?? Sighting(lastSeen: date, activeAt: .distantPast)
        sighting.lastSeen = date
        if focused == true { sighting.activeAt = date }
        sightings[instance] = sighting
    }

    private func routeTargetLocked(now: Date) -> String? {
        let fresh = sightings.filter { now.timeIntervalSince($0.value.lastSeen) < BridgeProtocol.instanceFreshness }
        return fresh.max { lhs, rhs in
            if lhs.value.activeAt != rhs.value.activeAt { return lhs.value.activeAt < rhs.value.activeAt }
            if lhs.value.lastSeen != rhs.value.lastSeen { return lhs.value.lastSeen < rhs.value.lastSeen }
            return lhs.key < rhs.key
        }?.key
    }

    private func takeDeliverableLocked(instance: String?) -> [Delivery] {
        pending.removeAll { $0.cancellation.isCancelled }
        guard !pending.isEmpty else { return [] }
        let route = routeTargetLocked(now: Date())
        let now = Date()
        var batch: [Delivery] = []
        var remaining: [Entry] = []
        for var entry in pending {
            let deliverable: Bool
            if let target = entry.target {
                deliverable = target == instance
            } else {
                deliverable = route == nil || route == instance
            }
            if deliverable {
                entry.deliveredAt = now
                delivered[entry.id] = entry
                batch.append(Delivery(id: entry.id, action: entry.action, params: entry.params))
            } else {
                remaining.append(entry)
            }
        }
        pending = remaining
        return batch
    }
}

/// Cancellation handlers run outside the main actor. Mark synchronously so a
/// polling drain can refuse a cancelled command before its actor cleanup runs.
final class BrowserCommandCancellation: @unchecked Sendable {
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
    /// True while the extension's worker is alive (heartbeats arrive) but the page
    /// itself is not sending context: the active tab's content script is missing
    /// or orphaned. isExtensionConnected keeps its worker-liveness meaning for
    /// existing callers; this is the extra truth the UI must not paper over.
    private(set) var isPageContextStale = false
    /// The worker's latest report about the active tab's content script.
    @ObservationIgnored private var lastActiveTabProbe: (script: String, at: Date)?
    /// When isExtensionConnected last turned true.
    @ObservationIgnored private var connectedSince: Date?
    /// A page context post from an extension too old to draft email was seen.
    @ObservationIgnored private var observedLegacyProtocol = false
    /// Where the last foreground browser instance is remembered across launches.
    @ObservationIgnored private var instanceDefaults: UserDefaults? = .standard
    static let lastInstanceDefaultsKey = "HolmesLastForegroundBrowserInstance"
    /// Legacy extensions (no active tab probe): how long a frontmost browser may
    /// stay silent while its worker beats before the page counts as stale.
    static let pageContextTimeout: TimeInterval = 180

    /// One state for the notch and Settings, so they never claim a full connection
    /// from worker heartbeats alone or hide a bridge that is not listening.
    enum LinkState: Equatable {
        case notListening(String)
        case disconnected
        case connected
        case pageContextStale
    }

    var linkState: LinkState {
        if !isRunning, let lastError { return .notListening(lastError) }
        guard isExtensionConnected else { return .disconnected }
        return isPageContextStale ? .pageContextStale : .connected
    }
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

    /// Every extension the user paired, one per browser or profile. Surfaced in
    /// Settings (with Remove) so "paired" is visible state, not something the user
    /// has to infer from traffic. Pairing a new browser never drops the others.
    private(set) var pairedExtensions: [PairedExtension] = []

    /// The most recently active paired token. Kept for callers that only need to
    /// know whether anything is paired at all.
    var pairedToken: String? {
        pairedExtensions.max { ($0.lastSeen ?? $0.pairedAt) < ($1.lastSeen ?? $1.pairedAt) }?.token
    }

    @ObservationIgnored private var pairingStore = PairedExtensionStore.files

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
    // The queue itself lives in BrowserCommandQueue behind a lock, so GET /commands
    // never waits for the main thread. The continuations stay @MainActor state.
    @ObservationIgnored let commandQueue = BrowserCommandQueue()
    /// Includes delivered commands while their producer still awaits a result.
    private var commandCancellations: [Int: BrowserCommandCancellation] = [:]
    /// The awaiting continuations, keyed by command id. Exactly one of {result
    /// POST, cancellation, delivery timeout, undelivered timeout} resumes each, all
    /// via removeValue, so a continuation can never be resumed twice.
    private var commandContinuations: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    /// Monotonic id source. A plain incrementing Int (not a UUID/Date) so echoed
    /// results can never collide, and so ids stay small and legible on the wire.
    private var nextCommandID = 1
    /// Ids that already resolved with a timeout. A result that arrives for one of
    /// these later is logged and ignored; it never resolves or re-enqueues anything.
    @ObservationIgnored private var expiredCommandIDs: [Int] = []
    /// How many late results were ignored. Surfaced for diagnostics and tests.
    private(set) var lateResultsIgnored = 0
    /// Overridable so tests can exercise both deadlines without waiting a minute.
    @ObservationIgnored var commandResultTimeout = BridgeProtocol.commandResultTimeout
    @ObservationIgnored var commandUndeliveredTimeout = BridgeProtocol.commandUndeliveredTimeout
    /// Port to bind. The real app always uses 5766; tests bind an ephemeral port.
    @ObservationIgnored private var listenPort: UInt16 = BridgeProtocol.port
    /// The port actually bound (differs from listenPort only when that is 0).
    private(set) var boundPort: UInt16?

    private init() {
        token = BridgeToken.loadOrCreate()
        pairedExtensions = pairingStore.load()
        loadRememberedInstance()
    }

    /// Restores the browser instance that was last in front, so the first compose
    /// refresh after an app restart targets it instead of claiming a reload is needed.
    private func loadRememberedInstance() {
        guard let remembered = instanceDefaults?.string(forKey: Self.lastInstanceDefaultsKey), !remembered.isEmpty else { return }
        lastForegroundBrowserInstance = remembered
        commandQueue.rememberInstance(remembered)
    }

    private func rememberForeground(_ instance: String, fromApp: Bool) {
        guard !instance.isEmpty else { return }
        if lastForegroundBrowserInstance != instance {
            lastForegroundBrowserInstance = instance
            instanceDefaults?.set(instance, forKey: Self.lastInstanceDefaultsKey)
        }
        if fromApp { commandQueue.noteForeground(instance: instance) }
    }

    #if DEBUG
    /// Isolated integration harness: real queue/parser, fake OS identity and no
    /// token files, browser access or app activation. `port` 0 binds an ephemeral
    /// loopback port when a test calls start().
    init(testToken: String, environment: ContextEnvironment, port: UInt16 = 0,
         pairingStore: PairedExtensionStore = .memory()) {
        token = testToken
        contextEnvironment = environment
        listenPort = port
        self.pairingStore = pairingStore
        pairedExtensions = pairingStore.load()
        instanceDefaults = nil
    }
    func testUseInstanceDefaults(_ defaults: UserDefaults) {
        instanceDefaults = defaults
        loadRememberedInstance()
    }
    func testSighting(_ sighting: BridgeSighting) { noteSighting(sighting) }
    func testRefreshConnectionState(now: Date) { refreshConnectionState(now: now) }
    func testIngest(_ data: Data) -> LiveContext? { ingest(data) }
    func testDrainCommands(instance: String?) -> Data { drainCommandsJSON(forInstance: instance) }
    func testCommandResult(_ data: Data) { recordCommandResult(data) }
    var testPendingCommandIDs: [Int] { commandQueue.pendingIDs }
    var testAwaitingCommandCount: Int { commandContinuations.count }
    var testTrackedCommandCount: Int { commandCancellations.count }
    #endif

    // MARK: - Lifecycle

    /// True between start() and stop(), whether or not the bind succeeded yet.
    @ObservationIgnored private var wantsRunning = false
    /// Pending background bind retry after the port was unavailable.
    @ObservationIgnored private var bindRetryTask: Task<Void, Never>?
    /// Delay schedule for bind retries. Tests shorten it.
    @ObservationIgnored var bindBackoff = BridgeBackoff(base: 2, cap: 60)

    /// Binds + listens. Safe to call repeatedly; a second call is a no-op. If the
    /// port is taken, the reason is published through lastError (Settings and the
    /// notch show it) and the bind is retried in the background with backoff.
    func start() {
        wantsRunning = true
        guard !isRunning else { return }

        // Every callback hops to the main actor fire-and-forget. None of them
        // blocks the socket thread: GET /commands reads the lock-guarded queue
        // directly, so a busy main thread can no longer fill the handler slots.
        let server = BridgeServer(
            port: listenPort,
            token: token,
            pairedTokens: pairedExtensions.map(\.token),
            maxBodyBytes: Self.maxBodyBytes,
            commandQueue: commandQueue,
            onPayload: { [weak self] data in
                Task { @MainActor in self?.ingest(data) }
            },
            onSighting: { [weak self] sighting in
                Task { @MainActor in self?.noteSighting(sighting) }
            },
            onUnauthorized: { [weak self] path in
                Task { @MainActor in self?.noteUnauthorized(path) }
            },
            onPaired: { [weak self] secret in
                Task { @MainActor in self?.notePaired(secret) }
            },
            onCommandResult: { [weak self] data in
                Task { @MainActor in self?.recordCommandResult(data) }
            }
        )

        switch server.startListening() {
        case .success(let port):
            self.server = server
            boundPort = port
            isRunning = true
            lastError = nil
            print("[Bridge] Listening on http://127.0.0.1:\(port) (loopback only, token required)")
            print("[Bridge] Token file: \(Self.tokenFileURL.path)")
            bindBackoff.success()
            bindRetryTask?.cancel()
            bindRetryTask = nil
            startWatchdog()
        case .failure(let message):
            let delay = bindBackoff.failure()
            lastError = "\(message) Retrying in \(Int(delay.rounded(.up)))s."
            print("[Bridge] NOT listening — \(message) (retry in \(delay)s)")
            scheduleBindRetry(after: delay)
        }
    }

    private func scheduleBindRetry(after delay: TimeInterval) {
        bindRetryTask?.cancel()
        bindRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantsRunning, !self.isRunning else { return }
            self.bindRetryTask = nil
            self.start()
        }
    }

    func stop() {
        wantsRunning = false
        bindRetryTask?.cancel()
        bindRetryTask = nil
        server?.stopListening()
        server = nil
        boundPort = nil
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

    private func refreshConnectionState(now: Date = Date()) {
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
                connectedSince = now
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
        refreshPageContextState(now: now)
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
    /// Arming does NOT drop existing pairings: a second browser (or a re-installed
    /// extension with a new random secret) is added alongside the others. A stale
    /// pairing is removed explicitly from Settings.
    func beginPairing() {
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
        guard JSONSerialization.isValidJSONObject(params) else {
            return ["error": "invalid_params", "message": "The browser command parameters are not valid JSON."]
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
                // a result cannot arrive before its continuation is registered,
                // because results are recorded on the main actor too.
                guard commandQueue.enqueue(id: id, action: action, params: params, cancellation: cancellation) else {
                    continuation.resume(returning: Self.queueFullResult)
                    return
                }
                commandContinuations[id] = continuation
                commandCancellations[id] = cancellation
                Task { @MainActor [weak self] in await self?.superviseCommand(id) }
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
        // The instance comes from a foreground context post, a focused heartbeat or
        // poll, or the one remembered from the previous launch. Only an extension
        // that really is too old (or missing from the page) is told to reload.
        // The remembered browser wins only while it is alive this launch. A browser
        // that was switched away from, or an extension reinstalled with a new
        // instance, must not make the refresh wait out the undelivered deadline.
        let liveRemembered = lastForegroundBrowserInstance.flatMap { commandQueue.isFresh($0) ? $0 : nil }
        guard let instance = liveRemembered ?? commandQueue.preferredInstance ?? lastForegroundBrowserInstance else {
            emailComposeUnavailableReason = observedLegacyProtocol ? Self.composeReloadMessage
                : isExtensionConnected ? "Click into your email tab in the browser so Holmes can find it, then try again."
                : "Connect the Holmes browser extension, then refresh Gmail to enable email drafting."
            return nil
        }
        let result = await enqueueBrowserCommand("read_email_compose", ["_browserInstanceID": instance])
        guard !Task.isCancelled, result["cancelled"] as? Bool != true else { return nil }
        guard result["ok"] as? Bool == true,
              let payload = result["payload"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            emailComposeUnavailableReason = Self.browserFailureMessage(result)
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
        let result = await enqueueBrowserCommand("fill_email_draft", ["body": body,
            "expected": expected.browserExpectation, "_browserInstanceID": instance])
        try Task.checkCancellation()
        if result["cancelled"] as? Bool == true { throw CancellationError() }
        guard result["ok"] as? Bool == true, result["inserted"] as? Bool == true,
              result["identity"] as? String == expected.identity else {
            throw EmailComposeError.unavailable(result["reason"] != nil || result["error"] != nil
                ? Self.browserFailureMessage(result)
                : "The composer could not confirm insertion. Your draft is still available to copy.")
        }
        return true
    }

    /// Drains and RETURNS the pending commands as the JSON array background.js
    /// expects — `[{"id":Int,"action":String,"params":{…}}]`, or `[]` when empty.
    /// Fetching is destructive: a command is delivered exactly once.
    private func drainCommandsJSON(forInstance instance: String?) -> Data {
        // A GET /commands only reaches here past the token gate, so it is an
        // independent, focus-proof proof of life: treat it as a heartbeat.
        noteHeartbeat()
        expireStaleCommands()
        let batch = commandQueue.drain(instance: instance, focused: nil, wait: 0)
        return BrowserCommandQueue.encode(batch, session: commandQueue.session)
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
        // A result stamped with another launch's session belongs to a command this
        // launch never issued, even if the numeric id happens to match.
        if let session = object["session"] as? String, session != commandQueue.session { return }
        if object["_holmesStarted"] as? Bool == true {
            commandQueue.markStarted(id)
            return
        }
        guard let cancellation = commandCancellations[id] else {
            if expiredCommandIDs.contains(id) {
                lateResultsIgnored += 1
                print("[Bridge] Ignored a late result for command \(id); it already timed out and is not re-run")
            }
            return
        }
        finishCommand(id, result: cancellation.isCancelled ? Self.cancelledCommandResult : object)
    }

    private static var cancelledCommandResult: [String: Any] { ["error": "cancelled", "cancelled": true] }

    static var queueFullResult: [String: Any] {
        ["error": "queue_full",
         "message": "Holmes already has \(BridgeProtocol.maxPendingCommands) browser commands waiting. The extension may be disconnected; wait a moment and try again."]
    }

    static func extensionAsleepResult(after seconds: TimeInterval) -> [String: Any] {
        ["error": "extension_asleep", "undelivered": true,
         "message": "The Holmes browser extension did not pick up this command within \(Int(seconds))s. Its background worker may be asleep or the browser may be closed. Click into a browser tab, then try again. The command was never run."]
    }

    static func deliveredTimeoutResult(after seconds: TimeInterval) -> [String: Any] {
        ["error": "timeout", "delivered": true,
         "message": "The browser received this command but did not report a result within \(Int(seconds))s. It may still have run, so check the page before retrying."]
    }

    /// Watches one command's two deadlines: undelivered (the worker never fetched
    /// it) and delivered (fetched but no result). Resolves the awaiter exactly once.
    private func superviseCommand(_ id: Int) async {
        while commandContinuations[id] != nil {
            if commandCancellations[id]?.isCancelled == true {
                finishCommand(id, result: Self.cancelledCommandResult)
                return
            }
            let now = Date()
            let deadline: Date
            switch commandQueue.state(of: id) {
            case .pending(let since)?:
                deadline = since.addingTimeInterval(commandUndeliveredTimeout)
                if now >= deadline {
                    expireCommand(id, result: Self.extensionAsleepResult(after: commandUndeliveredTimeout))
                    return
                }
            case .delivered(let since)?:
                deadline = since.addingTimeInterval(commandResultTimeout)
                if now >= deadline {
                    expireCommand(id, result: Self.deliveredTimeoutResult(after: commandResultTimeout))
                    return
                }
            case nil:
                // Not in the queue but still awaited: only a cancellation drop can
                // do that, and the branch above handles it. Never hang regardless.
                expireCommand(id, result: Self.deliveredTimeoutResult(after: commandResultTimeout))
                return
            }
            let pause = max(0.01, min(0.25, deadline.timeIntervalSince(now)))
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
    }

    /// Removing a queued command prevents future delivery. A command already
    /// delivered may have written its body; cancellation cannot roll that back.
    private func finishCommand(_ id: Int, result: [String: Any]) {
        commandQueue.remove(id)
        commandCancellations.removeValue(forKey: id)
        commandContinuations.removeValue(forKey: id)?.resume(returning: result)
    }

    /// Resolves with a timeout style result and remembers the id, so a result that
    /// shows up afterwards is recognised as late instead of silently vanishing.
    private func expireCommand(_ id: Int, result: [String: Any]) {
        let cancelled = commandCancellations[id]?.isCancelled == true
        guard commandContinuations[id] != nil else { return }
        if !cancelled {
            expiredCommandIDs.append(id)
            if expiredCommandIDs.count > 256 { expiredCommandIDs.removeFirst(expiredCommandIDs.count - 256) }
        }
        finishCommand(id, result: cancelled ? Self.cancelledCommandResult : result)
    }

    /// Resolves cancelled awaiters promptly. Deadlines are enforced per command by
    /// superviseCommand, so nothing else is needed here.
    private func expireStaleCommands() {
        for id in commandCancellations.filter({ $0.value.isCancelled }).map(\.key) {
            finishCommand(id, result: Self.cancelledCommandResult)
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
        if !isExtensionConnected {
            isExtensionConnected = true
            connectedSince = Date()
        }
    }

    /// Page context health. With the worker's active tab probe, stale means the
    /// probe found no content script and no page has posted since. Without a probe
    /// (older extension), stale means a browser is in front yet its page has been
    /// silent for pageContextTimeout while the worker keeps beating.
    private func refreshPageContextState(now: Date) {
        let stale: Bool
        if !isExtensionConnected {
            stale = false
        } else if let probe = lastActiveTabProbe {
            stale = probe.script == "missing" && (lastContextPost.map { $0 < probe.at } ?? true)
        } else {
            let frontIsBrowser = Self.isBrowserName((contextEnvironment.frontmost()?.name ?? "").lowercased())
            let quietSince = lastContextPost ?? connectedSince
            stale = frontIsBrowser && (quietSince.map { now.timeIntervalSince($0) > Self.pageContextTimeout } ?? false)
        }
        guard stale != isPageContextStale else { return }
        isPageContextStale = stale
        print(stale ? "[Bridge] Extension worker is alive but the page is not sending context"
                    : "[Bridge] Page context is flowing again")
    }

    /// Turns a failed browser command result into one accurate, actionable line.
    /// Only a content script that is genuinely missing or orphaned is told to reload.
    nonisolated static func browserFailureMessage(_ result: [String: Any]) -> String {
        let error = result["error"] as? String ?? ""
        let reason = result["reason"] as? String ?? ""
        let text = (reason + " " + error).lowercased()
        switch error {
        case "extension_asleep":
            return "The Holmes extension isn't picking up requests right now (its background worker may be asleep). Click into your browser tab, then try again."
        case "timeout":
            return "Your browser received the request but didn't answer in time. Click into the email tab, then try again."
        case "queue_full":
            return "Holmes has too many browser requests waiting. Wait a few seconds, then try again."
        case "cancelled":
            return "The request was cancelled."
        default:
            break
        }
        if text.contains("receiving end does not exist") || text.contains("could not establish connection")
            || text.contains("content script is missing") {
            return "Holmes isn't loaded in that tab. Refresh the email tab; if that doesn't help, reload Holmes on chrome://extensions."
        }
        if text.contains("result too large") {
            return "The browser's answer was too large to send. Try again with a smaller page or selection."
        }
        if text.contains("no longer in the active tab") || text.contains("active tab changed")
            || text.contains("no active browser tab") || text.contains("did not become visible") {
            return "Bring the email tab to the front in your browser, then try again."
        }
        if text.contains("no active compose window") || text.contains("compose reader did not respond") || text.contains("no composer") {
            return "Open the email you're writing in the browser, then try again."
        }
        if !reason.isEmpty { return reason }
        if let message = result["message"] as? String, !message.isEmpty { return message }
        if !error.isEmpty { return "The browser couldn't finish that request: \(error)" }
        return "The browser didn't return a composer reading. Try again."
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
        guard !pairedExtensions.contains(where: { $0.token == secret }) else { return }
        let now = Date()
        pairedExtensions.append(PairedExtension(token: secret, label: "Browser extension", instanceID: nil,
                                                pairedAt: now, lastSeen: now))
        if pairedExtensions.count > BridgeProtocol.maxPairedExtensions {
            pairedExtensions.sort { ($0.lastSeen ?? $0.pairedAt) > ($1.lastSeen ?? $1.pairedAt) }
            pairedExtensions.removeLast(pairedExtensions.count - BridgeProtocol.maxPairedExtensions)
            server?.setPairedTokens(pairedExtensions.map(\.token))
        }
        pairingStore.save(pairedExtensions)
        print("[Bridge] Paired with an extension (token …\(secret.suffix(4))); \(pairedExtensions.count) paired")
    }

    /// Forgets one paired extension (Settings ▸ Remove). Its token is refused from
    /// the next request on; the other pairings are untouched.
    func removePairedExtension(_ token: String) {
        pairedExtensions.removeAll { $0.token == token }
        server?.setPairedTokens(pairedExtensions.map(\.token))
        pairingStore.save(pairedExtensions)
    }

    /// A heartbeat or poll authenticated with a paired token: keeps the connection
    /// fresh and labels that pairing with the browser instance it came from.
    private func noteSighting(_ sighting: BridgeSighting) {
        noteHeartbeat()
        // A worker reporting OS focus identifies the browser in front, even when no
        // page has posted context since Holmes launched.
        if sighting.focused == true, let instance = sighting.instance, !instance.isEmpty {
            rememberForeground(instance, fromApp: false)
        }
        if let body = sighting.body, !body.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let activeTab = object["activeTab"] as? [String: Any],
           let script = activeTab["script"] as? String {
            lastActiveTabProbe = (script, Date())
            refreshPageContextState(now: Date())
        }
        guard let index = pairedExtensions.firstIndex(where: { $0.token == sighting.token }) else { return }
        var entry = pairedExtensions[index]
        let now = Date()
        var persist = entry.lastSeen.map { now.timeIntervalSince($0) > 600 } ?? true
        if let instance = sighting.instance, !instance.isEmpty, entry.instanceID != instance {
            entry.instanceID = instance
            persist = true
        }
        if let instance = entry.instanceID, let bundle = browserBundlesByInstance[instance],
           let name = contextEnvironment.nameForBundle(bundle), entry.label != name {
            entry.label = name
            persist = true
        }
        let refreshVisible = entry.lastSeen.map { now.timeIntervalSince($0) > 5 } ?? true
        entry.lastSeen = now
        guard persist || refreshVisible else { return }
        pairedExtensions[index] = entry
        if persist { pairingStore.save(pairedExtensions) }
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
        refreshPageContextState(now: Date())

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
            observedLegacyProtocol = true
            emailComposeUnavailableReason = Self.composeReloadMessage
        } else {
            observedLegacyProtocol = false
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
                rememberForeground(instanceID, fromApp: true)
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

    /// Every paired extension (paired_tokens.json, 0600). Migrates the single
    /// paired_token file an older build wrote.
    static var pairedListURL: URL { directory.appendingPathComponent("paired_tokens.json", isDirectory: false) }

    static func loadPairedExtensions() -> [PairedExtension] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: pairedListURL),
           let list = try? decoder.decode([PairedExtension].self, from: data) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairedListURL.path)
            return list.filter { $0.token.count >= 16 }
        }
        guard let legacy = loadPaired() else { return [] }
        let migrated = [PairedExtension(token: legacy, label: "Browser extension", instanceID: nil,
                                        pairedAt: Date(), lastSeen: nil)]
        savePairedExtensions(migrated)
        return migrated
    }

    static func savePairedExtensions(_ list: [PairedExtension]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else { return }
        // Write beside the target with 0600 from the start, then rename over it, so
        // the secrets are never world readable and a crash never leaves half a file.
        let temporary = directory.appendingPathComponent(".paired_tokens.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, pairedListURL.path) == 0 else {
            try? fm.removeItem(at: temporary)
            print("[Bridge] WARNING: couldn't persist pairings at \(pairedListURL.path); they will need pairing again next launch")
            return
        }
        // The list is now authoritative; a leftover single token file must not
        // resurrect a pairing the user removed.
        try? fm.removeItem(at: pairedFileURL)
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

/// One paired extension. The token is the secret the extension minted; label and
/// instance are learned from its traffic so Settings can say which browser it is.
struct PairedExtension: Codable, Equatable, Identifiable, Sendable {
    var token: String
    var label: String
    var instanceID: String?
    var pairedAt: Date
    var lastSeen: Date?
    var id: String { token }
    /// Last four characters, safe to show in Settings.
    var tokenSuffix: String { String(token.suffix(4)) }
}

/// Where pairings are persisted. The app uses the 0600 files; tests use memory so
/// they never touch the user's real pairing.
struct PairedExtensionStore {
    let load: () -> [PairedExtension]
    let save: ([PairedExtension]) -> Void

    static var files: PairedExtensionStore {
        PairedExtensionStore(load: BridgeToken.loadPairedExtensions, save: BridgeToken.savePairedExtensions)
    }

    static func memory(_ initial: [PairedExtension] = []) -> PairedExtensionStore {
        final class Box { var value: [PairedExtension]; init(_ value: [PairedExtension]) { self.value = value } }
        let box = Box(initial)
        return PairedExtensionStore(load: { box.value }, save: { box.value = $0 })
    }
}

// MARK: - BridgeServer
// The raw BSD-socket HTTP layer (no entitlements needed; the app is unsandboxed).
// Deliberately OUTSIDE the main actor: accept()/recv() block. It authenticates,
// reads a complete request, replies, and hands the raw bytes to the main actor —
// it never touches Holmes state itself.

private final class BridgeServer: @unchecked Sendable {

    enum StartResult {
        case success(UInt16)
        case failure(String)
    }

    private let port: UInt16
    private let token: String
    private let maxBodyBytes: Int
    /// Read directly (lock guarded) by GET /commands. No main thread involved.
    private let commandQueue: BrowserCommandQueue
    private let onPayload: @Sendable (Data) -> Void
    private let onSighting: @Sendable (BridgeSighting) -> Void
    private let onUnauthorized: @Sendable (String) -> Void
    private let onPaired: @Sendable (String) -> Void
    /// Hands off a POST /command-result body (fire-and-forget, like onPayload).
    private let onCommandResult: @Sendable (Data) -> Void

    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false
    /// The paired extensions' own secrets (one per browser). Read and written under
    /// `lock` because every connection is handled on its own queue.
    private var pairedTokens: Set<String>
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
         pairedTokens: [String],
         maxBodyBytes: Int,
         commandQueue: BrowserCommandQueue,
         onPayload: @escaping @Sendable (Data) -> Void,
         onSighting: @escaping @Sendable (BridgeSighting) -> Void,
         onUnauthorized: @escaping @Sendable (String) -> Void,
         onPaired: @escaping @Sendable (String) -> Void,
         onCommandResult: @escaping @Sendable (Data) -> Void) {
        self.port = port
        self.token = token
        self.pairedTokens = Set(pairedTokens)
        self.maxBodyBytes = maxBodyBytes
        self.commandQueue = commandQueue
        self.onPayload = onPayload
        self.onSighting = onSighting
        self.onUnauthorized = onUnauthorized
        self.onPaired = onPaired
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
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                return .failure("Port \(port) on 127.0.0.1 is already in use by another app (is another copy of Holmes running?).")
            }
            return .failure("bind() failed on 127.0.0.1:\(port) (errno \(code)).")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            return .failure("listen() failed: \(errno)")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) }
        }
        let actualPort = named == 0 ? UInt16(bigEndian: boundAddress.sin_port) : port

        lock.lock()
        serverFD = fd
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        return .success(actualPort)
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
        // accept() can fail repeatedly (EMFILE when the process is out of file
        // descriptors, ECONNABORTED storms). Retrying instantly spun a core at 100%;
        // back off exponentially up to a second and reset on the next success.
        var backoff = BridgeBackoff(base: 0.01, cap: 1)
        while isRunning {
            let fd = listeningFD
            guard fd >= 0 else { break }
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                let code = errno
                guard isRunning else { break }
                let delay = backoff.failure()
                if backoff.consecutiveFailures == 1 || backoff.consecutiveFailures % 100 == 0 {
                    print("[Bridge] accept() failed (errno \(code)); backing off \(delay)s")
                }
                usleep(UInt32(delay * 1_000_000))
                continue
            }
            backoff.success()
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
            // Non-blocking: waiting here (even 2s) ran connections through one at a
            // time, so a backlog pushed later requests past the extension's fetch
            // timeout before they ever saw a 503.
            guard slots.wait(timeout: .now()) == .success else {
                // Every handler is busy (stalled clients). Answer this one with an
                // immediate 503 and keep accepting.
                Self.refuseBusy(clientFD)
                close(clientFD)
                continue
            }
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

        guard let matchedToken = authenticatedToken(request.headers[BridgeProtocol.tokenHeaderKey], origin: origin) else {
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
            let instance = request.headers[BridgeProtocol.instanceHeaderKey]
            let focused = Self.focusedFlag(request.headers[BridgeProtocol.focusedHeaderKey])
            commandQueue.noteSeen(instance: instance, focused: focused)
            onSighting(BridgeSighting(token: matchedToken, instance: instance, focused: focused, body: request.body))
            writeJSON(fd, status: "200 OK", origin: origin, object: ["ok": true])
            return
        }

        // Browser-automation command channel — behind the SAME token gate as
        // /context (both paths are only reachable past the guard above).
        //   GET  /commands       → drain + return the queued commands as JSON.
        //   POST /command-result → hand the structured outcome to the producer.
        if request.method == "GET" && path == BridgeProtocol.commandsPath {
            // Proof of life, same as a heartbeat. The watchdog keeps the extension
            // "connected" while its worker is polling.
            let instance = request.headers[BridgeProtocol.instanceHeaderKey]
            let focused = Self.focusedFlag(request.headers[BridgeProtocol.focusedHeaderKey])
            onSighting(BridgeSighting(token: matchedToken, instance: instance, focused: focused, body: nil))
            let wait = max(0, min(Double(request.headers[BridgeProtocol.longPollHeaderKey] ?? "") ?? 0,
                                  BridgeProtocol.longPollMaxSeconds))
            let (batch, held) = commandQueue.drainDetailed(instance: instance, focused: focused, wait: wait,
                                                           clientGone: { Self.peerClosed(fd) })
            var headers = corsHeaders(origin: origin)
            headers["Content-Type"] = "application/json"
            // "1" only when this request was really held. A poll over the long poll
            // cap gets "0" so the worker waits its idle gap instead of spinning.
            headers["X-Holmes-Long-Poll"] = held ? "1" : "0"
            let body = BrowserCommandQueue.encode(batch, session: commandQueue.session)
            // The extension hung up while we waited: hand the commands to the next
            // poll instead of losing them in a dead socket.
            if !write(fd, status: "200 OK", headers: headers, body: body) {
                commandQueue.requeue(batch.map(\.id))
            }
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
    /// Returns the secret that authenticated the request (the issued token or one
    /// of the paired ones), or nil. Every comparison is constant-time.
    private func authenticatedToken(_ provided: String?, origin: String?) -> String? {
        guard let provided else { return nil }
        let candidate = provided.trimmingCharacters(in: .whitespaces)
        if constantTimeEqual(candidate, token) { return token }

        lock.lock()
        let known = pairedTokens
        let pairingOpen = (pairingWindowEnds.map { $0 > Date() }) ?? false
        lock.unlock()

        // Compare against every paired token without an early exit.
        var matched: String?
        for secret in known where constantTimeEqual(candidate, secret) { matched = secret }
        if let matched { return matched }

        // Unknown secret, and the user hasn't armed pairing: reject. Adopting on
        // first contact meant any local process, or any page that could clear the
        // preflight, could claim the bridge and feed .exact context straight into
        // an agent that holds tool access.
        guard pairingOpen else { return nil }

        // Shape check, so a stray probe with an empty or junk header can't consume
        // the armed window.
        guard (16...256).contains(candidate.count),
              candidate.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
        else { return nil }

        // Even inside the window only a browser EXTENSION may pair. An http(s)
        // Origin is page JavaScript, and no Origin at all is a native process:
        // any app on this Mac could otherwise claim the window the user opened
        // for their browser. Native tools use the issued token instead.
        guard Self.mayPair(origin: origin) else {
            print("[Bridge] Refused to pair with origin \(origin ?? "none") — only extension origins may pair")
            return nil
        }

        lock.lock()
        // Re-check under the lock: two concurrent requests must not both pair.
        guard (pairingWindowEnds.map { $0 > Date() }) ?? false else {
            let raced = pairedTokens.first { constantTimeEqual(candidate, $0) }
            lock.unlock()
            return raced
        }
        pairedTokens.insert(candidate)
        pairingWindowEnds = nil   // one-shot: the window closes the moment it is used
        lock.unlock()

        onPaired(candidate)
        return candidate
    }

    /// Opens the user-armed adoption window (called from Settings). Existing
    /// pairings stay valid.
    func openPairingWindow(until deadline: Date) {
        lock.lock()
        pairingWindowEnds = deadline
        lock.unlock()
    }

    /// Replaces the accepted paired tokens (after Settings removed one).
    func setPairedTokens(_ tokens: [String]) {
        lock.lock()
        pairedTokens = Set(tokens)
        lock.unlock()
    }

    /// Closes it — on cancel, on expiry, or after a successful pairing.
    func closePairingWindow() {
        lock.lock()
        pairingWindowEnds = nil
        lock.unlock()
    }

    /// Origins allowed to pair: browser extension origins only. Chrome, Comet, Arc,
    /// Brave, Edge and other Chromium browsers all post from chrome-extension://.
    /// No Origin is a native process, a site origin is page JavaScript, and "null"
    /// is an opaque browser origin (sandboxed iframe, file://); none may pair.
    static func mayPair(origin: String?) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces),
              !origin.isEmpty else { return false }
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

        // Command results may be large (screenshots, extracts); page context may not.
        let bareRequestPath = path.components(separatedBy: "?").first ?? path
        let limit = (method == "POST" && bareRequestPath == BridgeProtocol.commandResultPath)
            ? BridgeProtocol.maxCommandResultBytes : maxBodyBytes
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0 else { return nil }
        guard contentLength <= limit else {
            // Drain first (bounded by size and the request deadline). Replying 413
            // and closing with unread bytes makes the kernel reset the connection,
            // which the extension saw as a network error and surfaced as a timeout.
            let alreadyRead = buffer.count - buffer.distance(from: buffer.startIndex, to: end.upperBound)
            var remaining = contentLength - alreadyRead
            if contentLength <= BridgeProtocol.maxDrainBytes {
                while remaining > 0, Date() < deadline {
                    let n = recv(fd, &chunk, min(chunk.count, remaining), 0)
                    if n <= 0 { break }
                    remaining -= n
                }
            }
            writeJSON(fd, status: "413 Payload Too Large", origin: headers["origin"],
                      object: ["error": "Body exceeds \(limit) bytes", "limit": limit, "received": contentLength])
            return nil
        }

        // 2 — read the body until Content-Length is satisfied. A stall or a close
        // before that point yields a truncated payload, which is not a request:
        // drop the connection rather than handing half a DOM to the parser.
        var body = Data(buffer[end.upperBound...])
        body.reserveCapacity(contentLength)
        while body.count < contentLength {
            guard Date() < deadline else { return nil }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            body.append(contentsOf: chunk[0..<n])
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

    /// True when every byte was handed to the kernel and the peer had not already
    /// hung up. A long poll uses this to requeue commands it could not deliver.
    @discardableResult
    private func write(_ fd: Int32, status: String, headers: [String: String], body: Data) -> Bool {
        var head = "HTTP/1.1 \(status)\r\n"
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"

        if Self.peerClosed(fd) { return false }
        var out = Data(head.utf8)
        out.append(body)
        return out.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var sent = 0
            while sent < out.count {
                let n = send(fd, base + sent, out.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// The worker's "one of my windows has OS focus" header, or nil when absent.
    static func focusedFlag(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        return value == "1" || value == "true"
    }

    /// Minimal 503 for a connection that arrived while every handler was busy.
    static func refuseBusy(_ fd: Int32) {
        let reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 1\r\n\r\n"
        _ = reply.withCString { send(fd, $0, strlen($0), 0) }
    }

    /// Non-blocking check for a client that already closed its end. A readable
    /// socket that yields zero bytes on a peek is an orderly shutdown.
    static func peerClosed(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 0)
        guard ready > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked == 0 { return true }
        if peeked < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }
        return false
    }
}
