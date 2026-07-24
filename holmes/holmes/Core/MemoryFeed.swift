import Foundation
import Observation

// MARK: - MemoryFeed
// The SwiftUI-facing mirror of MemoryStore.
//
// MemoryStore is an actor, and a SwiftUI `body` is a synchronous, non-isolated
// function — it can never `await` the actor to read a row. So the dashboard
// reads THIS: a @MainActor @Observable snapshot that the store pushes into
// whenever it writes.
//
// The refresh discipline matters. The perception loop can attempt a write on
// every tick, and a dashboard that re-queried SQLite on each one would burn
// main-thread time redrawing rows that didn't change. Instead the writer calls
// `markDirty()` — which only schedules — and the feed drains at most once every
// `minRefreshInterval`. There is no timer: an idle Holmes does zero work here.

@Observable
@MainActor
final class MemoryFeed {
    static let shared = MemoryFeed()

    /// Newest events across all kinds — the dashboard's main list.
    var recent: [MemoryEvent] = []

    /// The rows the agent is USING for the task in flight, so the dashboard can
    /// show "referenced right now" rather than just "stored at some point".
    /// Cleared by passing an empty array when the task ends.
    var referenced: [MemoryEvent] = []

    /// Lifetime row count.
    var totalCount: Int = 0

    /// Rows recorded since local midnight.
    var todayCount: Int = 0

    /// Timestamp of the newest row, or nil when memory is empty. Drives the
    /// "last remembered N minutes ago" line.
    var lastWrite: Date?

    /// How many rows the list holds. Deliberately small: this is a live feed of
    /// what Holmes is noticing, not a browsable archive.
    private static let recentLimit = 30

    /// Most rows kept in `referenced` — the agent grounds on a handful, and a
    /// longer list would just be noise in the UI.
    private static let referencedLimit = 12

    /// Floor on time between refreshes. Two seconds is under the threshold
    /// where a list update reads as "delayed" but far above the perception
    /// loop's write rate.
    private static let minRefreshInterval: TimeInterval = 2

    // Coalescing state. @ObservationIgnored so mutating it never invalidates a
    // view — none of it is rendered, and marking dirty must stay free.
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: Date = .distantPast

    private init() {}

    // MARK: - Refresh

    /// Pulls the recent rows and the counters off the actor and publishes them.
    /// Safe to call directly (e.g. `.task { await MemoryFeed.shared.refresh() }`
    /// when the dashboard appears) — it bypasses the coalescer on purpose, so a
    /// view that just became visible shows current data immediately.
    func refresh() async {
        let events = await MemoryStore.shared.recent(limit: Self.recentLimit)
        let counts = await MemoryStore.shared.stats()

        // Both awaits have already hopped back to the main actor by here, so
        // these assignments publish on the same turn the view observes.
        recent = events
        totalCount = counts.total
        todayCount = counts.today
        lastWrite = events.first?.date
        lastRefreshAt = Date()
    }

    /// Called by the writer after a successful insert. Cheap by contract: it
    /// schedules a drain and returns, so MemoryStore can call it on every row
    /// without thinking about cost.
    ///
    /// Coalescing rules:
    ///   • at most one drain is ever pending — later calls during the wait fold
    ///     into it, which is the whole point;
    ///   • the drain waits out the remainder of `minRefreshInterval` since the
    ///     last completed refresh, so a burst of writes produces one query;
    ///   • the Task captures `self` weakly and lives at most that interval, so
    ///     it can neither retain the feed nor outlive it.
    func markDirty() {
        guard pendingRefresh == nil else { return }
        let wait = Self.minRefreshInterval - Date().timeIntervalSince(lastRefreshAt)
        pendingRefresh = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            // Cleared BEFORE the query: a write that lands while the refresh is
            // in flight schedules the next drain instead of being swallowed.
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    // MARK: - Referenced

    /// Records which stored rows the agent is grounding the current task on.
    /// Deduped by id with first-seen order preserved, since the caller's order
    /// is relevance order and the UI shows the strongest match first.
    func noteReferenced(_ events: [MemoryEvent]) {
        var seen = Set<Int64>()
        var unique: [MemoryEvent] = []
        for event in events where !seen.contains(event.id) {
            seen.insert(event.id)
            unique.append(event)
            if unique.count == Self.referencedLimit { break }
        }
        referenced = unique
    }
}
