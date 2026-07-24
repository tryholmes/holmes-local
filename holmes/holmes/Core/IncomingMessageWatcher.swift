import Foundation
import AppKit
import CryptoKit
import Observation

// MARK: - IncomingMessageWatcher
// The automatic trigger. Everything else in the reply path — topic extraction,
// memory recall, the grounded draft, the REFERENCED NOW section — is downstream
// of one question: DID SOMEONE JUST ASK THE USER SOMETHING? This file answers
// it without the user doing anything at all. That is the whole point: by the
// time they open Holmes, the draft and the memories it came from are already
// there.
//
// Three surfaces, one funnel:
//
//   1. iMessage — MessagesReader's Accessibility read of the displayed thread,
//      taken whenever Messages is RUNNING, not only when it is frontmost. The
//      read does not require frontmost (MessagesReader builds its element from
//      the pid), and requiring it would have cost the feature its trigger: the
//      user in this product's core scenario is coding in a browser when the
//      text lands. What is gated instead is the CADENCE — every 1.5s while the
//      user is in Messages, every 4.5s while it is merely open behind something
//      else, nothing at all when Messages is not running.
//
//   2. Web chats (WhatsApp Web, Slack, Discord, Messenger, …) — read off the
//      LiveContext stream the browser extension already feeds through
//      BrowserBridge. No second socket, no second listener: BrowserBridge's
//      single `onLiveContext` callback belongs to HolmesAgent, so this class
//      takes contexts the same way TriggerBrain does — a push from the tier-0
//      path via `noteLiveContext`, plus a poll of `BrowserBridge.lastLiveContext`
//      on the shared timer so the watcher still works if nothing pushes.
//
//   3. Email — a newly-opened message in the Gmail/Outlook/Proton adapter
//      payload, or in Mail.app's Accessibility reading. Surfaced as "email".
//
// MARK: - Correctness rules, all enforced in code below
//   • NEVER fire for something the USER sent. Every surface has an explicit
//     from-me test, and an unattributable speaker is treated as from-me (i.e.
//     dropped) rather than guessed at.
//   • Dedupe is THREAD-SCOPED and evicted as one unit — see `ThreadLedger`.
//   • At most one fire per thread per 10 seconds.
//   • A message must plausibly WARRANT a reply — see `warrantsReply`. "ok",
//     "thanks" and a 👍 tapback are not questions and must never produce a draft.
//   • What was ALREADY ON SCREEN when Holmes started looking is history, not an
//     event. The unit of that rule is the visible TRANSCRIPT, not the thread —
//     see `observeTranscript` for why the distinction is the whole feature.
//
// MARK: - DRAFT-NEVER-SEND
// This file detects. It does not draft, and it certainly does not send: it
// hands a normalized ReplyComposer.IncomingMessage to `onIncoming` and stops.
// Nothing here touches ActionExecutor, synthesizes a keystroke, or posts to a
// messaging service. The user's explicit tap remains the only thing that can
// commit a reply.

@Observable
@MainActor
final class IncomingMessageWatcher {
    static let shared = IncomingMessageWatcher()
    private init() {}

    // MARK: - Published state

    /// The most recent inbound message Holmes decided was worth answering.
    /// Settable so a consumer can clear it once its draft has been dismissed.
    var lastDetected: ReplyComposer.IncomingMessage?

    /// True between `start()` and `stop()`. Owned by those two methods — the
    /// timer's existence and this flag must never disagree, which is why it is
    /// read-only from outside.
    private(set) var isWatching = false

    /// Total fires this session. Purely for the Settings/debug surface; it
    /// makes "the watcher is running but has never fired" visible instead of
    /// something the user has to infer.
    private(set) var detectionCount = 0

    // MARK: - Callback

    /// Called on the main actor for every message that clears every gate.
    /// @ObservationIgnored because a closure is not renderable state, and
    /// assigning one must not invalidate a view.
    @ObservationIgnored var onIncoming: ((ReplyComposer.IncomingMessage) -> Void)?

    // MARK: - Tuning

    /// Base tick, and the iMessage read cadence while the user is IN Messages.
    /// Fast enough that a reply is waiting before the user has finished reading
    /// the message themselves.
    private static let pollInterval: TimeInterval = 1.5

    /// iMessage read cadence while Messages is running but backgrounded. Three
    /// ticks apart, so the AX walk costs a third of what a foreground read does
    /// while the user is off doing something else — and a message still becomes
    /// a draft within seconds of landing, with the user touching nothing.
    private static let backgroundPollInterval: TimeInterval = 4.5

    /// One draft per conversation per this many seconds. A person who fires off
    /// four lines in a row is asking ONE thing.
    private static let perThreadDebounce: TimeInterval = 10

    /// Hard cap on tracked threads. An always-on agent must not accumulate
    /// state for the life of the process.
    private static let threadCap = 200

    /// Lines remembered per thread. Comfortably more than any surface renders
    /// at once (MessagesReader caps its transcript at 15), so a baseline is
    /// never partially forgotten while its thread is still live.
    private static let digestsPerThread = 60

    /// Anything observed within this long after `start()` is treated as history
    /// that was already on screen, not as an arriving message.
    ///
    /// Sized against the SLOWEST producer, not against a hunch: ScreenEngine's
    /// timer is 3s plus OCR/AX latency and the browser extension's heartbeat is
    /// 5s, so a 3s grace expired before the first reading of an already-open
    /// screen had even arrived — and that reading then looked like an event.
    private static let startupGrace: TimeInterval = 12

    /// Distinct LiveContext readings an email thread must appear in before it
    /// may fire. See `noteLiveContext` for why one is not enough.
    private static let emailObservationsBeforeFiring = 2

    /// Cap on the text handed to the composer. An email body can be enormous;
    /// the question being asked is always near the top.
    private static let maxIncomingCharacters = 2000

    // MARK: - State
    // All @ObservationIgnored: none of it is rendered, and mutating it on every
    // tick must never invalidate a view.

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt: Date = .distantPast
    /// Per-thread baselines, seen-line digests and observation counts.
    @ObservationIgnored private var ledger = ThreadLedger(
        threadCap: IncomingMessageWatcher.threadCap,
        digestsPerThread: IncomingMessageWatcher.digestsPerThread)
    /// Last fire time per thread, for the debounce.
    @ObservationIgnored private var lastFireAt: [String: Date] = [:]
    /// Capture time of the newest LiveContext already examined — the push path
    /// and the poll path both land in `noteLiveContext`, and one screen must
    /// only be considered once.
    @ObservationIgnored private var lastContextAt: Date = .distantPast
    /// When the Messages transcript was last actually read, for the adaptive
    /// cadence. The timer ticks at `pollInterval`; this decides which ticks do
    /// the expensive part.
    @ObservationIgnored private var lastMessagesReadAt: Date = .distantPast

    // MARK: - Lifecycle

    /// Begins watching. Idempotent: a second call while already running is a
    /// no-op rather than a second timer.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        startedAt = Date()

        // A fresh session starts with a clean slate: the dedupe state describes
        // "what has arrived since we started looking", and stale entries would
        // suppress a real message after a stop/start cycle.
        ledger.removeAll()
        lastFireAt.removeAll()
        lastContextAt = .distantPast
        lastMessagesReadAt = .distantPast

        // [weak self] so the run loop's strong reference to the timer can never
        // become a strong reference to this object. The Task hop is a single
        // main-actor turn — it cannot outlive the object, and it does no work
        // if `self` is gone.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = Self.pollInterval / 4   // let the OS coalesce our wakeups
        self.timer = timer

        print("[Holmes] IncomingMessageWatcher: watching — iMessage every \(Self.pollInterval)s in the foreground / \(Self.backgroundPollInterval)s in the background, web chat + email off the live context stream")
    }

    /// Stops watching and tears the timer down. The invalidate MUST happen
    /// here: an un-invalidated repeating timer keeps firing on the main run
    /// loop for the life of the process.
    func stop() {
        timer?.invalidate()
        timer = nil
        guard isWatching else { return }
        isWatching = false
        print("[Holmes] IncomingMessageWatcher: stopped")
    }

    // MARK: - Tick

    private func tick() {
        guard isWatching else { return }
        pollMessagesApp()
        pollBrowserContext()
    }

    // MARK: - Surface 1 — iMessage (Accessibility)

    /// Reads the transcript Messages is displaying.
    ///
    /// TWO cheap gates in front of the expensive one, in cost order:
    ///   1. is Messages running at all — one NSWorkspace array scan. When it
    ///      isn't, there is no window, no transcript and nothing to do.
    ///   2. is this tick due — the AX walk runs at 1.5s while the user is in
    ///      Messages and at 4.5s while it is behind another app. A read of a
    ///      backgrounded app is still a real read (see MessagesReader), so a
    ///      text that lands while the user is coding becomes a waiting draft
    ///      without them touching anything; it just costs a third as much.
    /// The walk itself is bounded by MessagesReader's own maxDepth/maxChildren
    /// limits, which is what keeps the background cadence affordable.
    private func pollMessagesApp() {
        guard MessagesReader.shared.isChatAppRunning() else { return }

        let cadence = MessagesReader.shared.isChatAppFrontmost()
            ? Self.pollInterval
            : Self.backgroundPollInterval
        let now = Date()
        // A third of a tick of slack, so timer jitter can't push a 4.5s cadence
        // out to 6s by missing its window by milliseconds.
        guard now.timeIntervalSince(lastMessagesReadAt) >= cadence - Self.pollInterval / 3 else { return }
        lastMessagesReadAt = now

        guard let thread = MessagesReader.shared.readFrontmostThread(),
              !thread.messages.isEmpty
        else { return }

        let contact = thread.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        // The window titles the thread with the conversation name; when it can't
        // (an unnamed group / a static app title), one stable placeholder keeps
        // dedupe working rather than making every read look like a new thread.
        // Namespaced by app so two chat apps can't collide on an empty title.
        let threadID = thread.app.lowercased() + "#" + (contact.isEmpty ? "frontmost-thread" : contact)

        observeTranscript(TranscriptReading(
            surface: ReplyComposer.surfaceIMessage,
            threadID: threadID,
            app: thread.app,
            // The conversation name is the best sender label the app exposes;
            // per-bubble attribution inside a group chat is deliberately not
            // attempted (see MessagesReader).
            fallbackSender: contact.isEmpty ? "them" : contact,
            firstSightingMayFire: true,
            bubbles: thread.messages.map {
                // isFromMe comes from bubble alignment — the only from-me signal
                // the AX tree carries — and is trusted verbatim.
                Bubble(speaker: $0.sender, text: $0.text, isFromMe: $0.isFromMe)
            }))
    }

    // MARK: - Surface 2/3 — the LiveContext stream

    /// Polls the bridge's last published context. This is a READ of the stream
    /// HolmesAgent already owns, not a second listener: BrowserBridge holds a
    /// single `onLiveContext` closure, and stealing it would silence the
    /// perception loop.
    private func pollBrowserContext() {
        guard let context = BrowserBridge.shared.lastLiveContext else { return }
        noteLiveContext(context)
    }

    /// The push path, mirroring TriggerBrain.noteLiveContext: HolmesAgent's
    /// tier-0 handler can hand every reading straight here for zero-latency
    /// detection, including the Accessibility readings (Mail.app) that never go
    /// near the browser bridge. Safe to call on every tick — a context that has
    /// already been examined is dropped on its capture time.
    func noteLiveContext(_ context: LiveContext) {
        guard isWatching else { return }
        // A reading CAPTURED before Holmes started watching describes a screen
        // that was already there. Measuring the reading itself, rather than the
        // wall clock since start(), is what makes the startup rule immune to a
        // slow producer: BrowserBridge replays its last payload, and that
        // payload can be older than this watcher.
        guard context.capturedAt >= startedAt else { return }
        guard context.capturedAt > lastContextAt else { return }
        lastContextAt = context.capturedAt

        // A guess must never stage a draft. OCR-derived context is garbled by
        // definition, and "someone asked you X" built out of misread pixels is
        // the worst possible thing to put in front of a user.
        guard context.confidence != .inferred else { return }

        if let chat = webChatReading(in: context) {
            observeTranscript(chat)
            return
        }
        if let mail = emailCandidate(in: context) {
            noteEmail(mail)
        }
    }

    // MARK: - Candidate extraction — web chat

    /// Pulls a chat page's visible transcript out of its context, or nil.
    ///
    /// The extension's chat adapters render the transcript as "Speaker: text",
    /// one message per line, into `detail` (and `bodyText`). That format is the
    /// contract this parser reads — see `attributedLines`.
    private func webChatReading(in context: LiveContext) -> TranscriptReading? {
        // Only the extension's literal DOM read. An Accessibility reading of a
        // chat web page is a flattened text dump with no speaker attribution,
        // and attributing it would be guessing at who said what.
        guard context.source == .browserExtension, context.confidence == .exact else { return nil }

        let surface = context.entities["surface"] ?? ""
        // An assistant's reply is not an inbound message from a person.
        guard surface != ContextSurface.aiChat.rawValue else { return nil }
        guard surface == ContextSurface.directMessage.rawValue
                || surface == ContextSurface.teamChannel.rawValue
                || context.activity == "chatting"
        else { return nil }

        // The user is already writing their own reply. They don't need Holmes
        // to start one, and racing their words would be worse than useless.
        guard context.activity != "composing", context.entities["draft"] == nil else { return nil }
        guard context.focusedField?.isComposing != true else { return nil }

        let transcript = context.detail.isEmpty ? context.bodyText : context.detail
        let lines = Self.attributedLines(in: transcript)
        guard let last = lines.last else { return nil }

        // THE from-me GATE for web chats, and the one place where a wrong answer
        // means Holmes drafts a reply to the USER'S OWN words.
        //
        // `lastFromMe` is DOM ground truth published by the adapter: WhatsApp's
        // `message-out` class, or the signed-in account name Slack/Discord/
        // Messenger render in their own chrome. It is authoritative because a
        // speaker LABEL is not: every one of those services labels the user's
        // own messages with their service display name, which is almost never
        // the macOS account name that `isSelf` can check.
        //
        // So: when the marker says the last line is the user's, stop. When a
        // surface whose adapter publishes the marker did not publish it this
        // time, the adapter could not tell who wrote that line — fail CLOSED
        // rather than fall back to a test that is known not to work there.
        let marker = (context.entities[Self.fromMeEntityKey] ?? "").lowercased()
        if marker.isEmpty {
            guard !Self.publishesFromMeMarker(site: context.site) else { return nil }
        } else {
            guard marker == "no" else { return nil }
        }
        guard !isSelf(speaker: last.speaker) else { return nil }

        // The room, for the thread key: whichever name this adapter published.
        let room = context.entities["chat"]
            ?? context.entities["contact"]
            ?? context.entities["correspondent"]
            ?? context.entities["channel"]
            ?? context.entities["server"]
            ?? context.title
        let threadID = [context.site ?? context.app, room]
            .filter { !$0.isEmpty }
            .joined(separator: "#")

        return TranscriptReading(
            surface: ReplyComposer.surfaceWebChat,
            threadID: threadID.isEmpty ? "web-chat" : threadID,
            app: context.app,
            fallbackSender: last.speaker,
            // A DM's last line is addressed to the user, so a thread that
            // appears mid-session is a conversation they just opened — usually
            // because something arrived in it. A CHANNEL's last line is
            // addressed to the room, so opening #general must never draft a
            // reply to whatever was said in it last.
            firstSightingMayFire: surface == ContextSurface.directMessage.rawValue,
            bubbles: lines.map {
                // Per-line attribution is not available from a flattened
                // transcript, so only the LAST line's authorship is known (from
                // the marker above). Earlier lines exist to be baselined, and a
                // baseline does not care who wrote what.
                Bubble(speaker: $0.speaker, text: $0.text, isFromMe: false)
            })
    }

    // MARK: - Candidate extraction — email

    /// A message the user has open in a mail client. Accepts both the exact
    /// browser reading and Mail.app's structural Accessibility reading, since a
    /// coarse-but-real "from + subject + body" is still a real question — the
    /// composer records the confidence tier and hedges accordingly.
    private func emailCandidate(in context: LiveContext) -> Candidate? {
        guard (context.entities["surface"] ?? "") == ContextSurface.emailRead.rawValue else { return nil }

        let sender = (context.entities["sender"] ?? context.entities["senderEmail"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !isSelf(speaker: sender) else { return nil }
        // Newsletters, receipts and CI notifications are not correspondence.
        // Drafting a reply to a robot is pure noise, and the robot's "questions"
        // ("Did you know…?") sail straight through the reply-worthy predicate.
        guard !Self.isAutomatedSender(sender) else { return nil }

        let subject = (context.entities["subject"] ?? context.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (context.bodyText.isEmpty ? context.detail : context.bodyText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.isEmpty ? subject : body
        guard !text.isEmpty else { return nil }

        // The URL identifies a Gmail thread exactly; Mail.app has none, so the
        // sender+subject pair stands in for it.
        let threadID = context.url ?? "\(sender)|\(subject)"

        return Candidate(surface: ReplyComposer.surfaceEmail,
                         threadID: threadID,
                         sender: sender,
                         text: text,
                         app: context.app)
    }

    /// The email arrival rule. An open message has no transcript to diff, so
    /// "did this arrive?" becomes "did the user navigate to it while Holmes was
    /// watching?", and that takes two facts rather than one:
    ///
    ///   • a thread first seen during the startup grace was ALREADY OPEN when
    ///     Holmes started. It is baselined and can never fire — otherwise the
    ///     mail the user read an hour ago becomes a draft the moment Holmes
    ///     launches, or the moment anything cycles stop()/start().
    ///   • a thread first seen afterwards must be seen in TWO distinct readings
    ///     before it fires. One reading proves nothing — a first reading can
    ///     describe a screen that has been sitting there — while a second means
    ///     the message was still open across two independent captures, i.e. the
    ///     user is actually reading it now.
    private func noteEmail(_ candidate: Candidate) {
        let key = Self.threadKey(surface: candidate.surface, threadID: candidate.threadID)
        let observations = ledger.observe(key)

        // Already open when Holmes started looking → history, permanently.
        if observations == 1, Date().timeIntervalSince(startedAt) < Self.startupGrace {
            ledger.baseline(key, digests: [Self.digest(of: candidate.text)])
            return
        }
        guard !ledger.isBaselined(key) else { return }
        guard observations >= Self.emailObservationsBeforeFiring else { return }
        consider(candidate)
    }

    // MARK: - The funnel

    /// One rendered line of a conversation, normalized across surfaces.
    private struct Bubble {
        let speaker: String
        let text: String
        let isFromMe: Bool
    }

    /// One reading of a conversation surface: the whole visible transcript,
    /// plus the identity of the thread it belongs to.
    private struct TranscriptReading {
        let surface: String
        let threadID: String
        let app: String
        /// Used when a line carries no speaker of its own.
        let fallbackSender: String
        /// May the FIRST sighting of this thread fire? See `observeTranscript`.
        let firstSightingMayFire: Bool
        let bubbles: [Bubble]
    }

    /// One normalized inbound message, before any of the gates have run.
    private struct Candidate {
        let surface: String
        let threadID: String
        let sender: String
        let text: String
        let app: String
    }

    /// What happened to a candidate. `deferred` is the one that matters: a
    /// message held back by the debounce is still UNANSWERED, so the caller
    /// must not mark it as dealt with.
    private enum Outcome {
        case fired
        case ignored
        case deferred
    }

    // MARK: - The transcript rule

    /// THE arrival rule for conversation surfaces: a message is an arrival when
    /// it was APPENDED to a transcript Holmes has already seen.
    ///
    /// Why the unit is the transcript and not the thread. The old rule — "the
    /// first sighting of a thread is history" — swallowed the exact message
    /// this feature exists for. A text lands while the user is in their browser;
    /// they switch to Messages to read it; that switch is the thread's first
    /// sighting, so the message that CAUSED it was recorded as history and could
    /// never fire again. Baselining what is literally on screen fixes that: the
    /// bubbles that were there are history, and anything appended after them is
    /// an event, which is what the words actually mean.
    ///
    /// The three shapes a reading can take:
    ///
    ///   1. NEVER SEEN THIS THREAD. Record every visible line. It may then fire
    ///      on its last line — but only when `firstSightingMayFire` and only
    ///      after the startup grace, i.e. the thread appeared while Holmes was
    ///      watching, which for a one-to-one conversation means the user just
    ///      opened it and the reason people open a conversation is that
    ///      something arrived in it. Stated honestly, the cost of that rule is
    ///      the mirror case: opening an old DM whose last line is an unanswered
    ///      question does produce a draft. That draft is dismissible; the
    ///      alternative was missing every message that arrives while Messages
    ///      is not the thread on screen.
    ///
    ///   2. THE ANCHOR IS STILL THERE. The last line seen previously is still
    ///      in the transcript, so everything after it was appended — a genuine
    ///      arrival. Nothing after it? Nothing happened.
    ///
    ///   3. THE ANCHOR IS GONE. The pane scrolled, the conversation switched, or
    ///      the view re-rendered from a different point. What is on screen is
    ///      not an append and must not be treated as one: re-baseline in silence.
    ///      This is also what stops a scroll into old history from drafting a
    ///      reply to a question from last week.
    private func observeTranscript(_ reading: TranscriptReading) {
        let key = Self.threadKey(surface: reading.surface, threadID: reading.threadID)
        let bubbles = reading.bubbles.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !bubbles.isEmpty else { return }
        let digests = bubbles.map { Self.digest(of: $0.text) }

        // 1 — First sighting. The gates run BEFORE the baseline is written, so
        //     the one line that may be an arrival is judged on its merits rather
        //     than recorded as history and suppressed forever — which is exactly
        //     what the old thread-level rule did to it.
        guard ledger.isBaselined(key) else {
            let last = bubbles[bubbles.count - 1]
            let duringStartup = Date().timeIntervalSince(startedAt) < Self.startupGrace
            guard reading.firstSightingMayFire, !duringStartup, !last.isFromMe else {
                ledger.baseline(key, digests: digests)
                return
            }
            // A deferral leaves the thread UNBASELINED on purpose: the message
            // is still unanswered, and the next reading has to reach it again.
            guard consider(candidate(for: last, in: reading)) != .deferred else { return }
            ledger.baseline(key, digests: digests)
            return
        }

        // 2/3 — Anchor. `lastIndex` rather than `firstIndex`: when a line is
        //       repeated verbatim, the NEWEST occurrence is the conservative
        //       anchor — it can only ever suppress a fire, never invent one.
        let anchor = ledger.lastDigest(of: key)
        guard let index = digests.lastIndex(of: anchor) else {
            ledger.baseline(key, digests: digests)
            return
        }
        guard index < digests.count - 1 else { return }

        let arrivals = Array(bubbles[(index + 1)...])
        var outcome = Outcome.ignored
        // Only the NEWEST appended line is a candidate: four lines in a row are
        // one question and it is the last of them, and if the user has already
        // answered — the newest line is theirs — the conversation has moved on
        // and a draft would be noise.
        if let newest = arrivals.last, !newest.isFromMe {
            outcome = consider(candidate(for: newest, in: reading))
        }
        // The anchor advances only over lines that have been DEALT WITH. A line
        // the debounce held back is still unanswered, and moving the anchor past
        // it would swallow it exactly the way the old thread-level baseline did.
        guard outcome != .deferred else { return }
        ledger.record(key, digests: Array(digests[(index + 1)...]))
    }

    private func candidate(for bubble: Bubble, in reading: TranscriptReading) -> Candidate {
        let speaker = bubble.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        return Candidate(surface: reading.surface,
                         threadID: reading.threadID,
                         sender: speaker.isEmpty ? reading.fallbackSender : speaker,
                         text: bubble.text,
                         app: reading.app)
    }

    /// The remaining gates, in the order that costs the least to fail.
    @discardableResult
    private func consider(_ candidate: Candidate) -> Outcome {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored }

        let threadKey = Self.threadKey(surface: candidate.surface, threadID: candidate.threadID)
        let digest = Self.digest(of: text)

        // 1 — Seen this exact line on this exact thread before. Covers both
        //     "already fired" and "already baselined away".
        guard !ledger.hasSeen(threadKey, digest: digest) else { return .ignored }

        // 2 — Blanket startup guard. Every surface has its own, more precise
        //     rule above; this one is the floor none of them can fall through.
        guard Date().timeIntervalSince(startedAt) >= Self.startupGrace else {
            ledger.record(threadKey, digests: [digest])
            return .ignored
        }

        // 3 — Does it actually want an answer? Recorded as seen either way: a
        //     "thanks" that didn't qualify must not be re-tested on every tick
        //     for as long as it stays on screen.
        guard Self.warrantsReply(text) else {
            ledger.record(threadKey, digests: [digest])
            return .ignored
        }

        // 4 — Debounce. Deliberately NOT recorded as seen: a message suppressed
        //     because its thread just fired is still unanswered, and becomes
        //     eligible again once the window passes.
        if let previous = lastFireAt[threadKey],
           Date().timeIntervalSince(previous) < Self.perThreadDebounce { return .deferred }

        ledger.record(threadKey, digests: [digest])
        noteFire(threadKey)

        let message = ReplyComposer.IncomingMessage(
            surface: candidate.surface,
            sender: candidate.sender,
            text: String(text.prefix(Self.maxIncomingCharacters)),
            threadID: candidate.threadID,
            app: candidate.app)

        lastDetected = message
        detectionCount += 1
        print("[Holmes] IncomingMessageWatcher: \(candidate.surface) from \(candidate.sender) — \"\(String(text.prefix(80)))\"")

        // Detection ends here. What happens next — topic extraction, recall,
        // a grounded draft — is the caller's business, and none of it sends.
        onIncoming?(message)
        return .fired
    }

    /// Records a fire and keeps the debounce table bounded. Recent entries win
    /// when it has to be trimmed: an old timestamp can only ever permit a fire
    /// that would have been permitted anyway.
    private func noteFire(_ threadKey: String) {
        lastFireAt[threadKey] = Date()
        guard lastFireAt.count > Self.threadCap else { return }
        let newest = lastFireAt.sorted { $0.value > $1.value }.prefix(Self.threadCap / 2)
        lastFireAt = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// Surface + thread, lowercased. One key shape everywhere, so the ledger,
    /// the debounce table and the logs can never describe different threads.
    private static func threadKey(surface: String, threadID: String) -> String {
        surface + "|" + threadID.lowercased()
    }

    // MARK: - The reply-worthy predicate

    /// DOES THIS MESSAGE WANT AN ANSWER? Deterministic, documented, and cheap —
    /// no model is asked, because a model asked "should I reply to 'ok'?" will
    /// eventually say yes and the user will find a draft reply to the word "ok".
    ///
    /// The rules, in order:
    ///   1. Strip to letters, digits and spaces. What's left of a pure tapback
    ///      ("👍", "❤️", "!!!") is nothing, and nothing is not a question.
    ///   2. A short message made ENTIRELY of acknowledgement words is a
    ///      reaction — "ok", "thanks", "got it", "sounds good". Never a draft.
    ///      Capped at three words so a real sentence that happens to open with
    ///      "ok" isn't swept up.
    ///   3. A question mark anywhere is decisive.
    ///   4. An interrogative word anywhere ("what", "how", "when") — texting
    ///      drops the question mark constantly ("what is holmes").
    ///   5. A request phrase ("can you", "let me know", "any update").
    ///   6. A direct address: a vocative opener with a real sentence after it
    ///      ("hey are you around" is caught by 4/5; "hey quick one for you"
    ///      is caught here).
    /// Anything else is a statement, and a statement does not need a draft.
    static func warrantsReply(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 8000 else { return false }

        // 1 — normalize: lowercase, drop everything that isn't a letter, digit
        //     or space (emoji, punctuation, apostrophes), squash whitespace.
        let stripped = String(text.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber || character.isWhitespace) ? character : " "
        })
        let words = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }

        // 2 — pure acknowledgement / reaction.
        if words.count <= 3, words.allSatisfy({ acknowledgementWords.contains($0) }) { return false }

        // 3 — an explicit question.
        if text.contains("?") { return true }

        // 4 — an interrogative anywhere in the sentence.
        if words.contains(where: { interrogativeWords.contains($0) }) { return true }

        // 5 — a request, phrased as a statement.
        let normalized = words.joined(separator: " ")
        if requestPhrases.contains(where: { normalized.contains($0) }) { return true }

        // 6 — a direct address with substance behind it.
        if let opener = words.first, vocativeOpeners.contains(opener), words.count >= 3 { return true }

        return false
    }

    /// Words that, on their own, make a message a reaction rather than a question.
    private static let acknowledgementWords: Set<String> = [
        "ok", "okay", "okey", "k", "kk", "kay", "oki", "aight", "alright",
        "thanks", "thank", "thanku", "thankyou", "thx", "tx", "ty", "tysm",
        "cool", "nice", "great", "perfect", "awesome", "sweet", "love", "lovely",
        "word", "bet", "sure", "yep", "yup", "yeah", "ya", "yes", "yah",
        "no", "nope", "nah", "np", "nvm", "same", "true", "facts", "fair",
        "haha", "hahaha", "hehe", "lol", "lmao", "lmfao", "rofl",
        "done", "got", "it", "gotcha", "gotchu", "sounds", "good", "sg",
        "fine", "right", "exactly", "agreed", "understood", "noted", "roger",
        "you", "u", "so", "much", "man", "dude", "bro", "friend", "mate",
        "congrats", "congratulations", "nice1", "amazing", "beautiful"
    ]

    /// Interrogatives, including the apostrophe-stripped forms ("what's" →
    /// "whats") the normalizer produces.
    private static let interrogativeWords: Set<String> = [
        "what", "whats", "whatre", "whatd", "who", "whos", "whose", "whom",
        "why", "how", "hows", "howd", "when", "whens", "where", "wheres",
        "which", "wdyt", "wyd", "hbu", "wut", "wat", "whatcha"
    ]

    /// Requests and prompts for information that carry no interrogative word.
    private static let requestPhrases: [String] = [
        "can you", "could you", "would you", "will you", "can u", "could u",
        "do you", "did you", "are you", "have you", "should i", "should we",
        "let me know", "lmk", "ping me", "hit me back", "get back to me",
        "tell me", "send me", "show me", "remind me", "fill me in",
        "catch me up", "explain", "curious about", "curious what",
        "wondering if", "wondering what", "wondering how",
        "any update", "any news", "any chance", "any idea", "any thoughts",
        "thoughts on", "what do you think", "need your", "i need", "we need",
        "help me", "looking for", "trying to figure", "not sure what"
    ]

    /// Greetings that open a direct address.
    private static let vocativeOpeners: Set<String> = [
        "hey", "hi", "hello", "yo", "sup", "hiya", "howdy", "heya",
        "morning", "afternoon", "evening", "gm", "ge"
    ]

    // MARK: - Sender identity

    /// The entity key a chat adapter publishes DOM ground truth under: "was the
    /// last line in this transcript written by the user?" — "yes" or "no".
    private static let fromMeEntityKey = "lastFromMe"

    /// Sites whose adapter is known to answer `lastFromMe`. Missing it on one of
    /// these means the adapter could not tell, which is a reason to stop, not a
    /// reason to fall back to a weaker test — see `webChatReading`.
    private static func publishesFromMeMarker(site: String?) -> Bool {
        let host = (site ?? "").lowercased()
        guard !host.isEmpty else { return false }
        return fromMeMarkerHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let fromMeMarkerHosts: Set<String> = [
        "web.whatsapp.com", "whatsapp.com",
        "app.slack.com", "slack.com",
        "discord.com",
        "messenger.com",
        "linkedin.com"
    ]

    /// Is this speaker the user themself?
    ///
    /// Conservative by construction: an unknown or empty speaker returns TRUE,
    /// i.e. it is treated as the user's own message and dropped. Firing a draft
    /// at the user's own words is a much worse failure than missing one.
    ///
    /// The LAST line of defence, not the first: the macOS account name is the
    /// only self-identifier Holmes holds without asking for one, and Slack,
    /// Discord and WhatsApp all label the user with a service display name that
    /// has nothing to do with it. The authoritative signal for those surfaces is
    /// the `lastFromMe` marker their adapters read out of the DOM.
    private func isSelf(speaker: String) -> Bool {
        let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return true }
        if Self.selfLabels.contains(name) { return true }

        let account = NSUserName().lowercased()
        if !account.isEmpty, name == account { return true }

        let fullName = NSFullUserName().lowercased()
        if !fullName.isEmpty, name == fullName { return true }
        if let firstName = fullName.split(separator: " ").first.map(String.init),
           firstName.count >= 3, name == firstName { return true }

        return false
    }

    /// Speaker labels the adapters use for the user's own messages.
    private static let selfLabels: Set<String> = [
        "me", "you", "i", "myself", "self", "my", "sent", "outgoing"
    ]

    /// Mailbox names that belong to a machine rather than a person.
    private static func isAutomatedSender(_ sender: String) -> Bool {
        let lower = sender.lowercased()
        return automatedSenderMarkers.contains { lower.contains($0) }
    }

    private static let automatedSenderMarkers: [String] = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
        "notifications@", "notification@", "mailer", "postmaster", "bounce",
        "newsletter", "digest", "updates@", "info@", "alerts@", "alert@",
        "billing@", "receipts@", "invoice", "automated", "bot@", "system@",
        "noreply.", "via github", "via linkedin", "unsubscribe"
    ]

    // MARK: - Transcript parsing

    /// Splits a "Speaker: text" transcript into its attributed lines, oldest
    /// first. Unattributed lines attach to the line above them as continuation —
    /// a multi-line message renders as one speaker line followed by bare lines.
    ///
    /// The composing adapters append the user's own half-written reply under a
    /// "Draft:" heading; that section is cut off first, because it is the user's
    /// text and reading it as an inbound message would be exactly backwards.
    private static func attributedLines(in transcript: String) -> [(speaker: String, text: String)] {
        var body = transcript
        if let marker = body.range(of: "\nDraft:\n") {
            body = String(body[..<marker.lowerBound])
        }
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [(speaker: String, text: String)] = []
        for line in lines {
            if let split = speakerSplit(line) {
                result.append((split.speaker, split.text))
            } else if !result.isEmpty {
                result[result.count - 1].text += " " + line
            }
            // A bare line before any attribution belongs to no one and is
            // dropped: guessing its speaker is exactly what this file refuses
            // to do.
        }
        return result
    }

    /// Splits "Alice: see you at 5" into its speaker and its text.
    ///
    /// A speaker label is a NAME: short, few words, no sentence punctuation, not
    /// a URL scheme. Every rejection here is one more line that reads like an
    /// attribution but isn't ("https://…", "Note: the build is red").
    private static func speakerSplit(_ line: String) -> (speaker: String, text: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let speaker = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty, speaker.count <= 60, !text.isEmpty else { return nil }
        guard speaker.split(separator: " ").count <= 5 else { return nil }
        guard speaker.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;\"/\\")) == nil else { return nil }
        guard !speaker.lowercased().hasPrefix("http") else { return nil }
        return (speaker, text)
    }

    // MARK: - Dedupe primitives

    /// sha256 of the message text, over a NORMALIZED form: a re-render that
    /// changes whitespace or capitalization is the same message, and hashing the
    /// raw string would let it fire twice.
    private static func digest(of text: String) -> String {
        let normalized = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Per-thread dedupe state, created, updated and EVICTED as one unit.
    ///
    /// The atomicity is the point. When "which threads have been baselined" and
    /// "which lines have been seen" were two independently-capped tables, they
    /// evicted at wildly different rates — one entry per thread versus one entry
    /// per message — so a busy session reached a state where a thread was still
    /// marked baselined but its lines had aged out. Every stale message still on
    /// screen then looked brand new, and Holmes drafted replies to days-old
    /// texts. Here a thread's baseline flag cannot outlive its digests, because
    /// they are the same value: evicting a thread re-arms nothing, it simply
    /// means the next reading of that thread is a first sighting again.
    ///
    /// Eviction is least-recently-touched, so the conversations actually in play
    /// survive a burst of one-off threads.
    private struct ThreadLedger {
        private struct Entry {
            var baselined = false
            /// Lines already accounted for, oldest first (for eviction order).
            var digests: [String] = []
            var digestSet: Set<String> = []
            /// The last line at the previous observation — the append anchor.
            var lastDigest = ""
            /// Distinct readings this thread has appeared in.
            var observations = 0
        }

        private var entries: [String: Entry] = [:]
        private var order: [String] = []
        private let threadCap: Int
        private let digestsPerThread: Int

        init(threadCap: Int, digestsPerThread: Int) {
            self.threadCap = max(1, threadCap)
            self.digestsPerThread = max(1, digestsPerThread)
        }

        func isBaselined(_ key: String) -> Bool { entries[key]?.baselined ?? false }

        func lastDigest(of key: String) -> String { entries[key]?.lastDigest ?? "" }

        func hasSeen(_ key: String, digest: String) -> Bool {
            entries[key]?.digestSet.contains(digest) ?? false
        }

        /// Records everything currently visible in a thread WITHOUT firing, and
        /// marks the thread baselined. Safe to call again on a thread that is
        /// already baselined — that is the re-baseline after a scroll.
        mutating func baseline(_ key: String, digests: [String]) {
            var entry = entries[key] ?? Entry()
            entry.baselined = true
            append(&entry, digests)
            store(key, entry)
        }

        /// Marks lines as dealt with and advances the append anchor to the last
        /// of them. Deliberately does NOT set `baselined`: "this line has been
        /// handled" and "this thread's visible history has been recorded" are
        /// different claims, and only `baseline` may make the second one.
        mutating func record(_ key: String, digests: [String]) {
            var entry = entries[key] ?? Entry()
            append(&entry, digests)
            store(key, entry)
        }

        /// Counts one distinct reading of a thread and returns the new total.
        mutating func observe(_ key: String) -> Int {
            var entry = entries[key] ?? Entry()
            entry.observations += 1
            store(key, entry)
            return entry.observations
        }

        mutating func removeAll() {
            entries.removeAll()
            order.removeAll()
        }

        private func append(_ entry: inout Entry, _ digests: [String]) {
            for digest in digests where !entry.digestSet.contains(digest) {
                entry.digestSet.insert(digest)
                entry.digests.append(digest)
            }
            while entry.digests.count > digestsPerThread {
                entry.digestSet.remove(entry.digests.removeFirst())
            }
            if let last = digests.last { entry.lastDigest = last }
        }

        private mutating func store(_ key: String, _ entry: Entry) {
            entries[key] = entry
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
            order.append(key)
            while order.count > threadCap {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }
}
