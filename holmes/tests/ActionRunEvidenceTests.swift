import Foundation

@main
struct ActionRunEvidenceTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        var run = ActionRunEvidence()
        expect(run.failure == nil && !run.hasSuccessfulAction && !run.declined, "An empty run has no evidence of action success or failure")
        run.record(tool: "computer", action: "screenshot", readOnly: true, isError: false, text: "Screenshot captured")
        expect(!run.hasSuccessfulAction, "A successful screenshot is not a successful action")
        run.record(tool: "computer", action: "left_click", readOnly: false, isError: true, text: "Click blocked: control is disabled")
        expect(run.failure == "Click blocked: control is disabled", "A successful read cannot conceal a subsequent failed action")
        run.record(tool: "computer", action: "screenshot", readOnly: true, isError: false, text: "Fresh screenshot")
        expect(run.failure == "Click blocked: control is disabled" && !run.hasSuccessfulAction, "Reading after a failed click must not convert the run to success")
        run.record(tool: "browser_read", action: nil, readOnly: true, isError: false, text: "Page text")
        expect(run.failure == "Click blocked: control is disabled", "A different successful read also leaves mutation failure unresolved")
        run.record(tool: "computer", action: "scroll", readOnly: false, isError: false, text: "Scrolled")
        expect(run.hasSuccessfulAction, "An actual successful mutation is recorded")
        expect(run.failure == "Click blocked: control is disabled", "Successful scrolling does not repair the failed click")
        run.record(tool: "computer", action: "left_click", readOnly: false, isError: false, text: "Clicked")
        expect(run.failure == nil && run.hasSuccessfulAction, "A successful retry of the same tool/action clears its failure")

        var multiple = ActionRunEvidence()
        multiple.record(tool: "computer", action: "left_click", readOnly: false, isError: true, text: "First click failed")
        multiple.record(tool: "computer", action: "type", readOnly: false, isError: true, text: "Typing failed")
        multiple.record(tool: "computer", action: "screenshot", readOnly: true, isError: true, text: "Read failed")
        expect(multiple.failure == "Typing failed", "The latest unresolved action takes precedence over read errors")
        multiple.record(tool: "computer", action: "type", readOnly: false, isError: false, text: "Typed")
        expect(multiple.failure == "First click failed", "Recovering the latest operation still reports an older unresolved failure")
        multiple.record(tool: "computer", action: "left_click", readOnly: false, isError: false, text: "Clicked")
        expect(multiple.failure == nil, "Once all mutations recover, a prior read failure does not invalidate successful actions")

        var keyed = ActionRunEvidence()
        keyed.record(tool: "browser_one", action: "click", readOnly: false, isError: true, text: "Browser one failed")
        keyed.record(tool: "browser_two", action: "click", readOnly: false, isError: false, text: "Browser two clicked")
        expect(keyed.failure == "Browser one failed", "An identical action name on another tool is not a retry")
        keyed.record(tool: "browser_one", action: "click", readOnly: true, isError: false, text: "Read-only acknowledgement")
        expect(keyed.failure == "Browser one failed", "A read-only result can never clear a mutation failure, even for the same key")
        keyed.record(tool: "browser_one", action: "click", readOnly: false, isError: true, text: "Browser one retry failed again")
        expect(keyed.failure == "Browser one retry failed again", "A failed retry updates the unresolved operation's reason")
        keyed.record(tool: "browser_one", action: "click", readOnly: false, isError: false, text: "Browser one clicked")
        expect(keyed.failure == nil, "The correct tool/action retry recovers its own failure")

        var nilAction = ActionRunEvidence()
        nilAction.record(tool: "write_file", action: nil, readOnly: false, isError: true, text: "Write failed")
        nilAction.record(tool: "write_file", action: "", readOnly: false, isError: false, text: "Different empty-named operation")
        expect(nilAction.failure == "Write failed", "A missing action and an explicitly empty action have distinct ownership")
        nilAction.record(tool: "write_file", action: nil, readOnly: false, isError: false, text: "Written")
        expect(nilAction.failure == nil, "A tool without an action name can still recover on retry")

        var reads = ActionRunEvidence()
        reads.record(tool: "screenshot", action: nil, readOnly: true, isError: true, text: "Screen Recording denied")
        expect(reads.failure == "Screen Recording denied" && !reads.hasSuccessfulAction, "A run with only a failed read reports that reason")
        reads.record(tool: "browser_read", action: nil, readOnly: true, isError: true, text: "Extension disconnected")
        expect(reads.failure == "Extension disconnected", "When every tool failed, report the latest read failure")
        reads.record(tool: "browser_read", action: nil, readOnly: true, isError: false, text: "Read page")
        expect(reads.failure == nil && !reads.hasSuccessfulAction, "A successful read recovers read-only work without claiming an action")

        var recoveredRead = ActionRunEvidence()
        recoveredRead.record(tool: "read_file", action: nil, readOnly: true, isError: true, text: "Read failed")
        recoveredRead.record(tool: "write_file", action: nil, readOnly: false, isError: false, text: "Written")
        expect(recoveredRead.failure == nil && recoveredRead.hasSuccessfulAction, "An actual write can succeed despite an earlier unrelated read failure")
        recoveredRead.record(tool: "read_file", action: nil, readOnly: true, isError: true, text: "Follow-up read failed")
        expect(recoveredRead.failure == nil, "A late read failure does not erase established action success")

        var refusal = ActionRunEvidence()
        refusal.record(tool: "computer", action: "submit", readOnly: false, isError: true, text: "  User declined to submit the form.\n")
        expect(refusal.declined, "A leading user-decline outcome is explicit evidence")
        expect(refusal.failure == "User declined to submit the form." && !refusal.hasSuccessfulAction, "A declined action is not successful")
        refusal.record(tool: "computer", action: "screenshot", readOnly: true, isError: false, text: "Screenshot")
        expect(refusal.declined && refusal.failure != nil, "A later screenshot cannot undo the user's decline")
        refusal.record(tool: "computer", action: "submit", readOnly: false, isError: false, text: "Late callback")
        expect(refusal.declined, "Decline remains sticky even if an already-in-flight callback later reports success")

        var missingErrorFlag = ActionRunEvidence()
        missingErrorFlag.record(tool: "send", action: nil, readOnly: false, isError: false, text: "User declined")
        expect(missingErrorFlag.declined && !missingErrorFlag.hasSuccessfulAction && missingErrorFlag.failure == "User declined",
               "An omitted provider error flag cannot turn a user decline into action success")
        for text in ["The page says User declined", "\"User declined\" is a label", "User declinedness is not the outcome"] {
            var mention = ActionRunEvidence()
            mention.record(tool: "read", action: nil, readOnly: true, isError: false, text: text)
            expect(!mention.declined, "Unanchored text or a partial phrase must not count as a user decline: \(text)")
        }

        var emptyFailure = ActionRunEvidence()
        emptyFailure.record(tool: "computer", action: "click", readOnly: false, isError: true, text: " \n ")
        expect(emptyFailure.failure == "computer (click) failed.", "An empty tool error must still produce a visible failure")
        print("Passed \(checks) action run evidence checks")
    }
}
