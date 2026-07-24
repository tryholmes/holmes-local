import Foundation
import Observation

// MARK: - RecallSpotlight
// The receipts for a SUBJECT-triggered recall.
//
// MemoryFeed.referenced already answers "which stored rows is Holmes using
// right now". It cannot answer the two questions the user needs in order to
// trust — or reject — an unprompted recall:
//
//   • WHAT made Holmes go looking?  ("hey what is holmes?" → subject: "holmes")
//   • WHY did THIS row come back?   (the repo entity matched, the site matched,
//                                    or nothing literal matched at all)
//
// Those live here rather than on MemoryFeed so this stays purely additive: the
// recall path calls `spotlight(...)`, which lights the dashboard up through the
// existing `MemoryFeed.noteReferenced` and records the subject + per-row reasons
// alongside it. UI reads `topic` and `reason(for:)`.
//
// Honesty rule, same as everywhere else in Holmes: a reason is never invented.
// When the recall engine supplies one it is shown verbatim; otherwise the reason
// is DERIVED by literally re-checking the row's own fields for the subject, and
// when the subject does not literally appear anywhere the row is labelled
// `RecallReason.unverified` so a bad recall is visible instead of laundered.

@Observable
@MainActor
final class RecallSpotlight {
    static let shared = RecallSpotlight()
    private init() {}

    /// The subjects extracted from the inbound message — "holmes",
    /// "tryholmes/holmes", "@alex" — in the extractor's own ranking order.
    /// Empty when the current referenced set wasn't subject-triggered (e.g. the
    /// findSimilar(activity:terms:) path, which keys off what the user is doing
    /// now); the UI hides the "recalled for" line then rather than inventing one.
    var topics: [String] = []

    /// memory row id → why that row came back, verbatim from
    /// `MemoryStore.RecallHit.matchedOn`. Rows the query didn't explain fall
    /// through to `RecallReason`, which re-derives a reason from the row itself.
    var reasons: [Int64: String] = [:]

    /// The primary subject, for the one-line "recalled for:" label.
    var topic: String { topics.first ?? "" }

    /// When the current spotlight was published. @ObservationIgnored — it is a
    /// precedence input, never rendered, and stamping it must not invalidate a
    /// view that is only showing the rows.
    @ObservationIgnored private(set) var spotlitAt: Date = .distantPast

    /// True while a SUBJECT-triggered recall owns the referenced strip and is
    /// recent enough that replacing it would pull the rug out from under a user
    /// who has not read it yet.
    ///
    /// THE PRECEDENCE RULE, and why it exists: two independent paths write the
    /// referenced rows. `MemoryStore.recall(topics:)` answers "what does memory
    /// hold about the thing somebody just asked about"; `findSimilar(activity:)`
    /// answers "what resembles the screen the user is on". The second one fires
    /// on every enrichment — which, when the message arrived in Messages, is
    /// one to three seconds AFTER the recall — and it would silently overwrite
    /// the rows the pending draft's receipts point at. The more specific claim
    /// wins, exactly as it does for context readings in HolmesAgent.
    var holdsSubjectRecall: Bool {
        !topics.isEmpty && Date().timeIntervalSince(spotlitAt) < Self.subjectRecallHold
    }

    /// How long a subject recall outranks an activity match on its own. Long
    /// enough to still be there when the user notices the message and opens
    /// Holmes; short enough that one stale subject cannot own the strip for the
    /// rest of the session. A recall with a draft still waiting on it holds for
    /// as long as that draft does — see HolmesAgent.mayPublishActivityRecall.
    private static let subjectRecallHold: TimeInterval = 180

    /// "holmes" / "holmes, PR #482" / "holmes, PR #482 +2" — the whole reason
    /// the recall happened, in one line's worth of characters.
    var topicsLabel: String { Self.label(for: topics) }

    /// Same formatting for views that are handed a topic list directly (so a
    /// preview or a card can render the line without touching the singleton).
    nonisolated static func label(for topics: [String]) -> String {
        let clean = topics.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "" }
        let shown = clean.prefix(2).joined(separator: ", ")
        return clean.count > 2 ? "\(shown) +\(clean.count - 2)" : shown
    }

    /// The one call the recall path needs: records the subjects and each row's
    /// own reason, then lights the dashboard through the existing feed.
    /// Pass the hits exactly as MemoryStore.recall returned them — `matchedOn`
    /// is shown to the user verbatim and must not be re-worded on the way here.
    func spotlight(topics: [String], hits: [MemoryStore.RecallHit]) {
        var reasons: [Int64: String] = [:]
        for hit in hits {
            let reason = hit.matchedOn.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { reasons[hit.event.id] = reason }
        }
        spotlight(topics: topics, events: hits.map(\.event), reasons: reasons)
    }

    /// Same thing for a caller that only has rows (no per-row reasons). What
    /// isn't supplied is derived deterministically at render time.
    func spotlight(topics: [String], events: [MemoryEvent], reasons: [Int64: String] = [:]) {
        self.topics = topics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.reasons = reasons
        spotlitAt = Date()
        MemoryFeed.shared.noteReferenced(events)
    }

    /// Clears the spotlight and the referenced set together — they are one
    /// state, and a stale "recalled for: holmes" over a different set of rows
    /// would be a lie.
    func clear() {
        topics = []
        reasons = [:]
        spotlitAt = .distantPast
        MemoryFeed.shared.noteReferenced([])
    }

    /// Why this row is on screen. Supplied reason first, derived second.
    func reason(for event: MemoryEvent) -> String {
        if let stored = reasons[event.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return RecallReason.derive(event: event, topics: topics)
    }
}

// MARK: - RecallReason
// Deterministic "why did this match", computed from the row itself.
//
// The fallback for rows that arrived WITHOUT a `MemoryStore.RecallHit.matchedOn`
// — a plain findSimilar/search result, or a row a caller passed through by hand.
// It runs in the view layer with no model call and no network: it re-checks the
// persisted columns for the subject string and names the STRONGEST place it
// actually occurs. Ordering is by how identifying the field is — a named entity
// ("repo = tryholmes/holmes") is a far better reason than a substring buried in
// a detail blob, and the host is a better reason than the app name.

enum RecallReason {
    /// The row came back from the full-text query, but the subject does not
    /// literally appear in any of its columns. Shown in the warning colour: it
    /// is exactly the case where a recall may be wrong, and the user is the one
    /// who can tell.
    static let unverified = "no literal match"

    /// Best reason across all the subjects that were searched: the first topic
    /// that literally occurs somewhere in the row wins, and `unverified` is only
    /// returned when NONE of them do.
    static func derive(event: MemoryEvent, topics: [String]) -> String {
        for topic in topics {
            let reason = derive(event: event, topic: topic)
            if !reason.isEmpty, !isWeak(reason) { return reason }
        }
        return topics.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 })
            ? unverified
            : ""
    }

    static func derive(event: MemoryEvent, topic: String) -> String {
        let needle = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard needle.count >= 2 else { return "" }

        // 1. Named entities — the browser extension writes these from the DOM
        //    ("repo", "issue", "handle"), so they carry their own label.
        for (key, value) in event.entities.sorted(by: { $0.key < $1.key })
        where value.lowercased().contains(needle) {
            return "\(key) entity"
        }
        // 2. The host the row was captured on.
        if !event.site.isEmpty, event.site.lowercased().contains(needle) {
            return "site \(event.site)"
        }
        // 3. The deterministic headline written when the context was captured.
        if event.summary.lowercased().contains(needle) {
            return "named in summary"
        }
        if !event.windowTitle.isEmpty, event.windowTitle.lowercased().contains(needle) {
            return "in window title"
        }
        if !event.url.isEmpty, event.url.lowercased().contains(needle) {
            return "in url"
        }
        if event.detail.lowercased().contains(needle) {
            return "named in detail"
        }
        if !event.app.isEmpty, event.app.lowercased().contains(needle) {
            return "app \(event.app)"
        }
        return unverified
    }

    /// True for a reason the user should look twice at.
    static func isWeak(_ reason: String) -> Bool { reason == unverified }
}

// MARK: - RecallTime
// Conversational relative time for the recall surfaces ("2h ago", "yesterday").
// Deliberately wordier than AgentMemoryCard's 34pt-column formatter, which has
// to fit "2h" — these rows are read as a sentence, not scanned as a table.

enum RecallTime {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400, Calendar.current.isDateInToday(date) {
            return "\(Int(seconds / 3600))h ago"
        }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        if seconds < 7 * 86_400 { return "\(max(1, Int(seconds / 86_400)))d ago" }
        return dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
