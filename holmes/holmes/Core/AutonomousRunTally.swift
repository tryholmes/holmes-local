import Foundation

// MARK: - AutonomousRunTally
//
// Honest accounting for an autonomous plan. A step that failed even after its
// retry is skipped so one flaky control cannot kill the whole task, but a
// skipped step is REQUIRED work that did not happen: the run must finish as a
// failure that names the step, never as a plain "done".

struct AutonomousRunTally {
    struct Skipped: Equatable {
        let summary: String
        let reason: String
    }

    let plannedSteps: Int
    private(set) var completed = 0
    private(set) var skipped: [Skipped] = []

    init(plannedSteps: Int) {
        self.plannedSteps = plannedSteps
    }

    mutating func recordCompleted(_ count: Int = 1) {
        completed += max(0, count)
    }

    mutating func recordSkipped(summary: String, reason: String) {
        skipped.append(Skipped(summary: summary, reason: reason))
    }

    var succeeded: Bool { skipped.isEmpty }

    /// The run's outcome note: "done", or a failure that names what was skipped.
    var note: String {
        guard let first = skipped.first else { return "done" }
        let count = skipped.count
        let steps = count == 1 ? "1 required step was" : "\(count) required steps were"
        let reason = Self.clip(first.reason, 120)
        return "Failed: \(steps) skipped, starting with “\(Self.clip(first.summary, 60))”"
            + (reason.isEmpty ? "" : " (\(reason))")
    }

    func notifyBody(undoAvailable: Bool) -> String {
        let undo = undoAvailable ? " Undo is available in the Holmes panel." : ""
        guard !succeeded else {
            return "\(completed) of \(plannedSteps) steps completed.\(undo)"
        }
        let count = skipped.count
        return "Failed: \(completed) of \(plannedSteps) steps completed, \(count) skipped "
            + "(“\(Self.clip(skipped[0].summary, 50))”).\(undo)"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
