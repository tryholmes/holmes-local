import Foundation

// MARK: - Computer use run ownership
//
// Every computer control session (a user request, an autonomous plan, an undo)
// owns a token. The kill switch and the "last screenshot the model saw" belong
// to that token, never to the whole process: starting a second run must not
// disarm ⌘⌥Esc for a run that is already in flight, and a click must never be
// mapped through a screenshot another run captured.
//
// A run started while another run is in scope becomes its CHILD (the runner's
// model segment drives HolmesBrain.run), so cancelling the parent stops the
// nested session as well. Stop all (⌘⌥Esc, Pause, sleep) cancels every token.

struct ComputerUseRunToken: Hashable, Sendable {
    let id: UUID
    init() { id = UUID() }
}

/// The run the current task is acting for. Set with
/// `ComputerUseRunScope.$token.withValue(token) { … }`; task locals flow through
/// awaits, child tasks and the model client's tool callbacks.
enum ComputerUseRunScope {
    @TaskLocal static var token: ComputerUseRunToken?
}

@MainActor
final class ComputerUseRunRegistry<Capture> {
    private struct Entry {
        let parent: ComputerUseRunToken?
        var cancelled = false
        var capture: Capture?
    }

    private var entries: [ComputerUseRunToken: Entry] = [:]
    /// Runs holding a capture, oldest first. Only CAPTURES are bounded (they
    /// are full screenshots); a run's kill switch entry lives until `end`, so a
    /// long run can never be evicted and misread as cancelled.
    private var captureOrder: [ComputerUseRunToken] = []
    /// Work that runs with no token in scope (a Settings self test, a
    /// standalone key press) shares one slot so a screenshot then click still
    /// map against the same frame, exactly like the historical single run.
    let unscoped = ComputerUseRunToken()
    /// Most runs that keep a screenshot at once.
    private let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(4, capacity)
    }

    var activeCount: Int { entries.count }

    /// Registers a fresh run. It starts uncancelled with no capture, and never
    /// touches any other run's state.
    @discardableResult
    func begin(parent: ComputerUseRunToken? = nil) -> ComputerUseRunToken {
        let token = ComputerUseRunToken()
        let knownParent = parent.flatMap { entries[$0] == nil ? nil : $0 }
        entries[token] = Entry(parent: knownParent)
        return token
    }

    func end(_ token: ComputerUseRunToken) {
        entries.removeValue(forKey: token)
        captureOrder.removeAll { $0 == token }
    }

    /// Cancels one run (and, through `isCancelled`, every run nested in it).
    func cancel(_ token: ComputerUseRunToken) {
        if token == unscoped {
            unscopedCancelled = true
            return
        }
        entries[token]?.cancelled = true
    }

    /// Stop all: every registered run and the unscoped slot.
    func cancelAll() {
        for key in entries.keys { entries[key]?.cancelled = true }
        unscopedCancelled = true
    }

    /// Re-arms only the unscoped slot (a user initiated action with no run
    /// of its own). Registered runs are untouched.
    func resetUnscoped() {
        unscopedCancelled = false
        unscopedCapture = nil
    }

    private var unscopedCancelled = false
    private var unscopedCapture: Capture?

    func isCancelled(_ token: ComputerUseRunToken?) -> Bool {
        guard let token, token != unscoped else { return unscopedCancelled }
        var cursor: ComputerUseRunToken? = token
        var hops = 0
        while let current = cursor, hops <= entries.count {
            guard let entry = entries[current] else {
                // An ended run can no longer act; a parent that ended does not
                // cancel a child that is still running.
                return current == token
            }
            if entry.cancelled { return true }
            cursor = entry.parent
            hops += 1
        }
        return false
    }

    func capture(for token: ComputerUseRunToken?) -> Capture? {
        guard let token, token != unscoped else { return unscopedCapture }
        return entries[token]?.capture
    }

    func setCapture(_ capture: Capture?, for token: ComputerUseRunToken?) {
        guard let token, token != unscoped else {
            unscopedCapture = capture
            return
        }
        guard entries[token] != nil else { return }
        entries[token]?.capture = capture
        captureOrder.removeAll { $0 == token }
        guard capture != nil else { return }
        captureOrder.append(token)
        while captureOrder.count > capacity {
            let oldest = captureOrder.removeFirst()
            entries[oldest]?.capture = nil
        }
    }
}
