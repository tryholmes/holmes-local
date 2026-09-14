import Foundation

@main
struct AutonomousRunTallyTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        var clean = AutonomousRunTally(plannedSteps: 2)
        clean.recordCompleted()
        clean.recordCompleted()
        expect(clean.succeeded && clean.note == "done", "A run with every step completed succeeds")
        expect(clean.notifyBody(undoAvailable: true) == "2 of 2 steps completed. Undo is available in the Holmes panel.",
               "A clean run reports its steps and undo")

        var skipped = AutonomousRunTally(plannedSteps: 4)
        skipped.recordCompleted(3)
        skipped.recordSkipped(summary: "Press Reply in Mail", reason: "No accessible button labeled “Reply” in Mail")
        expect(!skipped.succeeded, "A skipped required step fails the run")
        expect(skipped.note.hasPrefix("Failed: 1 required step was skipped"), "The note says the run failed: \(skipped.note)")
        expect(skipped.note.contains("Press Reply in Mail") && skipped.note.contains("No accessible button"),
               "The note names the skipped step and why")
        expect(skipped.notifyBody(undoAvailable: false).hasPrefix("Failed: 3 of 4 steps completed, 1 skipped"),
               "The notification never reads as success when a step was skipped")

        skipped.recordSkipped(summary: "Type the reply", reason: "")
        expect(skipped.note.hasPrefix("Failed: 2 required steps were skipped"), "Several skips are counted")

        var unsure = AutonomousRunTally(plannedSteps: 2)
        unsure.recordCompleted(2)
        unsure.recordUnverified(summary: "Type the reply into Slack", reason: "the field does not expose its contents")
        expect(unsure.succeeded && !unsure.isFullyVerified, "An unverified step is not a failure, and not fully verified")
        expect(unsure.note != "done" && unsure.note.hasPrefix("Done, but 1 step could not be verified")
               && unsure.note.contains("Type the reply into Slack"),
               "An unverified step is named in the note, never a plain done: \(unsure.note)")
        expect(unsure.notifyBody(undoAvailable: false) == "2 of 2 steps completed, 1 unverified (“Type the reply into Slack”). Check them.",
               "The notification says which step is unverified")
        unsure.recordSkipped(summary: "Press Send", reason: "not found")
        expect(!unsure.succeeded && unsure.note.hasPrefix("Failed:"), "A skipped step still fails the run even with unverified steps")

        print("Passed \(checks) autonomous run tally checks")
    }
}
