// Used ONLY by render-ui-previews.sh, which copies this file over AppDelegate
// in a temporary project. Never add it to the production Xcode target.
import AppKit
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var report: [[String: Any]] = []
    private var outputDirectory: URL!
    private let glassMode = ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_GLASS"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_OUTPUT"],
              Bundle.main.bundleIdentifier?.hasPrefix("com.zeroprompt.holmes.ui-preview.") == true else {
            fputs("Refusing preview launch without an isolated bundle and output directory.\n", stderr)
            exit(2)
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        // Fixture values live in the process's argument domain, above the unique
        // preview application domain. Nothing is saved to the user's Holmes prefs.
        UserDefaults.standard.setVolatileDomain([
            "ollama.host": "http://127.0.0.1:11434",
            "ollama.model": "qwen3-vl:4b-instruct",
            "ollama.autoStartServer": false,
            "ollama.numCtx": 32768,
            "ollama.keepAlive": "10m",
            "ollama.thinkingEnabled": false,
            "com.grain.holmes.autonomy.masterEnabled": false,
            "com.grain.holmes.computerUse.enabled": false
        ], forName: UserDefaults.argumentDomain)
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try registerFonts()
        } catch { fail(error) }
        Task { @MainActor in
            do {
                try await renderFixtures()
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: outputDirectory.appendingPathComponent("previews.json"))
                print("UI previews saved to \(outputDirectory.path)")
                NSApp.terminate(nil)
            } catch { fail(error) }
        }
    }

    // No production start/stop handlers, menus, hotkeys, microphone, screen
    // capture, agent, calendar, MCP, or Ollama monitor are initialized here.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerFonts() throws {
        var rows: [[String: Any]] = []
        if let resourceURL = Bundle.main.resourceURL,
           let files = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil) {
            for case let url as URL in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                var error: Unmanaged<CFError>?
                let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                for descriptor in descriptors {
                    let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? "unknown"
                    rows.append(["file": url.lastPathComponent, "name": name,
                                 "registered": registered, "available": NSFont(name: name, size: 14) != nil])
                }
                if let error { _ = error.takeRetainedValue() }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("fonts.json"))
        print("Preview fonts: \(rows.count) faces, \(rows.filter { $0["available"] as? Bool == true }.count) available")
    }

    private func renderFixtures() async throws {
        if ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_WORK_ONLY"] == "1" {
            await verifyAutonomyOwnership()
            await verifyPerceptionLifecycle()
            try await verifyConfirmationAndTypingCancellation()
            try await renderEmailAndWorkFixtures()
            return
        }
        if ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_DEMO_ONLY"] == "1" {
            try await renderDemoFixtures()
            return
        }
        if glassMode {
            try await render("glass-surfaces", size: CGSize(width: 720, height: 420), view:
                ZStack {
                    AppleGlassBackground(cornerRadius: 18)
                    VStack(alignment: .leading, spacing: 24) {
                        Text("holmes").font(NoirFonts.brand(size: 36))
                        Text("Window glass").font(NoirFonts.title())
                        Text("The colored backdrop should remain visible through every surface.")
                            .font(NoirFonts.body())
                        HStack(spacing: 20) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Approval card").font(NoirFonts.title())
                                    Text("Readable text over frosted glass.").font(NoirFonts.body())
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .padding(16)
                            }
                            ZStack {
                                HeavyGlassBackground(cornerRadius: 12)
                                Text("Elevated glass").font(NoirFonts.title())
                            }
                            .frame(maxWidth: .infinity, minHeight: 152)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(NoirColors.textPrimary)
                    .padding(24)
                })
        }
        // Viewing this pane only synchronizes fields; no refresh/download button
        // is invoked. The disconnected initial status is intentional fixture data.
        try await render("settings-local-model", size: CGSize(width: 680, height: 620), view: SettingsView())
        try await render("settings-local-model-minimum", size: CGSize(width: 640, height: 520), view: SettingsView())
        if ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_EXPAND_ADVANCED"] == "1" {
            try await render("settings-advanced-top", size: CGSize(width: 680, height: 620),
                             view: SettingsView(), scrollOffset: 340)
            try await render("settings-advanced-bottom", size: CGSize(width: 680, height: 620),
                             view: SettingsView(), scrollOffset: 780)
        }
        if !glassMode {
            try await render("local-model-compact", size: CGSize(width: 450, height: 460),
                             view: LocalModelSettingsView(compact: true))
        }

        let bus = ConfirmationBus.shared
        // Assign directly: propose()/proposeDraft() would show real controller
        // windows. No handler is installed and no action is approved or executed.
        bus.pendingAction = PendingAction(
            title: "Review the next step", preview: "Open the selected project in your editor.\n\nThis is fixture copy for visual review; no action will run.",
            appName: "Your Mac", actionType: .agentToolCall)
        try await render("review-action", size: CGSize(width: 420, height: 410),
                         view: ScrollView { ConfirmationView() })
        bus.pendingAction = nil
        bus.pendingDraft = ProactiveDraft(
            playbookId: "preview-reply", kind: .chatReply, title: "Reply to Alex",
            body: "sounds good — I’ll share the updated design after checking the layout and text on a few window sizes.",
            contextSummary: "Messages · conversation with Alex", target: .clipboard)
        try await render("review-draft", size: CGSize(width: 420, height: 520),
                         view: ScrollView { ConfirmationView() })
        bus.pendingDraft = nil
        try await renderEmailAndWorkFixtures()

        let incoming = ReplyComposer.IncomingMessage(surface: ReplyComposer.surfaceIMessage,
            sender: "Alex", text: "hey, what is holmes?", threadID: "preview-only", app: "Messages")
        let memory = MemoryEvent(id: 9001, date: Date().addingTimeInterval(-3600), kind: "context",
            app: "Browser", windowTitle: "holmes project", activity: "reading",
            summary: "Reading the holmes project overview", detail: "Synthetic preview fixture",
            source: "browserExtension", confidence: "exact", site: "github.com",
            entitiesJSON: "{\"repo\":\"tryholmes/holmes-local\"}")
        let reply = ReplyComposer.DraftedReply(
            body: "it’s a local macOS assistant that understands what’s on your screen and prepares useful next steps for you to review.",
            groundedIn: [memory], background: [], confidence: .exact,
            recallHits: [MemoryStore.RecallHit(event: memory, score: 0.9, matchedOn: "project entity")], topics: ["holmes"])
        try await render("reply-ready", size: CGSize(width: 420, height: 540),
                         view: ScrollView { ReplyReadyCard(draft: reply, incoming: incoming) })
        let unsourced = ReplyComposer.DraftedReply(body: "let me check and get back to you", groundedIn: [],
            background: [], confidence: .inferred, recallHits: [], topics: ["holmes"])
        try await render("reply-unsourced", size: CGSize(width: 420, height: 540),
                         view: ScrollView { ReplyReadyCard(draft: unsourced, incoming: incoming) })

        // The notch intentionally stays black to match the physical cutout.
        // Its offscreen geometry previews are independent of desktop glass.
        if glassMode { return }
        let geometry = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 910),
            safeAreaTop: 32, leftAreaWidth: 660, rightAreaWidth: 660)
        let vm = NotchViewModel(geometry: geometry)
        vm.contextLine = "Reviewing the holmes design and checking the next implementation steps"
        vm.contextSymbol = "doc.text"
        vm.taskActive = true
        vm.taskName = "Checking the layout"
        vm.taskPhase = .working
        vm.taskStep = "Checking that the text and controls stay below the camera housing"
        vm.taskProgress = 0.6
        vm.taskIsIndeterminate = false
        vm.open()
        try await render("notch-expanded", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.close()
        try await render("notch-task", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.taskActive = false
        vm.sneakPeek = NotchSneakPeek(show: true, title: "Reading a document", subtitle: vm.contextLine, symbol: "doc.text")
        try await render("notch-context", size: geometry.windowSize, view: NotchView(vm: vm))
    }

    /// Review and activity fixtures use literal sample data. No coordinator,
    /// browser, model, microphone, or insertion method is invoked.
    private func renderEmailAndWorkFixtures() async throws {
        let bus = ConfirmationBus.shared
        let compose = EmailComposeSnapshot(
            source: .browser, identity: "preview:gmail-compose", provider: "gmail", app: "Google Chrome",
            recipients: ["boss@gmail.com"], cc: [], bcc: [], subject: "Im gonna be late", body: "",
            bodyReadable: true, bodyIsEmpty: true, capturedAt: Date())
        bus.pendingAction = nil
        bus.pendingDraft = ProactiveDraft(
            playbookId: "email-compose", kind: .emailCompose, title: "Draft: Im gonna be late",
            body: "Hi,\n\nI'm running late. I apologize for the delay.",
            contextSummary: "To: boss@gmail.com\nSubject: Im gonna be late\nPrepared from your email and request. Review before inserting.",
            target: .emailCompose(compose))
        try await render("email-review-insert", size: CGSize(width: 420, height: 600),
                         view: ScrollView { ConfirmationView() })
        let replacement = EmailComposeSnapshot(
            source: .accessibility, identity: "preview:mail-compose", provider: "mail", app: "Mail",
            recipients: ["alex@example.com"], cc: [], bcc: [], subject: "Project update", body: "Quick update:",
            bodyReadable: true, bodyIsEmpty: false, capturedAt: Date())
        bus.pendingDraft = ProactiveDraft(
            playbookId: "email-compose", kind: .emailCompose, title: "Draft: Project update",
            body: "Hi Alex,\n\nHere's a quick update on the project. I'll share the next steps once the review is complete.",
            contextSummary: "To: alex@example.com\nSubject: Project update\nReview your changes before replacing the existing body.",
            target: .emailCompose(replacement))
        try await render("email-review-replace", size: CGSize(width: 420, height: 600),
                         view: ScrollView { ConfirmationView() })
        bus.pendingDraft = nil
        if glassMode { return }

        let geometry = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 910),
            safeAreaTop: 32, leftAreaWidth: 660, rightAreaWidth: 660)
        let center = WorkActivityCenter()
        let vm = NotchViewModel(geometry: geometry)
        vm.contextLine = "Writing an email in Gmail — Im gonna be late"
        vm.contextSymbol = "envelope"
        let background = center.begin(title: "Reading screen context", origin: .background)
        center.update(background, phase: .working, detail: "Understanding the current screen")
        let email = center.begin(title: "Drafting your email")
        center.update(email, phase: .queued, detail: "Your request is in line")
        vm.synchronize(with: center)
        try await render("notch-email-queued", size: geometry.windowSize, view: NotchView(vm: vm))
        center.cancel(background)
        center.update(email, phase: .working, detail: "Writing the email body")
        vm.synchronize(with: center)
        try await render("notch-email-working", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.open()
        try await render("notch-email-working-expanded", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.close()
        center.finish(email, outcome: .failure, summary: "Ollama isn't running. Open Settings → Local Model.")
        vm.synchronize(with: center)
        try await render("notch-email-error", size: geometry.windowSize, view: NotchView(vm: vm))
        let cancelled = center.begin(title: "Drafting your email")
        center.cancel(cancelled, summary: "Email drafting stopped.")
        vm.synchronize(with: center)
        try await render("notch-email-cancelled", size: geometry.windowSize, view: NotchView(vm: vm))
        let ready = center.begin(title: "Drafting your email")
        center.finish(ready, outcome: .success, summary: "Your email draft is ready to review.")
        vm.synchronize(with: center)
        try await render("notch-email-ready", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.hideSneakPeek()
    }

    /// Exercise the production runner's early exit/cancellation seams while
    /// autonomy is disabled. Every plan is inert; no permission or tool runs.
    private func verifyAutonomyOwnership() async {
        precondition(!AutonomyPolicy.shared.masterEnabled)
        let center = WorkActivityCenter.shared
        let runner = AutonomousActionRunner.shared
        let empty = ActionPlan(goal: "Preview empty plan", steps: [], knownAddresses: [], rationale: "")
        let inert = ActionPlan(goal: "Preview only — never execute",
                               steps: [.init(action: "preview_only", input: [:], backend: "app",
                                             reversible: true, summary: "Inert preview step")],
                               knownAddresses: [], rationale: "")
        let emptyResult = await runner.run(empty, playbookId: "preview", level: .auto)
        precondition(!emptyResult.succeeded && center.activeCount == 0 && center.completion?.outcome == .failure)
        let draftResult = await runner.run(inert, playbookId: "preview", level: .draft)
        precondition(!draftResult.succeeded && center.activeCount == 0 && !runner.isRunning)
        let disabled = await runner.run(inert, playbookId: "preview", level: .auto)
        precondition(!disabled.succeeded && center.activeCount == 0)
        let parent = center.begin(title: "A parent preparing a playbook")
        let inherited = await WorkActivityScope.$id.withValue(parent) {
            await runner.run(inert, playbookId: "preview", level: .draft)
        }
        precondition(!inherited.succeeded && center.isActive(parent) && center.activeCount == 1)
        center.cancel(parent)
        let cancelled = Task { @MainActor in await runner.run(inert, playbookId: "preview", level: .draft) }
        cancelled.cancel()
        let stopped = await cancelled.value
        precondition(stopped == .cancelled && center.activeCount == 0 && !runner.isRunning)
        center.invalidateAll()
        print("Passed 5 production autonomous-runner ownership, refusal and cancellation checks")
    }

    /// Calls production cancellation paths in this isolated, nonactivating
    /// process. No decision is approved, and typing stops inside its focus delay.
    private func verifyConfirmationAndTypingCancellation() async throws {
        precondition(NSApp.activationPolicy() == .prohibited)
        let currentApp = NSRunningApplication.current
        precondition(currentApp.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        precondition(currentApp.bundleIdentifier?.hasPrefix("com.zeroprompt.holmes.ui-preview.") == true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        let bus = ConfirmationBus.shared
        precondition(bus.pendingAction == nil && bus.pendingDraft == nil && !bus.isShowing)
        let heldAction = PendingAction(title: "Preview cancellation fixture", preview: "No action will run.",
                                       appName: "Isolated preview", actionType: .agentToolCall)
        let cancelledAction = PendingAction(title: "Already stopped preview", preview: "Never show this decision.",
                                            appName: "Isolated preview", actionType: .agentToolCall)
        var heldDecisionResolved = false
        let heldDecision = Task { @MainActor in
            let decision = await bus.decide(heldAction)
            heldDecisionResolved = true
            return decision
        }
        for _ in 0..<100 {
            if bus.pendingAction?.id == heldAction.id { break }
            await Task.yield()
        }
        check(bus.pendingAction?.id == heldAction.id && bus.isShowing && !heldDecisionResolved,
              "The first real approval decision must remain suspended")
        // decide() uses the actual controller; keep its fixture panel offscreen
        // and noninteractive while inspecting the production bus ownership.
        for window in NSApp.windows {
            window.ignoresMouseEvents = true
            window.orderOut(nil)
        }
        let alreadyCancelledDecision = Task { @MainActor in await bus.decide(cancelledAction) }
        alreadyCancelledDecision.cancel()
        if case .dismissed = await alreadyCancelledDecision.value { checks += 1 }
        else { preconditionFailure("An already cancelled decision must be dismissed") }
        check(bus.pendingAction?.id == heldAction.id && bus.isShowing && !heldDecisionResolved,
              "An already cancelled second decision must not dismiss or steal the first")
        bus.dismiss()
        if case .dismissed = await heldDecision.value { checks += 1 }
        else { preconditionFailure("The fixture must dismiss its held decision without approval") }
        check(bus.pendingAction == nil && !bus.isShowing && heldDecisionResolved,
              "Both decision awaiters must finish with no approval left behind")

        let brain = HolmesBrain.shared
        let alreadyCancelledTyping = Task { @MainActor in
            await brain.typeIntoApp(currentApp, text: "Preview fixture: this text must never be typed.")
        }
        alreadyCancelledTyping.cancel()
        check(await alreadyCancelledTyping.value == false,
              "Already cancelled typing must return false before activation or insertion")

        var typingStartedAt: TimeInterval?
        let delayedTyping = Task { @MainActor in
            typingStartedAt = ProcessInfo.processInfo.systemUptime
            return await brain.typeIntoApp(currentApp, text: "Preview fixture: stop during the focus delay.")
        }
        for _ in 0..<100 {
            if typingStartedAt != nil { break }
            await Task.yield()
        }
        guard let startedAt = typingStartedAt else {
            delayedTyping.cancel()
            preconditionFailure("The production typing call never entered its focus delay")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        delayedTyping.cancel()
        let typed = await delayedTyping.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        check(!typed && elapsed < 0.45,
              "Typing cancelled after 50 ms must return false before its 450 ms focus delay completes")
        check(NSApp.activationPolicy() == .prohibited && bus.pendingAction == nil && !bus.isShowing,
              "Cancellation checks must leave the isolated preview nonactivating and the approval bus idle")
        print("Passed \(checks) production confirmation and typing cancellation checks (focus-delay cancellation: \(Int(elapsed * 1000)) ms)")
    }

    /// Hold the actual agent's OCR and model boundaries past stop/restart. The
    /// continuations deliberately ignore cancellation, as Vision can do, so the
    /// generation guards must prevent stale publication and queue cleanup.
    private func verifyPerceptionLifecycle() async {
        @MainActor final class HeldText {
            var calls = 0
            var waiting: [Int: CheckedContinuation<String, Never>] = [:]
            var cancelled: [Int: Bool] = [:]
            func read() async -> String {
                calls += 1
                let call = calls
                let result: String = await withCheckedContinuation { waiting[call] = $0 }
                cancelled[call] = Task.isCancelled
                return result
            }
            func resolve(_ call: Int, _ text: String) {
                precondition(waiting[call] != nil)
                waiting.removeValue(forKey: call)?.resume(returning: text)
            }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func waitFor(_ label: String, _ condition: () -> Bool) async {
            for _ in 0..<100 where !condition() {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            precondition(condition(), label)
        }
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                              bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        func capture(_ app: String, denied: Bool = false) -> CaptureResult {
            CaptureResult(image: denied ? nil : image, appName: app, windowTitle: "",
                          axOverride: denied ? "__NO_SCREEN_ACCESS__" : nil,
                          reading: nil, focused: nil, visionUsable: false)
        }
        let ocr = HeldText()
        let model = HeldText()
        let agent = HolmesAgent(perception: .init(
            recognizeText: { _ in await ocr.read() },
            completeEnrichment: { _, _ in await model.read() },
            canEnrich: { true }, frontmostAppName: { "" }))

        let first = agent.beginPerceptionLifecycle()
        agent.enqueueSnapshot(capture("Old OCR"), lifecycle: first)
        await waitFor("first OCR held") { ocr.calls == 1 }
        agent.enqueueSnapshot(capture("Old pending", denied: true), lifecycle: first)
        await settle()
        precondition(ocr.calls == 1 && agent.isAnalyzing)
        agent.stopPerceptionLifecycle()
        precondition(!agent.isAnalyzing)

        let second = agent.beginPerceptionLifecycle()
        agent.enqueueSnapshot(capture("New OCR"), lifecycle: second)
        await waitFor("new OCR held independently") { ocr.calls == 2 }
        agent.enqueueSnapshot(capture("Current pending", denied: true), lifecycle: second)
        agent.enqueueSnapshot(capture("Stale callback", denied: true), lifecycle: first)
        ocr.resolve(1, "Old screen text")
        await settle()
        precondition(agent.currentContext.appName != "Old OCR" && agent.currentContext.appName != "Old pending")
        precondition(agent.isAnalyzing && ocr.calls == 2, "old cleanup cannot release the current OCR")
        ocr.resolve(2, "")
        await waitFor("current queued snapshot survives old completion") { agent.currentContext.appName == "Current pending" }
        precondition(!agent.isAnalyzing && ocr.calls == 2)
        agent.stopPerceptionLifecycle()
        agent.enqueueSnapshot(capture("Stopped callback", denied: true), lifecycle: second)
        await settle()
        precondition(agent.currentContext.appName == "Current pending")

        let context = LiveContext(source: .accessibility, confidence: .structural,
                                  app: "Lifecycle fixture", headline: "Reading the lifecycle fixture")
        agent.beginPerceptionLifecycle()
        agent.live = context
        agent.enrichLiveContext(context)
        await waitFor("old enrichment held") { model.calls == 1 }
        agent.stopPerceptionLifecycle()
        agent.enrichLiveContext(context)
        await settle()
        precondition(model.calls == 1, "paused agent cannot start enrichment")
        agent.beginPerceptionLifecycle()
        agent.enrichLiveContext(context)
        await waitFor("new enrichment held independently") { model.calls == 2 }
        model.resolve(1, "{\"goal\":\"Stale goal\",\"headline\":\"\",\"lastMessageGist\":\"\"}")
        await settle()
        precondition(model.cancelled[1] == true && agent.deepContext == nil && agent.live.entities["goal"] == nil)
        agent.stopPerceptionLifecycle()
        model.resolve(2, "{\"goal\":\"\",\"headline\":\"\",\"lastMessageGist\":\"\"}")
        await settle()
        precondition(model.cancelled[2] == true && agent.deepContext == nil,
                     "old cleanup cannot orphan the current model task before stop")
        agent.beginPerceptionLifecycle()
        agent.enrichLiveContext(context)
        await waitFor("final enrichment held independently") { model.calls == 3 }
        model.resolve(3, "{\"goal\":\"\",\"headline\":\"\",\"lastMessageGist\":\"\"}")
        await waitFor("current enrichment publishes") { agent.deepContext != nil }
        precondition(agent.currentContext.description == context.headline && agent.live.entities["goal"] == nil)
        agent.stopPerceptionLifecycle()
        precondition(ocr.waiting.isEmpty && model.waiting.isEmpty)
        print("Passed 11 production perception lifecycle, held OCR/model and stale queue checks")
    }

    /// Sample-only fixtures; no native app is launched and no model is called.
    private func renderDemoFixtures() async throws {
        let suite = "holmes.demo-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dependencies = GuidedDemoModel.Dependencies(
            isModelReady: { true }, modelNotReadyMessage: { "Finish model setup to continue." },
            launchCalculator: { AppLaunchResult(appName: "Calculator", message: "Opened Calculator.", succeeded: true) },
            complete: { _, user in
                if user.contains("Sample message from Alex:") {
                    return "Hey Alex, happy to help! I’ll be there at 9:30 on Saturday to set up the tables. I can bring name tags too — how many do we need?"
                }
                return "• Book swap: Saturday, October 17, 10 am–noon in the reserved community room.\n• Maya brings signs and name tags; Leo sets up tables by 9:30 am.\n• Next step: send the volunteer reminder by Thursday."
            })
        let model = GuidedDemoModel(defaults: defaults, dependencies: dependencies)
        try await render("demo-welcome", size: CGSize(width: 760, height: 680),
                         view: GuidedDemoView(model: model, onDone: {}))
        try await render("demo-minimum", size: CGSize(width: 680, height: 600),
                         view: GuidedDemoView(model: model, onDone: {}))
        try await runDemoFixture(model, example: .openCalculator)
        try await render("demo-app-result", size: CGSize(width: 760, height: 680),
                         view: GuidedDemoView(model: model, onDone: {}))
        model.select(.summarizeNotes)
        try await render("demo-model-setup", size: CGSize(width: 680, height: 600),
                         view: GuidedDemoView(model: model, onDone: {}))
        try await runDemoFixture(model, example: .summarizeNotes)
        try await render("demo-summary-result", size: CGSize(width: 760, height: 680),
                         view: GuidedDemoView(model: model, onDone: {}), scrollOffset: 400)
        try await runDemoFixture(model, example: .draftReply)
        try await render("demo-editable-draft", size: CGSize(width: 680, height: 600),
                         view: GuidedDemoView(model: model, onDone: {}), scrollOffset: 620)
        model.updateOutput("", for: .draftReply)
        try await render("demo-empty-draft", size: CGSize(width: 680, height: 600),
                         view: GuidedDemoView(model: model, onDone: {}), scrollOffset: 620)
        model.cancel()
    }

    private func runDemoFixture(_ model: GuidedDemoModel, example: GuidedDemoCase) async throws {
        model.select(example)
        model.runSelected()
        let deadline = Date().addingTimeInterval(2)
        while model.runningCase != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(model.runningCase == nil && model.outputs[example] != nil, "Demo fixture did not finish")
    }

    private func render<V: View>(_ name: String, size: CGSize, view: V,
                                 scrollOffset: CGFloat? = nil) async throws {
        // Default mode keeps the existing offscreen layout/font snapshots.
        // Glass mode needs the WindowServer compositor: an opaque synthetic
        // backdrop covers the entire captured area behind a clear fixture host.
        // Both windows ignore input and cannot activate; no controls are clicked.
        let farEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        var frame = CGRect(x: farEdge + 4096, y: 0, width: size.width, height: size.height)
        let margin: CGFloat = glassMode ? 24 : 0
        if glassMode {
            guard let screen = NSScreen.screens.max(by: {
                $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height
            }), screen.visibleFrame.width >= size.width + margin * 2,
                screen.visibleFrame.height >= size.height + margin * 2 else {
                throw PreviewError.screenTooSmall(name)
            }
            frame.origin = CGPoint(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                                   y: (screen.visibleFrame.midY - size.height / 2).rounded())
        }
        let window = UIPreviewWindow(contentRect: frame,
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = glassMode ? .clear : NSColor(hex: "060606")
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        var backdrop: UIPreviewWindow?
        if glassMode {
            let backing = UIPreviewWindow(contentRect: frame.insetBy(dx: -margin, dy: -margin),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
            backing.isReleasedWhenClosed = false
            backing.ignoresMouseEvents = true
            backing.isOpaque = true
            backing.backgroundColor = .black
            backing.hasShadow = false
            backing.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 10)
            backing.contentView = UIPreviewBackdropView(frame: CGRect(origin: .zero, size: backing.frame.size))
            backing.orderFrontRegardless()
            backdrop = backing
            window.level = NSWindow.Level(rawValue: backing.level.rawValue + 1)
        }
        let host = NSHostingView(rootView:
            ZStack(alignment: .top) {
                if !glassMode { Color(hex: "060606") }
                view
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .preferredColorScheme(.dark))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        windows.append(window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            backdrop?.orderOut(nil)
            backdrop?.contentView = nil
            windows.removeAll { $0 === window }
        }
        window.orderFrontRegardless()
        // Settle SwiftUI onAppear and native subview layout without running a
        // blocking sleep on the main thread.
        try await Task.sleep(for: .milliseconds(glassMode ? 500 : 250))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let scrollOffset, let scroll = descendantScrollView(in: host), let document = scroll.documentView {
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? scrollOffset : maxY - scrollOffset
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        let destination = outputDirectory.appendingPathComponent(name + ".png")
        let bitmap: NSBitmapImageRep
        if glassMode {
            bitmap = try await captureComposited(frame: frame.insetBy(dx: -margin, dy: -margin), to: destination)
        } else {
            guard let cached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PreviewError.render(name)
            }
            host.cacheDisplay(in: host.bounds, to: cached)
            guard let png = cached.representation(using: .png, properties: [:]) else { throw PreviewError.render(name) }
            try png.write(to: destination)
            bitmap = cached
        }
        report.append(["name": name, "pointsWide": host.bounds.width, "pointsHigh": host.bounds.height,
                       "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
                       "capture": glassMode ? "composited-screen" : "view-bitmap",
                       "backdropMargin": margin])
        print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
    }

    private func captureComposited(frame: CGRect, to destination: URL) async throws -> NSBitmapImageRep {
        // screencapture uses top-left coordinates relative to the primary screen;
        // AppKit uses a bottom-left origin. Capture only our synthetic backdrop.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let requestURL = outputDirectory.appendingPathComponent(".glass-capture-request.json")
        let resultURL = outputDirectory.appendingPathComponent(".glass-capture-result.json")
        try? FileManager.default.removeItem(at: resultURL)
        let request: [String: Any] = [
            "rect": [Int(frame.minX), Int(primaryTop - frame.maxY), Int(frame.width), Int(frame.height)],
            "file": destination.lastPathComponent
        ]
        // The CLI driver owns screen capture so it can use the terminal's
        // existing access. The unique, offline preview app never asks for a new
        // privacy grant. Keep its run loop alive while the compositor captures.
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: resultURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let resultData = try? Data(contentsOf: resultURL),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw PreviewError.screenCaptureUnavailable("CLI capture driver timed out")
        }
        guard result["status"] as? Int == 0,
              let data = try? Data(contentsOf: destination),
              let bitmap = NSBitmapImageRep(data: data) else {
            throw PreviewError.screenCaptureUnavailable(result["error"] as? String ?? "No image produced")
        }
        return bitmap
    }

    private func descendantScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = descendantScrollView(in: child) { return found }
        }
        return nil
    }

    private func fail(_ error: Error) -> Never {
        fputs("UI preview failed: \(error)\n", stderr)
        exit(1)
    }

    enum PreviewError: Error {
        case render(String)
        case screenTooSmall(String)
        case screenCaptureUnavailable(String)
    }
}

private final class UIPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Broad colored bands remain identifiable through blur, while the visible
/// border gives a reference for the unblurred desktop behind each fixture.
private final class UIPreviewBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors = ["286C87", "A96642", "758955", "70629E"]
        for (index, color) in colors.enumerated() {
            NSColor(hex: color).setFill()
            NSRect(x: bounds.width * CGFloat(index) / CGFloat(colors.count), y: 0,
                   width: bounds.width / CGFloat(colors.count) + 1, height: bounds.height).fill()
        }
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: bounds.height * 0.44, width: bounds.width, height: bounds.height * 0.12).fill()
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
