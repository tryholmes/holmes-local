import Foundation

@main
struct WorkActivityTests {
    @MainActor static func main() async throws {
        let center = WorkActivityCenter()
        let vm = NotchViewModel()
        var changes: [UInt64] = []
        center.onChange = {
            changes.append(center.revision)
            vm.synchronize(with: center)
        }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        let background = center.begin(title: "Drafting in the background", origin: .background)
        center.update(background, phase: .working)
        let user = center.begin(title: "Write this email")
        center.update(user, phase: .queued, detail: "Waiting for the model")
        expect(center.selectedActivity?.id == user, "Explicit queued work must remain visible over background work")
        expect(vm.taskActive && vm.taskIsIndeterminate && vm.taskPhase == .queued,
               "Queued work must have a persistent indeterminate indicator")
        expect(vm.additionalTaskCount == 1, "Concurrent work must remain represented")
        center.finish(background, outcome: .success, summary: "Background draft ready")
        expect(center.selectedActivity?.id == user && vm.taskActive,
               "A background completion must not clear explicit work")
        expect(center.completion == nil, "A hidden background completion must not steal the explicit result banner")
        let revision = center.revision
        center.update(background, phase: .working, detail: "Late callback")
        center.finish(background, outcome: .failure, summary: "Late failure")
        expect(center.revision == revision, "Finished owners must reject duplicate terminal and late progress callbacks")

        let secondBackground = center.begin(title: "Reading context", origin: .background)
        center.update(user, phase: .working, progress: 0.5)
        expect(vm.taskProgress == 0.5 && !vm.taskIsIndeterminate, "Known work fractions must be represented honestly")
        center.update(user, phase: .working)
        expect(vm.taskIsIndeterminate, "A new model stage must not retain an invented step percentage")
        center.finish(user, outcome: .success, summary: "Email draft ready")
        expect(center.selectedActivity?.id == secondBackground && vm.taskActive,
               "Finishing the explicit owner must reveal remaining background work")
        expect(vm.lastResult == "Email draft ready", "The explicit deliverable must remain available in the expanded panel")
        expect(!vm.sneakPeek.show, "A completion banner must not replace remaining live work")
        center.cancel(secondBackground)

        let failure = center.begin(title: "Answer aloud")
        center.finish(failure, outcome: .failure, summary: "Screen Recording permission is needed.")
        expect(!vm.taskActive && vm.sneakPeek.show && vm.lastResultFailed,
               "Errors must remain visible even when speech is unavailable or disabled")
        expect(vm.lastResultSymbol == "exclamationmark.triangle.fill", "Failed results must not render a success checkmark")
        let next = center.begin(title: "A newer request")
        expect(vm.taskActive, "New work must retain live precedence while an old result timer exists")

        var cancelled: [UUID] = []
        center.setCancellationHandler(next) { cancelled.append(next) }
        center.cancelSelected()
        expect(cancelled == [next] && center.activeCount == 0, "Stop must invoke exactly the selected owner's cancellation")
        center.cancel(next)
        expect(cancelled == [next], "Repeated Stop cannot cancel another or newer request")

        let sleeping = center.begin(title: "Before sleep")
        center.setCancellationHandler(sleeping) { cancelled.append(sleeping) }
        center.invalidateAll()
        expect(cancelled == [next, sleeping] && center.activeCount == 0 && center.completion == nil,
               "Sleep must cancel active owners and invalidate their result epoch")
        expect(!vm.taskActive && !vm.sneakPeek.show, "Sleep must clear the work and old terminal reveal")
        let afterWake = center.begin(title: "After wake")
        center.finish(sleeping, outcome: .success, summary: "Old response")
        center.update(sleeping, phase: .speaking)
        expect(center.selectedActivity?.id == afterWake && center.completion == nil,
               "A pre-sleep continuation cannot revive activity or overwrite the new request")
        center.update(afterWake, phase: .working, progress: .nan)
        expect(center.selectedActivity?.progress == nil, "Invalid numeric progress must remain indeterminate")
        center.update(afterWake, phase: .working, progress: 2)
        expect(center.selectedActivity?.progress == 1, "Real fractions must be clamped to the UI range")
        center.cancel(afterWake)

        vm.showSneakPeek(title: "Old", subtitle: "Old result", symbol: "checkmark", duration: 0.03)
        vm.showSneakPeek(title: "New", subtitle: "New result", symbol: "checkmark", duration: 0.25)
        try await Task.sleep(for: .milliseconds(70))
        expect(vm.sneakPeek.show && vm.sneakPeek.title == "New",
               "A cancelled old terminal timer must not dismiss the replacement result")
        vm.hideSneakPeek()
        expect(changes == changes.sorted() && Set(changes).count == changes.count,
               "The notch observer must receive ordered synchronous revisions")
        print("Passed \(checks) owned work activity and notch lifecycle checks")
    }
}
