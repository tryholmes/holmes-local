import AppKit
import Foundation

// Only the production MenuBarManager and WorkActivityCenter are under test.
// Their app/hardware boundaries record calls without starting any subsystem.
@MainActor final class SearchBarWindowController { static let shared = SearchBarWindowController(); func toggle() {}; func show() {} }
@MainActor final class MainPanelWindowController { static let shared = MainPanelWindowController(); func show() {} }
@MainActor final class GuidedDemoWindowController { static let shared = GuidedDemoWindowController(); func show() {} }
@MainActor final class SettingsWindowController { static let shared = SettingsWindowController(); func show() {} }
@MainActor final class SideIconWindowController {
    static let shared = SideIconWindowController()
    enum IconState { case dormant }
    var iconState: IconState = .dormant
    func show() {}
}
@MainActor final class ClickyController {
    static let shared = ClickyController()
    var cancelCount = 0
    func cancelPushToTalk() { cancelCount += 1 }
}
@MainActor final class EmailDraftCoordinator {
    static let shared = EmailDraftCoordinator()
    var stopped = false
    func start() { stopped = false }
    func stop() { stopped = true }
}
@MainActor final class AutonomousActionRunner {
    static let shared = AutonomousActionRunner()
    var cancelCount = 0
    func cancelCurrentRun() { cancelCount += 1 }
}
@MainActor final class ComputerUseEngine {
    static let shared = ComputerUseEngine()
    var cancelCount = 0
    func cancelRun() { cancelCount += 1 }
}
@MainActor final class SpeechSynthesizer {
    static let shared = SpeechSynthesizer()
    var stopCount = 0
    func stop() { stopCount += 1 }
}
@MainActor final class VisualGuidanceOverlay {
    static let shared = VisualGuidanceOverlay()
    var hideCount = 0
    func hide() { hideCount += 1 }
}
@MainActor final class ScreenGlowController {
    static let shared = ScreenGlowController()
    enum GlowState { case off }
    var offCount = 0
    func set(state: GlowState) { offCount += 1 }
}
@MainActor final class HolmesAgent {
    static let shared = HolmesAgent()
    var starts = 0
    var stops = 0
    var cancelledStarts: Set<Int> = []
    var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func start() async {
        starts += 1
        let id = starts
        await withCheckedContinuation { pending[id] = $0 }
        if Task.isCancelled { cancelledStarts.insert(id) }
    }
    func stop() { stops += 1 }
    func release(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
}

@main
struct WorkLifecycleTests {
    @MainActor static func main() async throws {
        let menu = MenuBarManager.shared
        let center = WorkActivityCenter.shared
        let agent = HolmesAgent.shared
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let old = center.begin(title: "Queued before Pause")
        var cancellationCount = 0
        center.setCancellationHandler(old) { cancellationCount += 1 }
        menu.isPaused = true
        expect(center.activeCount == 0 && cancellationCount == 1, "Pause must cancel actual owned work and invalidate its UI")
        expect(EmailDraftCoordinator.shared.stopped && agent.stops == 1, "Pause must stop observation and compose drafting")
        expect(ClickyController.shared.cancelCount == 1 && AutonomousActionRunner.shared.cancelCount == 1,
               "Pause must stop both voice and autonomous work")
        expect(SpeechSynthesizer.shared.stopCount == 1 && VisualGuidanceOverlay.shared.hideCount == 1
               && ScreenGlowController.shared.offCount == 1, "Pause must clear speech, visual guidance and thinking glow")
        center.finish(old, outcome: .success, summary: "Late answer")
        expect(center.completion == nil, "A response arriving after Pause must not revive the old result")

        menu.suspendForSystemEvent()
        let stoppedCount = agent.stops
        menu.suspendForSystemEvent()
        expect(agent.stops == stoppedCount, "Duplicate sleep/display-lock notifications must coalesce")
        menu.resumeAfterSystemEvent()
        try await Task.sleep(for: .milliseconds(20))
        expect(menu.isPaused && !menu.isSystemSuspended && agent.starts == 0,
               "Wake must preserve an explicit Pause rather than restarting observation")

        menu.isPaused = false
        try await eventually { agent.pending[1] != nil }
        expect(!EmailDraftCoordinator.shared.stopped, "Resume must re-enable compose observation")
        menu.suspendForSystemEvent()
        expect(menu.isSystemSuspended && EmailDraftCoordinator.shared.stopped,
               "Sleep during a suspended startup must synchronously stop observation")
        menu.resumeAfterSystemEvent()
        try await eventually { agent.pending[2] != nil }
        agent.release(1)
        try await eventually { agent.cancelledStarts.contains(1) }
        expect(agent.cancelledStarts.contains(1), "Sleep must cancel the startup that was already awaiting a subsystem")
        // Completing the OLD cancelled startup must not clear the NEW task's
        // handle. Pause now must still reach that new startup's cancellation.
        menu.isPaused = true
        agent.release(2)
        try await eventually { agent.cancelledStarts.contains(2) }
        expect(agent.cancelledStarts.contains(2), "An old resume callback must not orphan the newer startup task")
        menu.stopAllWork()
        expect(center.activeCount == 0 && center.completion == nil,
               "Termination uses the same idempotent teardown and leaves no pending activity")
        print("Passed \(checks) production pause, sleep/wake and startup-cancellation lifecycle checks")
    }

    @MainActor static func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for the controlled lifecycle continuation")
    }
}
