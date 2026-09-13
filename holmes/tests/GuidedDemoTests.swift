import Foundation

@main
struct GuidedDemoTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let suite = "holmes-guided-demo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func settle(_ model: GuidedDemoModel) async {
            for _ in 0..<1000 {
                if model.runningCase == nil { return }
                await Task.yield()
            }
            preconditionFailure("Example did not settle")
        }

        var ready = false
        var readinessChecks = 0
        var launches = 0
        var prompts: [(system: String, user: String)] = []
        var launchResult = AppLaunchResult(appName: "Calculator", message: "Opened Calculator.", succeeded: true)
        var response = "A real generated result"
        var completionError: Error?
        let deps = GuidedDemoModel.Dependencies(
            isModelReady: { readinessChecks += 1; return ready },
            modelNotReadyMessage: { "The sample model isn't downloaded." },
            launchCalculator: { launches += 1; return launchResult },
            complete: { system, user in
                prompts.append((system, user))
                if let completionError { throw completionError }
                return response
            })

        expect(!GuidedDemoModel.shouldPresent(defaults: defaults), "Tour must wait for onboarding")
        defaults.set(true, forKey: GuidedDemoModel.onboardingCompletedKey)
        expect(GuidedDemoModel.shouldPresent(defaults: defaults), "Finished onboarding schedules the unseen tour")
        GuidedDemoModel.markPresented(defaults: defaults)
        expect(!GuidedDemoModel.shouldPresent(defaults: defaults), "The presented tour must not auto-open twice")
        defaults.set(false, forKey: GuidedDemoModel.onboardingCompletedKey)
        defaults.set(false, forKey: GuidedDemoModel.hasSeenDemoKey)
        expect(!GuidedDemoModel.shouldPresent(defaults: defaults), "An unseen tour still requires onboarding")

        let model = GuidedDemoModel(defaults: defaults, dependencies: deps)
        expect(model.completedCount == 0 && model.selectedCase == .openCalculator, "Fresh progress starts at Calculator")
        model.updateOutput("Typed text", for: .draftReply)
        expect(model.outputs[.draftReply] == nil && model.completedCount == 0, "Text edits cannot invent a completed run")
        model.runSelected()
        model.runSelected()
        await settle(model)
        expect(launches == 1, "Repeated Run clicks must launch once")
        expect(readinessChecks == 0 && prompts.isEmpty, "Native launch must not check or call the model")
        expect(model.outputs[.openCalculator] == "Opened Calculator.", "Native launch reports its real result")
        expect(model.completedCases == [.openCalculator], "Only the successful case is completed")

        model.select(.summarizeNotes)
        model.runSelected()
        expect(model.runningCase == nil && prompts.isEmpty, "A missing model must not start a generation")
        expect(model.errors[.summarizeNotes]?.contains("isn't downloaded") == true,
               "Missing prerequisites need their actual problem")
        expect(model.completedCount == 1 && model.outputs[.summarizeNotes] == nil,
               "Missing prerequisites must not produce a success or placeholder")

        ready = true
        response = "  • The community room is reserved.\n• Maya and Leo own setup.\n• Send the reminder Thursday.  "
        model.runSelected()
        await settle(model)
        expect(prompts.count == 1, "Summary must use the real completion dependency")
        expect(prompts[0].user == GuidedDemoCase.summarizeNotes.prompt + "\n\n" + GuidedDemoCase.summarizeNotes.sampleText,
               "Summary input must be exactly the visible synthetic sample and instruction")
        expect(prompts[0].system.contains("fictional sample"), "Summary system prompt limits grounding to supplied sample")
        expect(model.outputs[.summarizeNotes] == response.trimmingCharacters(in: .whitespacesAndNewlines),
               "Show the generated result, not a canned example")
        expect(model.errors[.summarizeNotes] == nil && model.completedCount == 2, "Successful retry clears the error and saves progress")

        model.select(.draftReply)
        response = "I can help at 9:30 and bring name tags. How many do we need?"
        model.runSelected()
        await settle(model)
        expect(prompts.count == 2 && launches == 1, "Reply drafting only calls the text completion")
        expect(prompts[1].user == GuidedDemoCase.draftReply.prompt + "\n\n" + GuidedDemoCase.draftReply.sampleText,
               "Reply input contains only the supplied synthetic message and notes")
        expect(prompts[1].system.contains("Return only the draft") && prompts[1].system.contains("sent"),
               "Reply generation is explicitly a draft")
        expect(model.outputs[.draftReply] == response && model.completedCount == 3, "Reply completes when real nonempty text returns")
        model.updateOutput("Edited draft", for: .draftReply)
        expect(model.outputs[.draftReply] == "Edited draft" && model.completedCount == 3,
               "Editing a draft changes only its visible text")

        let restored = GuidedDemoModel(defaults: defaults, dependencies: deps)
        expect(restored.completedCases == Set(GuidedDemoCase.allCases), "Every case completion survives relaunch")
        expect(restored.outputs.isEmpty && restored.errors.isEmpty, "Only progress persists, never draft text")
        defaults.set(["openCalculator", "obsoleteCase", "openCalculator"], forKey: GuidedDemoModel.completedCasesKey)
        let migrated = GuidedDemoModel(defaults: defaults, dependencies: deps)
        expect(migrated.completedCases == [.openCalculator], "Unknown saved case IDs and duplicates are harmless")

        // Isolate failure paths so they cannot borrow earlier successful progress.
        defaults.removeObject(forKey: GuidedDemoModel.completedCasesKey)
        let failure = GuidedDemoModel(defaults: defaults, dependencies: deps)
        launchResult = AppLaunchResult(appName: "Calculator", message: "macOS refused to open Calculator.", succeeded: false)
        failure.runSelected()
        await settle(failure)
        expect(failure.errors[.openCalculator] == launchResult.message && failure.completedCount == 0,
               "Native launch failure must remain a failure")
        expect(failure.outputs[.openCalculator] == nil, "A failed launch must not show a successful result")
        failure.select(.draftReply)
        response = " \n\t "
        failure.runSelected()
        await settle(failure)
        expect(failure.errors[.draftReply]?.contains("empty response") == true && failure.completedCount == 0,
               "An empty model answer does not complete the example")
        completionError = NSError(domain: "demo-tests", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The model server disconnected."])
        failure.runSelected()
        await settle(failure)
        expect(failure.errors[.draftReply] == "The model server disconnected." && failure.completedCount == 0,
               "Model errors stay visible and do not count as success")
        expect(defaults.stringArray(forKey: GuidedDemoModel.completedCasesKey) == nil,
               "Failures do not write completion flags")

        // Hold completions past cancellation, then release them out of order.
        // These closures deliberately ignore task cancellation like a slow native callback.
        var pending: [CheckedContinuation<String, Error>] = []
        var returns = 0
        let delayed = GuidedDemoModel(defaults: defaults, dependencies: .init(
            isModelReady: { true }, modelNotReadyMessage: { "unavailable" },
            launchCalculator: { AppLaunchResult(appName: "Calculator", message: "Opened Calculator.", succeeded: true) },
            complete: { _, _ in
                let text = try await withCheckedThrowingContinuation { pending.append($0) }
                returns += 1
                return text
            }))
        func awaitPending(_ count: Int) async {
            for _ in 0..<1000 {
                if pending.count == count { return }
                await Task.yield()
            }
            preconditionFailure("Expected \(count) pending completions")
        }
        func awaitReturns(_ count: Int) async {
            for _ in 0..<1000 {
                if returns == count { break }
                await Task.yield()
            }
            precondition(returns == count, "Held response did not return")
            // The task's post-await state update may be scheduled next.
            for _ in 0..<10 { await Task.yield() }
        }
        delayed.select(.summarizeNotes)
        delayed.runSelected()
        await awaitPending(1)
        delayed.cancel()
        expect(delayed.runningCase == nil && delayed.completedCount == 0, "Cancel immediately releases the visible run")
        delayed.runSelected()
        await awaitPending(2)
        pending[0].resume(returning: "Old summary")
        await awaitReturns(1)
        expect(delayed.runningCase == .summarizeNotes && delayed.outputs[.summarizeNotes] == nil,
               "A cancelled completion cannot finish or overwrite a newer run")
        pending[1].resume(returning: "New summary")
        await settle(delayed)
        expect(delayed.outputs[.summarizeNotes] == "New summary" && delayed.completedCount == 1,
               "A retry can complete after the old request is cancelled")

        delayed.select(.draftReply)
        delayed.runSelected()
        await awaitPending(3)
        delayed.select(.openCalculator)
        pending[2].resume(returning: "Reply after navigation")
        await awaitReturns(3)
        expect(delayed.outputs[.draftReply] == nil && !delayed.completedCases.contains(.draftReply),
               "Changing examples ignores a late result")
        delayed.select(.draftReply)
        delayed.runSelected()
        await awaitPending(4)
        delayed.cancel() // The window calls this on dismissal.
        pending[3].resume(throwing: NSError(domain: "late-error", code: 1))
        for _ in 0..<20 { await Task.yield() }
        expect(delayed.errors[.draftReply] == nil && delayed.outputs[.draftReply] == nil,
               "Dismissing the tour ignores a late failure as well as a late success")

        print("GuidedDemoTests: \(checks) checks passed")
    }
}
