import Foundation

// Compile the production coordinator, session, trigger, and output parser against
// controlled platform boundaries. No browser, Mail, model, or insertion is used.
enum ContextSource { case none, browserExtension, accessibility, ocr }
enum ContextConfidence { case exact, structural, inferred }
enum ContextSurface: String { case emailCompose, emailRead }
struct LiveContext {
    let source: ContextSource
    let confidence: ContextConfidence
    let app: String
    var activity: String = "composing"
    var headline: String = "Writing email"
    var entities: [String: String] = [:]
    var bodyText: String = ""
    var capturedAt: Date = Date()
    var emailCompose: EmailComposeSnapshot?
    var age: TimeInterval { Date().timeIntervalSince(capturedAt) }
}
@MainActor final class NSWorkspace {
    struct Application { let bundleIdentifier: String? }
    static let shared = NSWorkspace()
    var frontmostApplication: Application?
}
@MainActor final class HolmesAgent {
    static let shared = HolmesAgent()
    var live = LiveContext(source: .none, confidence: .inferred, app: "Finder")
    func logActivity(note: String) {}
}
@MainActor final class BrowserBridge {
    static let shared = BrowserBridge()
    var emailComposeUnavailableReason: String?
    var refreshes = 0
    var insertions = 0
    var current: LiveContext?
    var handler: (() async -> LiveContext?)?
    func refreshEmailComposeContext() async -> LiveContext? {
        refreshes += 1
        if let handler { return await handler() }
        return current
    }
    func stageEmailDraft(_ body: String, expected: EmailComposeSnapshot) async throws -> Bool {
        insertions += 1
        return true
    }
}
@MainActor enum MailComposeReader {
    static var current: LiveContext?
    static var insertions = 0
    static func refreshEmailComposeContext() -> LiveContext? { current }
    static func stageEmailDraft(_ body: String, expected: EmailComposeSnapshot) async throws -> Bool {
        insertions += 1
        return true
    }
}
@MainActor final class MenuBarManager {
    static let shared = MenuBarManager()
    var isPaused = false
}
@MainActor final class AutonomyPolicy {
    static let shared = AutonomyPolicy()
    var enabled = true
    func isEnabled(_ key: String) -> Bool { enabled }
}
enum OllamaConfig {
    static var isConfigured = true
    static var notReadyMessage = "The model is unavailable"
}
@MainActor final class OllamaClient {
    enum Priority { case agent, background }
    enum AgentError: Error { case busy }
    struct Call { let prompt: String; let priority: Priority; let owner: UUID? }
    static let shared = OllamaClient()
    var calls: [Call] = []
    var handler: ((Call) async throws -> String)?
    static func objectSchema(_ fields: [String: [String: String]]) -> [String: Any] { fields }
    func complete(system: String, user: String, maxTokens: Int, asJSON: Bool,
                  schema: [String: Any], priority: Priority) async throws -> String {
        let call = Call(prompt: user, priority: priority, owner: WorkActivityScope.id)
        calls.append(call)
        if let handler { return try await handler(call) }
        return #"{"body":"Hi, I'm running late. I'm sorry for the delay."}"#
    }
}
enum DraftKind { case emailCompose }
enum DraftTarget { case emailCompose(EmailComposeSnapshot), clipboard }
struct ProactiveDraft {
    let id: UUID
    let playbookId: String
    let kind: DraftKind
    let title: String
    let body: String
    let contextSummary: String
    let target: DraftTarget
}
@MainActor final class PlaybookEngine {
    struct Offered { let draft: ProactiveDraft; let prioritized: Bool }
    static let shared = PlaybookEngine()
    var offered: [Offered] = []
    func offerDraft(_ draft: ProactiveDraft, prioritize: Bool) { offered.append(.init(draft: draft, prioritized: prioritize)) }
}

@MainActor private final class CoordinatorHold<Value> {
    var started = false
    var cancelled = false
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; started = true }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
    }
    func release(_ value: Value) {
        let pending = continuation
        continuation = nil
        precondition(pending != nil)
        pending?.resume(returning: value)
    }
}

@main
struct EmailDraftCoordinatorTests {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let coordinator = EmailDraftCoordinator.shared
        let center = WorkActivityCenter.shared
        let browser = BrowserBridge.shared
        let model = OllamaClient.shared
        let cards = PlaybookEngine.shared

        reset()
        let first = compose()
        show(first)
        coordinator.observe(context(first))
        expect(model.calls.isEmpty && cards.offered.isEmpty, "Observing headers must wait for the stable dwell")
        await eventually { cards.offered.count == 1 }
        expect(model.calls.count == 1 && model.calls[0].priority == .background, "First stable automatic draft uses background model priority")
        expect(model.calls[0].owner != nil && center.activeCount == 0, "Automatic generation owns and finishes one activity")
        expect(browser.refreshes == 2, "Automatic draft reads fresh context before claiming and again before publishing")
        expect(!cards.offered[0].prioritized && cards.offered[0].draft.body.contains("running late"), "Automatic draft publishes the actual editable email body")
        expect(browser.insertions == 0 && MailComposeReader.insertions == 0, "Generating a card never inserts or sends")
        show(first)
        coordinator.observe(context(first))
        await pause(1.7)
        expect(model.calls.count == 1 && cards.offered.count == 1, "Unchanged composer is drafted only once")

        reset()
        let typing = compose()
        show(typing)
        coordinator.observe(context(typing))
        await pause(0.2)
        let typed = compose(identity: typing.identity, body: "My own email text")
        show(typed)
        coordinator.observe(context(typed))
        await pause(1.6)
        expect(model.calls.isEmpty && cards.offered.isEmpty, "Continued typing during dwell cancels automatic generation")

        reset()
        let beforeEdit = compose(subject: "Old subject")
        show(beforeEdit)
        coordinator.observe(context(beforeEdit))
        await pause(0.3)
        let afterEdit = compose(identity: beforeEdit.identity, subject: "New subject")
        show(afterEdit)
        coordinator.observe(context(afterEdit))
        await eventually { cards.offered.count == 1 }
        expect(model.calls.count == 1 && model.calls[0].prompt.contains("New subject"), "Editing subject during debounce drafts only the final stable header")

        reset()
        let duringModel = compose()
        let heldModel = CoordinatorHold<String>()
        model.handler = { _ in await heldModel.wait() }
        show(duringModel)
        coordinator.observe(context(duringModel))
        await eventually { heldModel.started }
        let changedBody = compose(identity: duringModel.identity, body: "I started typing")
        show(changedBody)
        coordinator.observe(context(changedBody))
        await eventually { heldModel.cancelled }
        heldModel.release(#"{"body":"Old generated body"}"#)
        await eventually { center.activeCount == 0 }
        expect(cards.offered.isEmpty, "Typing during generation prevents publication even if the model completes late")

        reset()
        let queued = compose()
        model.handler = { _ in throw OllamaClient.AgentError.busy }
        show(queued)
        coordinator.observe(context(queued))
        await eventually { center.selectedActivity?.phase == .queued }
        expect(model.calls.count == 1, "Busy automatic drafting reports queued work")
        coordinator.observe(LiveContext(source: .none, confidence: .inferred, app: "Finder"))
        await eventually { center.activeCount == 0 }
        await pause(1.1)
        expect(model.calls.count == 1 && cards.offered.isEmpty, "Leaving the email cancels queued retries")

        reset()
        let automatic = compose()
        let heldAutomatic = CoordinatorHold<String>()
        model.handler = { call in
            if call.priority == .background { return await heldAutomatic.wait() }
            return #"{"body":"Explicit email draft"}"#
        }
        show(automatic)
        coordinator.observe(context(automatic))
        await eventually { heldAutomatic.started }
        let explicitResult = await coordinator.request(instruction: "Draft this email", context: context(automatic))
        guard case .ready = explicitResult else { fatalError("Explicit drafting should succeed") }
        await eventually { heldAutomatic.cancelled }
        expect(cards.offered.count == 1 && cards.offered[0].prioritized, "Explicit request preempts background generation and gets the foreground card")
        heldAutomatic.release(#"{"body":"Old automatic draft"}"#)
        await pause(0.05)
        expect(cards.offered.count == 1 && cards.offered[0].draft.body == "Explicit email draft", "Preempted automatic result cannot replace the explicit card")

        reset()
        let initialRefresh = CoordinatorHold<LiveContext?>()
        browser.handler = { await initialRefresh.wait() }
        let initialContext = context(compose())
        let preflight = Task { await coordinator.request(instruction: "Draft this email", context: initialContext) }
        await eventually { initialRefresh.started }
        expect(center.activeCount == 1 && center.selectedActivity?.detail == "Reading the current email", "Explicit work is visible before the initial bridge refresh")
        coordinator.stop()
        await eventually { initialRefresh.cancelled }
        expect(center.activeCount == 0, "Stop removes an owned initial-refresh activity immediately")
        initialRefresh.release(initialContext)
        let stopped = await preflight.value
        expect(stopped == .cancelled && model.calls.isEmpty && cards.offered.isEmpty, "Stop during initial refresh prevents model work and publication")

        reset()
        let firstRefresh = CoordinatorHold<LiveContext?>()
        let secondRefresh = CoordinatorHold<LiveContext?>()
        let oldContext = context(compose(subject: "First request"))
        let newContext = context(compose(subject: "Second request"))
        browser.current = newContext
        browser.handler = {
            switch browser.refreshes {
            case 1: return await firstRefresh.wait()
            case 2: return await secondRefresh.wait()
            default: return newContext
            }
        }
        let oldRequest = Task { await coordinator.request(instruction: "Draft first email", context: oldContext) }
        await eventually { firstRefresh.started }
        let newRequest = Task { await coordinator.request(instruction: "Draft second email", context: newContext) }
        await eventually { secondRefresh.started && firstRefresh.cancelled }
        expect(center.activeCount == 1, "Supersession immediately removes the old owned initial-refresh activity")
        firstRefresh.release(oldContext)
        let oldResult = await oldRequest.value
        expect(oldResult == .cancelled && model.calls.isEmpty, "Superseded initial refresh cannot launch an old model request")
        expect(center.activeCount == 1, "Old request cleanup preserves the newer initial refresh owner")
        secondRefresh.release(newContext)
        guard case .ready = await newRequest.value else { fatalError("Newest refresh should draft") }
        expect(cards.offered.count == 1 && model.calls[0].prompt.contains("Second request"), "Only the newest refreshed email publishes")

        reset()
        browser.emailComposeUnavailableReason = "Reload the Holmes browser extension to read email compose fields."
        browser.current = nil
        let unavailable = await coordinator.request(instruction: "Can you draft this email?", context: LiveContext(source: .none, confidence: .inferred, app: "Chrome"))
        expect(unavailable == .needsContext(browser.emailComposeUnavailableReason!), "Old-extension failure preserves its actionable reason")
        expect(center.completion?.outcome == .failure && model.calls.isEmpty, "Unavailable compose context finishes visibly without model work")

        reset()
        let absent = LiveContext(source: .browserExtension, confidence: .exact, app: "Chrome", entities: ["surface": "emailRead"])
        browser.current = absent
        coordinator.observe(absent)
        await pause(1.6)
        expect(model.calls.isEmpty, "Reading email without a literal composer cannot auto-draft")
        let disabled = compose()
        show(disabled)
        AutonomyPolicy.shared.enabled = false
        coordinator.observe(context(disabled))
        await pause(1.6)
        expect(model.calls.isEmpty, "Disabled email-compose policy prevents automatic drafts")
        AutonomyPolicy.shared.enabled = true
        MenuBarManager.shared.isPaused = true
        coordinator.observe(context(disabled))
        await pause(1.6)
        expect(model.calls.isEmpty, "Paused Holmes prevents automatic drafts")

        reset()
        let pausedRefresh = CoordinatorHold<LiveContext?>()
        let pauseContext = context(compose())
        browser.handler = { await pausedRefresh.wait() }
        show(pauseContext.emailCompose!)
        coordinator.observe(pauseContext)
        await eventually { pausedRefresh.started }
        // Permission/policy state can change while a bridge response is pending,
        // without another context observation arriving before it returns.
        MenuBarManager.shared.isPaused = true
        pausedRefresh.release(pauseContext)
        await pause(0.1)
        expect(model.calls.isEmpty, "Pausing during the second read must prevent a newly starting automatic draft")

        // Manual drafting remains available while automatic behavior is paused.
        browser.handler = nil
        browser.current = pauseContext
        let manualWhilePaused = await coordinator.request(instruction: "Draft this email", context: pauseContext)
        guard case .ready = manualWhilePaused else { fatalError("Pause must not disable an explicit drafting request") }
        expect(model.calls.count == 1 && model.calls[0].priority == .agent, "Paused manual requests retain explicit model priority")

        reset()
        let oldDebounceRead = CoordinatorHold<LiveContext?>()
        let newDebounceRead = CoordinatorHold<LiveContext?>()
        let debounceOld = compose(subject: "Old held header")
        let debounceNew = compose(identity: debounceOld.identity, subject: "New held header")
        browser.handler = {
            switch browser.refreshes {
            case 1: return await oldDebounceRead.wait()
            case 2: return await newDebounceRead.wait()
            default: return context(debounceNew)
            }
        }
        show(debounceOld)
        coordinator.observe(context(debounceOld))
        await eventually { oldDebounceRead.started }
        show(debounceNew)
        coordinator.observe(context(debounceNew))
        await eventually { oldDebounceRead.cancelled && newDebounceRead.started }
        oldDebounceRead.release(context(debounceOld))
        await pause(0.05)
        expect(model.calls.isEmpty, "A replaced debounce response cannot claim the old headers")
        newDebounceRead.release(context(debounceNew))
        await eventually { cards.offered.count == 1 }
        expect(model.calls.count == 1 && model.calls[0].prompt.contains("New held header"), "Old refresh cleanup cannot clear the replacement debounce owner")

        reset()
        let autoReading = CoordinatorHold<LiveContext?>()
        let manualReading = CoordinatorHold<LiveContext?>()
        let preemptContext = context(compose())
        browser.handler = {
            switch browser.refreshes {
            case 1: return await autoReading.wait()
            case 2: return await manualReading.wait()
            default: return preemptContext
            }
        }
        show(preemptContext.emailCompose!)
        coordinator.observe(preemptContext)
        await eventually { autoReading.started }
        let preempting = Task { await coordinator.request(instruction: "Draft this email", context: preemptContext) }
        await eventually { manualReading.started && autoReading.cancelled }
        autoReading.release(preemptContext)
        await pause(0.05)
        expect(model.calls.isEmpty && center.activeCount == 1, "Manual preemption cancels held automatic refresh while preserving its own reading activity")
        manualReading.release(preemptContext)
        guard case .ready = await preempting.value else { fatalError("Explicit request must survive an old debounce callback") }
        expect(cards.offered.count == 1 && cards.offered[0].prioritized, "Only the manual request publishes after held-refresh preemption")

        reset()
        let disabledReading = CoordinatorHold<LiveContext?>()
        let disableContext = context(compose())
        browser.handler = { await disabledReading.wait() }
        show(disableContext.emailCompose!)
        coordinator.observe(disableContext)
        await eventually { disabledReading.started }
        AutonomyPolicy.shared.enabled = false
        disabledReading.release(disableContext)
        await pause(0.1)
        expect(model.calls.isEmpty, "Disabling email drafts while refresh is pending blocks generation after it returns")

        reset()
        let noOrigin = compose(identity: "")
        show(noOrigin)
        coordinator.observe(context(noOrigin))
        await pause(1.6)
        expect(model.calls.isEmpty, "A compose reading without an origin identity cannot trigger an automatic draft")

        reset()
        let inheritedRefresh = CoordinatorHold<LiveContext?>()
        let inheritedContext = context(compose())
        browser.handler = { await inheritedRefresh.wait() }
        let parentID = center.begin(title: "Parent voice request")
        var parentCancelled = false
        center.setCancellationHandler(parentID) { parentCancelled = true }
        let inherited = Task {
            await WorkActivityScope.$id.withValue(parentID) {
                await coordinator.request(instruction: "Draft this email", context: inheritedContext)
            }
        }
        await eventually { inheritedRefresh.started }
        coordinator.stop()
        await eventually { inheritedRefresh.cancelled }
        expect(center.isActive(parentID) && !parentCancelled, "Coordinator stop must leave an inherited owner's lifecycle to its caller")
        inheritedRefresh.release(inheritedContext)
        let inheritedResult = await inherited.value
        expect(inheritedResult == .cancelled && center.isActive(parentID), "Inherited initial refresh cancellation cannot finish the caller")
        center.cancel(parentID)
        expect(parentCancelled, "Coordinator never replaces or removes an inherited Stop handler")

        reset()
        let beforeCancelledEntry = CoordinatorHold<Void>()
        let cancelledEntry = Task {
            await beforeCancelledEntry.wait()
            return await coordinator.request(instruction: "Draft an old email", context: context(compose()))
        }
        await eventually { beforeCancelledEntry.started }
        cancelledEntry.cancel()
        let currentModel = CoordinatorHold<String>()
        let currentContext = context(compose())
        browser.current = currentContext
        model.handler = { _ in await currentModel.wait() }
        let currentEntry = Task { await coordinator.request(instruction: "Draft this email", context: currentContext) }
        await eventually { currentModel.started }
        let currentOwner = center.selectedActivity?.id
        beforeCancelledEntry.release(())
        let cancelledEntryResult = await cancelledEntry.value
        expect(cancelledEntryResult == .cancelled && center.selectedActivity?.id == currentOwner,
               "A previously cancelled caller cannot supersede the currently running request")
        expect(!currentModel.cancelled, "Cancelled entry cannot cancel another request's nested model await")
        currentModel.release(#"{"body":"The current email draft"}"#)
        guard case .ready = await currentEntry.value else { fatalError("Current entry must survive cancelled stale entry") }

        coordinator.stop()
        center.invalidateAll()
        print("Passed \(checks) production email coordinator routing and debounce checks")
    }

    @MainActor private static func reset() {
        EmailDraftCoordinator.shared.stop()
        WorkActivityCenter.shared.invalidateAll()
        EmailDraftCoordinator.shared.start()
        BrowserBridge.shared.handler = nil
        BrowserBridge.shared.current = nil
        BrowserBridge.shared.emailComposeUnavailableReason = nil
        BrowserBridge.shared.refreshes = 0
        BrowserBridge.shared.insertions = 0
        OllamaClient.shared.handler = nil
        OllamaClient.shared.calls = []
        OllamaConfig.isConfigured = true
        PlaybookEngine.shared.offered = []
        MenuBarManager.shared.isPaused = false
        AutonomyPolicy.shared.enabled = true
    }
    @MainActor private static func show(_ snapshot: EmailComposeSnapshot) {
        let current = context(snapshot)
        HolmesAgent.shared.live = current
        BrowserBridge.shared.current = current
    }
    private static func context(_ snapshot: EmailComposeSnapshot) -> LiveContext {
        LiveContext(source: .browserExtension, confidence: .exact, app: "Chrome",
                    entities: ["surface": ContextSurface.emailCompose.rawValue],
                    bodyText: snapshot.body, capturedAt: snapshot.capturedAt, emailCompose: snapshot)
    }
    private static func compose(identity: String = UUID().uuidString, subject: String = "I'm gonna be late", body: String = "") -> EmailComposeSnapshot {
        EmailComposeSnapshot(source: .browser, identity: identity, provider: "gmail", app: "Chrome",
                             recipients: ["jamie@example.com"], cc: [], bcc: [], subject: subject, body: body,
                             bodyReadable: true, bodyIsEmpty: body.isEmpty, capturedAt: Date())
    }
    @MainActor private static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for production coordinator transition")
    }
    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
