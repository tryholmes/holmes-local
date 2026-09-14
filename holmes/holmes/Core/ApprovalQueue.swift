import Foundation

// Result of a user approving/dismissing an agent tool call.
enum AgentDecision {
    case approved(text: String)   // `text` carries any edits the user made in the preview
    case dismissed
    /// Nobody answered an unattended (autonomous) approval before its deadline.
    /// Callers treat it like a dismissal but report it as a timeout.
    case timedOut
}

/// Deadline policy for approvals raised by work nobody is watching.
enum ApprovalScope {
    /// When set, every approval raised in this task resolves `.timedOut` after
    /// this many seconds without an answer. Autonomous playbook runs set it; a
    /// user initiated request leaves it nil and may keep waiting.
    @TaskLocal static var unattendedTimeout: TimeInterval?

    /// The deadline autonomous runs use. A static var so tests can shorten it.
    nonisolated(unsafe) static var defaultUnattendedTimeout: TimeInterval = 120

    static let timedOutMessage = "Timed out waiting for approval"
}

// MARK: - ApprovalQueue
//
// FIFO of approval requests. Exactly one is presented at a time; a second
// request arriving while the first is showing WAITS instead of dismissing it
// (which a waiting run used to read as "declined"). When the current one
// resolves, the next is presented. A cancelled request leaves the queue (or
// the screen) without touching anyone else's decision.

@MainActor
final class ApprovalQueue<Item> {
    private struct Entry {
        let id: UUID
        let item: Item
        let resolve: (AgentDecision) -> Void
        var deadline: Task<Void, Never>?
    }

    private var current: Entry?
    private var waiting: [Entry] = []

    /// Presents `item` (a new current request), or hides the card with nil.
    var onPresent: (Item?) -> Void = { _ in }
    /// Called before a timed out request resolves, for user visible status.
    var onTimeout: (Item) -> Void = { _ in }

    init() {}

    var currentID: UUID? { current?.id }
    var currentItem: Item? { current?.item }
    var queuedCount: Int { waiting.count }
    var isIdle: Bool { current == nil && waiting.isEmpty }

    func contains(_ id: UUID) -> Bool {
        current?.id == id || waiting.contains { $0.id == id }
    }

    /// Suspends until the request is approved, dismissed, cancelled (the
    /// awaiting task) or timed out.
    func decide(id: UUID, item: Item, timeout: TimeInterval?) async -> AgentDecision {
        guard !Task.isCancelled else { return .dismissed }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AgentDecision, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .dismissed)
                    return
                }
                enqueue(id: id, item: item, timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    func enqueue(id: UUID, item: Item, timeout: TimeInterval?, resolve: @escaping (AgentDecision) -> Void) {
        var entry = Entry(id: id, item: item, resolve: resolve)
        if let timeout, timeout.isFinite {
            // The deadline runs from ENQUEUE: an unattended request waiting
            // behind a user's card still frees its playbook slot on time.
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            entry.deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.timeOut(id: id)
            }
        }
        if current == nil {
            current = entry
            onPresent(item)
        } else {
            waiting.append(entry)
        }
    }

    /// Resolves the presented request (Approve / Dismiss) and presents the next.
    func resolveCurrent(_ decision: AgentDecision) {
        guard let entry = current else { return }
        finish(entry, decision)
    }

    /// Removes a request wherever it is, resolving it `.dismissed`.
    func cancel(id: UUID) {
        resolve(id: id, .dismissed)
    }

    /// Dismisses everything, current first, then the queue in order.
    func dismissAll() {
        let all = (current.map { [$0] } ?? []) + waiting
        waiting.removeAll()
        current = nil
        for entry in all {
            entry.deadline?.cancel()
            entry.resolve(.dismissed)
        }
        onPresent(nil)
    }

    private func timeOut(id: UUID) {
        guard let entry = current?.id == id ? current : waiting.first(where: { $0.id == id }) else { return }
        onTimeout(entry.item)
        resolve(id: id, .timedOut)
    }

    private func resolve(id: UUID, _ decision: AgentDecision) {
        if let entry = current, entry.id == id {
            finish(entry, decision)
        } else if let index = waiting.firstIndex(where: { $0.id == id }) {
            let entry = waiting.remove(at: index)
            entry.deadline?.cancel()
            entry.resolve(decision)
        }
    }

    private func finish(_ entry: Entry, _ decision: AgentDecision) {
        entry.deadline?.cancel()
        // Advance BEFORE resuming the waiter so a caller that immediately asks
        // again queues behind the next request instead of jumping it.
        if waiting.isEmpty {
            current = nil
            onPresent(nil)
        } else {
            let next = waiting.removeFirst()
            current = next
            onPresent(next.item)
        }
        entry.resolve(decision)
    }
}
