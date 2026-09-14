import Foundation

@main struct BrowserComposeBridgeTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var frontmost = BrowserBridge.AppIdentity(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let environment = BrowserBridge.ContextEnvironment(frontmost: { frontmost }, ownBundleIdentifier: "test.holmes",
            nameForBundle: { $0 == "com.google.Chrome" ? "Google Chrome" : "Comet" })
        let bridge = BrowserBridge(testToken: "synthetic-test-token", environment: environment)
        let origin = Date().addingTimeInterval(-0.8)
        var ticks = 0
        func payload(instance: String = "chrome-profile", focused: Bool = true, subject: String = "Im gonna be late",
                     body: String = "", old: Bool = false, stamp: Date? = nil) throws -> Data {
            ticks += 1
            let date = stamp ?? origin.addingTimeInterval(Double(ticks) / 1000)
            let identity = String(decoding: try JSONSerialization.data(withJSONObject: [instance, 23, 17, "document", "account", 1]), as: UTF8.self)
            let milliseconds = date.timeIntervalSince1970 * 1000
            var object: [String: Any] = ["app": "Chrome", "site": "mail.google.com", "url": "https://mail.google.com/mail/u/0/#inbox",
                "title": "Inbox title is not a subject", "type": "email_compose", "recipient": "boss@example.test", "subject": subject,
                "bodyText": body, "capturedAt": milliseconds, "isActiveTab": true, "visible": true, "focused": focused]
            if !old {
                object["browserInstanceId"] = instance
                object["emailComposeProtocolVersion"] = 1
                object["emailCompose"] = ["source": "browser", "identity": identity, "provider": "Gmail", "app": "Chrome",
                    "recipients": ["boss@example.test"], "cc": [String](), "bcc": [String](), "subject": subject, "body": body,
                    "bodyReadable": true, "bodyIsEmpty": body.isEmpty, "bodyRevision": body,
                    "capturedAt": milliseconds]
            }
            return try JSONSerialization.data(withJSONObject: object)
        }
        func commands(_ instance: String?) throws -> [[String: Any]] {
            try JSONSerialization.jsonObject(with: bridge.testDrainCommands(instance: instance)) as! [[String: Any]]
        }
        func nextCommand(_ instance: String) async throws -> [String: Any] {
            for _ in 0..<100 {
                await Task.yield()
                if let command = try commands(instance).first { return command }
            }
            fatalError("Expected a queued command for \(instance)")
        }
        func reply(_ command: [String: Any], _ result: [String: Any]) throws {
            var result = result; result["id"] = command["id"]
            bridge.testCommandResult(try JSONSerialization.data(withJSONObject: result))
        }
        func waitForPending(_ count: Int) async {
            for _ in 0..<100 {
                if bridge.testPendingCommandIDs.count == count { return }
                await Task.yield()
            }
            fatalError("Expected \(count) queued commands")
        }
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }

        let first = bridge.testIngest(try payload())!
        let expected = first.emailCompose!
        check(expected.canAutoDraft && expected.appBundleIdentifier == "com.google.Chrome", "Production builder preserves literal compose fields and browser identity")
        check(first.capturedAt == expected.capturedAt && first.capturedAt < Date(), "Original capture time survives the production parser")
        check(bridge.testIngest(try payload(stamp: Date().addingTimeInterval(-30))) == nil, "Queued old payload cannot become fresh context")
        check(bridge.testIngest(try payload(stamp: Date().addingTimeInterval(5))) == nil, "Future timestamp is refused")
        check(bridge.testIngest(try payload(stamp: origin)) == nil, "Out-of-order context cannot overwrite newer reading")
        check(bridge.testIngest(try payload(instance: "comet-profile", focused: false)) == nil, "Another browser cannot be relabeled as foreground Chrome")

        frontmost = .init(name: "Holmes", bundleIdentifier: "test.holmes")
        let own = bridge.testIngest(try payload(focused: false))!
        check(own.app == "Google Chrome" && own.emailCompose?.appBundleIdentifier == "com.google.Chrome", "Holmes review UI retains originating browser identity")
        check(bridge.testIngest(try payload(instance: "comet-profile", focused: false)) == nil, "Holmes frontmost cannot adopt another browser's page")

        var callbackCount = 0
        bridge.onLiveContext = { context in
            callbackCount += 1
            check(context.emailCompose?.subject == "Fresh read", "Fresh publication callback receives the new compose state")
        }
        let refresh = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        await Task.yield()
        check(try commands("comet-profile").isEmpty, "Wrong browser cannot drain a pending refresh")
        let request = try await nextCommand("chrome-profile")
        check(request["action"] as? String == "read_email_compose", "Refresh uses dedicated structured command")
        let freshPayload = try payload(focused: false, subject: "Fresh read")
        try reply(request, ["ok": true, "payload": JSONSerialization.jsonObject(with: freshPayload)])
        let refreshed = await refresh.value
        check(callbackCount == 1 && refreshed?.emailCompose?.subject == "Fresh read", "Refresh publishes then returns the same fresh snapshot")
        bridge.onLiveContext = nil

        let insert = Task { @MainActor in try await bridge.stageEmailDraft("Reviewed body", expected: expected) }
        await Task.yield()
        check(try commands("comet-profile").isEmpty, "Wrong browser cannot consume a pending insertion")
        let insertRequest = try await nextCommand("chrome-profile")
        check(insertRequest["action"] as? String == "fill_email_draft", "Insertion never reaches generic keyboard automation")
        let params = insertRequest["params"] as! [String: Any]
        check((params["expected"] as? [String: Any])?["identity"] as? String == expected.identity, "Exact original destination is delivered to extension")
        try reply(insertRequest, ["ok": true, "inserted": true, "identity": expected.identity])
        check(try await insert.value, "Only confirmed exact-destination insertion succeeds")

        let badInsert = Task { @MainActor in try await bridge.stageEmailDraft("Reviewed body", expected: expected) }
        let badRequest = try await nextCommand("chrome-profile")
        try reply(badRequest, ["ok": true, "inserted": true, "identity": "wrong-compose-window"])
        do { _ = try await badInsert.value; fatalError("Wrong result identity must fail") } catch { checks += 1 }

        frontmost = .init(name: "Notes", bundleIdentifier: "com.apple.Notes")
        do { _ = try await bridge.stageEmailDraft("Wrong app", expected: expected); fatalError("Unrelated foreground app must fail") } catch { checks += 1 }
        check(await bridge.refreshEmailComposeContext() == nil, "Refresh refuses unrelated foreground app")
        check(try commands("chrome-profile").isEmpty, "Refused operations enqueue no command")

        frontmost = .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let oldBridge = BrowserBridge(testToken: "synthetic-old-token", environment: environment)
        _ = oldBridge.testIngest(try payload(old: true))
        check(await oldBridge.refreshEmailComposeContext() == nil, "Old extension cannot fabricate a composer from generic page text")
        check(oldBridge.emailComposeUnavailableReason?.contains("chrome://extensions") == true, "Old protocol gets actionable reload instructions")

        // An observer can publish a newer reading during the refresh callback.
        // The return value must not overwrite it when the awaiting caller resumes.
        let newer = try payload(subject: "User changed subject", stamp: origin.addingTimeInterval(0.5))
        bridge.onLiveContext = { _ in
            bridge.onLiveContext = nil
            _ = bridge.testIngest(newer)
        }
        let racing = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        let raceRequest = try await nextCommand("chrome-profile")
        let racePayload = try payload(subject: "Before user edit")
        try reply(raceRequest, ["ok": true, "payload": JSONSerialization.jsonObject(with: racePayload)])
        let raced = await racing.value
        check(raced == nil, "A callback-overtaken refresh must not return stale compose context")
        check(bridge.lastLiveContext?.emailCompose?.subject == "User changed subject", "Newer callback state wins")

        frontmost = .init(name: "Comet", bundleIdentifier: "ai.perplexity.comet")
        let comet = bridge.testIngest(try payload(instance: "comet-profile", stamp: origin.addingTimeInterval(0.6)))
        check(comet?.app == "Comet" && comet?.emailCompose?.appBundleIdentifier == "ai.perplexity.comet", "Comet is bound by actual OS identity, not its Chrome User-Agent")
        frontmost = .init(name: "Holmes", bundleIdentifier: "test.holmes")
        check(bridge.testIngest(try payload(focused: false, stamp: origin.addingTimeInterval(0.65))) == nil,
              "A previously identified Chrome instance still cannot replace Comet behind Holmes")
        let cometRefresh = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        await Task.yield()
        check(try commands("chrome-profile").isEmpty, "Refresh after browser switch is reserved for Comet")
        let cometRequest = try await nextCommand("comet-profile")
        let cometPayload = try payload(instance: "comet-profile", focused: false, stamp: origin.addingTimeInterval(0.67))
        try reply(cometRequest, ["ok": true, "payload": JSONSerialization.jsonObject(with: cometPayload)])
        check(await cometRefresh.value?.app == "Comet", "Refresh from Holmes restores the originating Comet name")

        let staleRefresh = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        let staleRequest = try await nextCommand("comet-profile")
        let stalePayload = try payload(instance: "comet-profile", focused: false, stamp: Date().addingTimeInterval(-30))
        try reply(staleRequest, ["ok": true, "payload": JSONSerialization.jsonObject(with: stalePayload)])
        check(await staleRefresh.value == nil, "A stale command reply never falls back to cached current context")

        // Cancel on the main actor and immediately poll, before the cancellation
        // handler's actor cleanup gets a turn. The synchronous marker must win.
        let contextBeforeCancellation = bridge.lastLiveContext
        let reasonBeforeCancellation = bridge.emailComposeUnavailableReason
        let cancelledRead = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        await waitForPending(1)
        let cancelledReadID = bridge.testPendingCommandIDs[0]
        let survivingRead = Task { @MainActor in
            await bridge.enqueueBrowserCommand("read_email_compose", ["_browserInstanceID": "comet-profile"])
        }
        await waitForPending(2)
        cancelledRead.cancel()
        let survivingReadCommands = try commands("comet-profile")
        check(survivingReadCommands.count == 1 && survivingReadCommands[0]["id"] as? Int != cancelledReadID,
              "Cancelled queued refresh is never delivered and a separate request survives")
        check(await cancelledRead.value == nil, "Cancelled refresh resumes promptly without a context")
        try reply(survivingReadCommands[0], ["ok": true, "survived": true])
        check(await survivingRead.value["survived"] as? Bool == true, "Cancelling one awaiter does not cancel another")
        check(bridge.lastLiveContext == contextBeforeCancellation && bridge.emailComposeUnavailableReason == reasonBeforeCancellation,
              "Cancelled refresh preserves context and does not invent an unavailable reason")

        let cancelledFill = Task { @MainActor in try await bridge.stageEmailDraft("Do not insert", expected: expected) }
        await waitForPending(1)
        let cancelledFillID = bridge.testPendingCommandIDs[0]
        let survivingFill = Task { @MainActor in try await bridge.stageEmailDraft("Approved second draft", expected: expected) }
        await waitForPending(2)
        cancelledFill.cancel()
        let survivingFillCommands = try commands("chrome-profile")
        check(survivingFillCommands.count == 1 && survivingFillCommands[0]["id"] as? Int != cancelledFillID,
              "Cancelled queued insertion is never delivered while a separate insertion survives")
        do { _ = try await cancelledFill.value; fatalError("Cancelled insertion must throw") }
        catch is CancellationError { checks += 1 }
        try reply(survivingFillCommands[0], ["ok": true, "inserted": true, "identity": expected.identity])
        check(try await survivingFill.value, "Cancellation leaves the other insertion awaiter intact")

        let latePayload = try JSONSerialization.jsonObject(with: payload(instance: "comet-profile", focused: false,
            subject: "Cancelled stale completion", stamp: Date()))
        for id in [cancelledReadID, cancelledFillID] + Array(90_000..<90_100) {
            try reply(["id": id], ["ok": true, "inserted": true, "identity": expected.identity, "payload": latePayload])
        }
        check(bridge.testPendingCommandIDs.isEmpty && bridge.testAwaitingCommandCount == 0 && bridge.testTrackedCommandCount == 0,
              "Late cancelled and unknown results are discarded without accumulating command state")
        check(bridge.lastLiveContext == contextBeforeCancellation, "Late cancelled read never ingests its payload")

        // A reply may resolve the continuation immediately before Stop, while
        // its producer has not resumed. Refresh must still refuse publication.
        let replyRace = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        let replyRaceRequest = try await nextCommand("comet-profile")
        try reply(replyRaceRequest, ["ok": true, "payload": latePayload])
        replyRace.cancel()
        check(await replyRace.value == nil && bridge.lastLiveContext == contextBeforeCancellation,
              "Cancellation after a result but before producer resumption prevents stale context publication")

        // Delivered requests cannot be withdrawn from the extension, but their
        // cancelled awaiters must resolve and ignore any subsequent completion.
        let deliveredRead = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        let deliveredReadRequest = try await nextCommand("comet-profile")
        deliveredRead.cancel()
        try reply(deliveredReadRequest, ["ok": true, "payload": latePayload])
        check(await deliveredRead.value == nil, "Delivered read cancellation wins an immediate result before actor cleanup")
        let deliveredFill = Task { @MainActor in try await bridge.stageEmailDraft("Already delivered", expected: expected) }
        let deliveredFillRequest = try await nextCommand("chrome-profile")
        deliveredFill.cancel()
        try reply(deliveredFillRequest, ["ok": true, "inserted": true, "identity": expected.identity])
        do { _ = try await deliveredFill.value; fatalError("Delivered cancellation must not report success") }
        catch is CancellationError { checks += 1 }
        check(bridge.testAwaitingCommandCount == 0 && bridge.testTrackedCommandCount == 0
              && bridge.lastLiveContext == contextBeforeCancellation,
              "Late delivered completions neither publish context nor retain result state")

        let precancelledCommand = Task { @MainActor in await bridge.enqueueBrowserCommand("read_email_compose", [:]) }
        precancelledCommand.cancel()
        check(await precancelledCommand.value["cancelled"] as? Bool == true, "Already cancelled generic command is rejected before enqueue")
        let precancelledRead = Task { @MainActor in await bridge.refreshEmailComposeContext() }
        precancelledRead.cancel()
        check(await precancelledRead.value == nil, "Already cancelled refresh is rejected before enqueue")
        let precancelledFill = Task { @MainActor in try await bridge.stageEmailDraft("Never queued", expected: expected) }
        precancelledFill.cancel()
        do { _ = try await precancelledFill.value; fatalError("Already cancelled insertion must throw") }
        catch is CancellationError { checks += 1 }
        check(try commands("chrome-profile").isEmpty && commands("comet-profile").isEmpty
              && bridge.testAwaitingCommandCount == 0 && bridge.testTrackedCommandCount == 0,
              "All cancellation paths leave no command available for a later poll")
        print("Browser compose bridge: \(checks) checks passed using production Swift parser, queue, refresh and insertion code")

        var socketChecks = 0
        func socketCheck(_ value: Bool, _ message: String) {
            socketChecks += 1
            precondition(value, message)
            print("PASS \(message)")
        }
        await BridgeLoopbackTests.runCommandChannel(check: socketCheck)
        await BridgeLoopbackTests.runBodyLimits(check: socketCheck)
        await BridgeLoopbackTests.runLifecycle(check: socketCheck)
        await BridgeLoopbackTests.runPairing(check: socketCheck)
        print("Browser bridge loopback sockets: \(socketChecks) checks passed against the real server on an ephemeral port")
    }
}
