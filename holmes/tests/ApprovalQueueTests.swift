import Foundation

@main
struct ApprovalQueueTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func label(_ decision: AgentDecision?) -> String {
            switch decision {
            case .approved(let text)?: return "approved:\(text)"
            case .dismissed?: return "dismissed"
            case .timedOut?: return "timedOut"
            case nil: return "pending"
            }
        }

        // Two overlapping approvals: the second must queue, not dismiss the first.
        let queue = ApprovalQueue<String>()
        var shown: [String?] = []
        queue.onPresent = { shown.append($0) }
        var firstDecision: AgentDecision?
        var secondDecision: AgentDecision?
        let firstID = UUID(), secondID = UUID()
        let first = Task { @MainActor in
            firstDecision = await queue.decide(id: firstID, item: "first run", timeout: nil)
        }
        try await eventually { queue.currentID == firstID }
        let second = Task { @MainActor in
            secondDecision = await queue.decide(id: secondID, item: "second run", timeout: nil)
        }
        try await eventually { queue.queuedCount == 1 }
        expect(firstDecision == nil, "A new approval must not resolve the pending one (it used to read as declined)")
        expect(queue.currentItem == "first run" && shown == ["first run"], "The first card stays on screen while the second waits")
        queue.resolveCurrent(.approved(text: "ok"))
        await first.value
        expect(label(firstDecision) == "approved:ok", "The first run receives the user's actual answer")
        expect(queue.currentItem == "second run" && shown.last == "second run", "The next approval is shown after the current resolves")
        queue.resolveCurrent(.dismissed)
        await second.value
        expect(label(secondDecision) == "dismissed" && queue.isIdle && shown.last! == nil,
               "Resolving the last approval hides the card")

        // Cancellation removes only the cancelled task's card.
        var keptDecision: AgentDecision?
        let keptID = UUID(), queuedID = UUID(), showingID = UUID()
        let kept = Task { @MainActor in keptDecision = await queue.decide(id: keptID, item: "kept", timeout: nil) }
        try await eventually { queue.currentID == keptID }
        let queuedTask = Task { @MainActor in await queue.decide(id: queuedID, item: "queued then cancelled", timeout: nil) }
        try await eventually { queue.queuedCount == 1 }
        queuedTask.cancel()
        let queuedValue = await queuedTask.value
        expect(label(queuedValue) == "dismissed", "A cancelled queued approval resolves dismissed")
        try await eventually { queue.queuedCount == 0 }
        expect(queue.currentID == keptID && keptDecision == nil, "Cancelling a queued card leaves the showing card alone")
        queue.resolveCurrent(.approved(text: ""))
        await kept.value
        let showingTask = Task { @MainActor in await queue.decide(id: showingID, item: "showing then cancelled", timeout: nil) }
        try await eventually { queue.currentID == showingID }
        showingTask.cancel()
        let showingValue = await showingTask.value
        expect(label(showingValue) == "dismissed", "A cancelled showing approval resolves dismissed")
        try await eventually { queue.isIdle }
        expect(shown.last! == nil, "Cancelling the showing card hides it")
        let alreadyCancelled = Task { @MainActor in await queue.decide(id: UUID(), item: "never", timeout: nil) }
        alreadyCancelled.cancel()
        let alreadyCancelledValue = await alreadyCancelled.value
        expect(label(alreadyCancelledValue) == "dismissed" && queue.isIdle, "An already cancelled request never shows")

        // Unattended deadline: an autonomous approval nobody answers times out,
        // even while it waits behind a user initiated card with no deadline.
        var timedOutItems: [String] = []
        queue.onTimeout = { timedOutItems.append($0) }
        var userDecision: AgentDecision?
        let userID = UUID()
        let user = Task { @MainActor in userDecision = await queue.decide(id: userID, item: "user", timeout: nil) }
        try await eventually { queue.currentID == userID }
        let started = Date()
        let unattended = Task { @MainActor in
            await ApprovalScope.$unattendedTimeout.withValue(0.15) {
                await queue.decide(id: UUID(), item: "playbook", timeout: ApprovalScope.unattendedTimeout)
            }
        }
        let unattendedDecision = await unattended.value
        let waited = Date().timeIntervalSince(started)
        expect(label(unattendedDecision) == "timedOut" && waited >= 0.1 && waited < 5,
               "An unattended approval resolves timedOut at its deadline (took \(waited)s)")
        expect(timedOutItems == ["playbook"], "A timeout reports which approval expired for the status line")
        expect(queue.currentID == userID && userDecision == nil, "A user initiated approval keeps waiting without a deadline")
        let showingUnattended = Task { @MainActor in await queue.decide(id: UUID(), item: "second playbook", timeout: 0.1) }
        queue.resolveCurrent(.approved(text: "user ok"))
        await user.value
        expect(label(userDecision) == "approved:user ok", "The user card still resolves normally")
        let showingUnattendedValue = await showingUnattended.value
        expect(label(showingUnattendedValue) == "timedOut" && queue.isIdle,
               "A showing unattended approval times out and hides its card")
        expect(ApprovalScope.defaultUnattendedTimeout == 120, "Autonomous approvals default to a 120 second deadline")

        // One shared card: direct proposals and queued approvals.
        struct Card { let id = UUID(); let name: String }
        let cardQueue = ApprovalQueue<Card>()
        let arbiter = ApprovalCardArbiter(queue: cardQueue, id: { $0.id })
        var onScreen: [String] = []
        var hides = 0
        arbiter.show = { onScreen.append($0.name) }
        arbiter.hide = { hides += 1 }

        // Scenario 1: a direct proposal over a user approval (no deadline).
        let userCard = Card(name: "user approval")
        var userCardDecision: AgentDecision?
        let userCardTask = Task { @MainActor in
            userCardDecision = await cardQueue.decide(id: userCard.id, item: userCard, timeout: nil)
        }
        try await eventually { arbiter.showingApprovalID == userCard.id }
        let meeting = Card(name: "meeting join")
        arbiter.proposeDirect(meeting)
        expect(onScreen.last == "meeting join" && arbiter.showingApprovalID == nil,
               "A direct proposal takes the card and parks the approval")
        arbiter.directClosed()
        expect(onScreen.last == "user approval" && arbiter.showingApprovalID == userCard.id,
               "When the direct card closes, the parked approval is shown again instead of hanging")
        cardQueue.resolveCurrent(.approved(text: "yes"))
        await userCardTask.value
        expect(label(userCardDecision) == "approved:yes" && hides == 1 && arbiter.showing == .none,
               "The re shown approval still resolves its run and closes the card")

        // Scenario 2: a playbook approval times out while the user looks at a direct card.
        let commandResult = Card(name: "command bar result")
        arbiter.proposeDirect(commandResult)
        let playbookCard = Card(name: "playbook approval")
        let hidesBeforeTimeout = hides
        let timedOutCard = await cardQueue.decide(id: playbookCard.id, item: playbookCard, timeout: 0.1)
        expect(label(timedOutCard) == "timedOut", "The parked playbook approval still times out")
        expect(hides == hidesBeforeTimeout && onScreen.last == "command bar result" && arbiter.isShowingDirect,
               "A timeout never closes a direct card the user is looking at")
        arbiter.directClosed()
        expect(arbiter.showing == .none && onScreen.last == "command bar result",
               "Closing the direct card afterwards shows nothing stale")

        // Scenario 3: a queued playbook approval behind a showing user approval times out.
        let front = Card(name: "front")
        let frontTask = Task { @MainActor in await cardQueue.decide(id: front.id, item: front, timeout: nil) }
        try await eventually { arbiter.showingApprovalID == front.id }
        let hidesBeforeQueuedTimeout = hides
        let behind = Card(name: "behind")
        let behindDecision = await cardQueue.decide(id: behind.id, item: behind, timeout: 0.1)
        expect(label(behindDecision) == "timedOut" && hides == hidesBeforeQueuedTimeout
               && arbiter.showingApprovalID == front.id,
               "A queued approval timing out leaves the showing approval on screen")
        cardQueue.resolveCurrent(.dismissed)
        _ = await frontTask.value

        // A timed out approval inside a tool call is reported as a timeout, not a decline.
        let tracked = await ApprovalTimeoutTracking.run { () -> String in
            let answer = await ApprovalQueue<String>().decide(id: UUID(), item: "tool approval", timeout: 0.05)
            if case .timedOut = answer { ApprovalTimeoutTracking.flag?.markTimedOut() }
            return label(answer)
        }
        expect(tracked.result == "timedOut" && tracked.timedOut, "A timeout inside a tracked tool call is recorded")
        let declinedQueue = ApprovalQueue<String>()
        let declined = await ApprovalTimeoutTracking.run { () -> String in
            let pending = Task { @MainActor in await declinedQueue.decide(id: UUID(), item: "declined", timeout: nil) }
            try? await eventually { !declinedQueue.isIdle }
            declinedQueue.resolveCurrent(.dismissed)
            return label(await pending.value)
        }
        expect(declined.result == "dismissed" && !declined.timedOut, "A real decline is not reported as a timeout")
        expect(ApprovalTimeoutTracking.flag == nil, "Tracking is scoped to the tool call")

        print("Passed \(checks) approval queue, cancellation and unattended timeout checks")
    }

    @MainActor static func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Timed out waiting for the approval queue")
    }
}
