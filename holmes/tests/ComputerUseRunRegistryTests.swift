import Foundation

@main
struct ComputerUseRunRegistryTests {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        let runs = ComputerUseRunRegistry<String>()
        let first = runs.begin()
        runs.setCapture("frame seen by the first run", for: first)
        runs.cancel(first)
        expect(runs.isCancelled(first), "Cancelling a run arms its kill switch")

        // The regression: beginning a second run used to reset one global kill
        // flag and one global screenshot for every run in flight.
        let second = runs.begin()
        expect(runs.isCancelled(first), "Starting another run must not disarm the kill switch of a run in flight")
        expect(!runs.isCancelled(second), "A new run starts uncancelled")
        expect(runs.capture(for: first) == "frame seen by the first run",
               "Starting another run must not clear the first run's screenshot")
        expect(runs.capture(for: second) == nil, "A new run never inherits another run's screenshot")
        runs.setCapture("frame seen by the second run", for: second)
        expect(runs.capture(for: first) == "frame seen by the first run",
               "A screenshot taken by one run must never become the mapping frame of another")

        // Nested sessions follow their parent.
        let parent = runs.begin()
        let child = runs.begin(parent: parent)
        expect(!runs.isCancelled(child), "A child run starts live")
        runs.cancel(parent)
        expect(runs.isCancelled(child), "Cancelling a plan also stops the model session nested in it")
        let sibling = runs.begin()
        runs.cancel(sibling)
        let otherChild = runs.begin(parent: second)
        expect(!runs.isCancelled(otherChild) && !runs.isCancelled(second),
               "Cancelling one run leaves unrelated runs and their children live")

        // Stop all reaches every run, including ones that started later than an earlier stop.
        runs.cancelAll()
        expect([first, second, parent, child, sibling, otherChild].allSatisfy { runs.isCancelled($0) },
               "Stop all cancels every registered run")
        expect(runs.isCancelled(nil), "Stop all also cancels unscoped work")
        runs.resetUnscoped()
        expect(!runs.isCancelled(nil) && runs.isCancelled(second),
               "Re arming unscoped work never revives a cancelled run")

        let ended = runs.begin()
        runs.end(ended)
        expect(runs.isCancelled(ended) && runs.capture(for: ended) == nil,
               "An ended run can no longer act or keep a capture")

        // A long run must never be evicted and then read as cancelled, however
        // many short runs (Settings self tests, requests) start after it.
        let bounded = ComputerUseRunRegistry<Int>(capacity: 4)
        let longRun = bounded.begin()
        bounded.setCapture(0, for: longRun)
        var shortRuns: [ComputerUseRunToken] = []
        for index in 1...100 {
            let run = bounded.begin()
            bounded.setCapture(index, for: run)
            shortRuns.append(run)
        }
        expect(!bounded.isCancelled(longRun), "A live run started before 100 others is still live, not evicted into cancelled")
        expect(bounded.capture(for: longRun) == nil && bounded.capture(for: shortRuns.last!) == 100,
               "Only screenshots are bounded: the oldest capture is dropped")
        bounded.cancelAll()
        expect(bounded.isCancelled(longRun), "Stop all still reaches the long run")
        for run in shortRuns { bounded.end(run) }
        expect(bounded.activeCount == 1, "Ended runs leave the table; the live one stays")

        print("Passed \(checks) computer use run ownership checks")
    }
}
