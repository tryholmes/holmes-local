import Foundation

// Real loopback socket tests for BrowserBridge + BridgeServer. The production
// server is bound to an ephemeral 127.0.0.1 port through the DEBUG constructor; no
// token files, browsers or app activation are involved.

enum BridgeLoopbackTests {
    static let token = "loopback-test-token-0001"

    @MainActor static func makeBridge(frontmost: @escaping () -> BrowserBridge.AppIdentity? = {
        .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
    }) -> (BrowserBridge, UInt16) {
        let environment = BrowserBridge.ContextEnvironment(frontmost: frontmost, ownBundleIdentifier: "test.holmes",
            nameForBundle: { $0 == "com.google.Chrome" ? "Google Chrome" : "Comet" })
        let bridge = BrowserBridge(testToken: token, environment: environment, port: 0)
        bridge.start()
        guard let port = bridge.boundPort, bridge.isRunning else { fatalError("Loopback bridge did not start: \(bridge.lastError ?? "?")") }
        return (bridge, port)
    }

    static func poll(_ port: UInt16, instance: String, wait: Int = 0, token: String = token,
                     timeout: TimeInterval = 10) -> (LoopbackResponse?, [[String: Any]]) {
        var headers = ["X-Holmes-Token": token, "X-Holmes-Browser-Instance": instance]
        if wait > 0 { headers["X-Holmes-Long-Poll"] = "\(wait)" }
        let response = LoopbackHTTP.request(port: port, method: "GET", path: "/commands", headers: headers, timeout: timeout)
        return (response, (response?.json as? [[String: Any]]) ?? [])
    }

    static func postResult(_ port: UInt16, _ object: [String: Any], token: String = token) -> LoopbackResponse? {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return LoopbackHTTP.request(port: port, method: "POST", path: "/command-result",
                                    headers: ["X-Holmes-Token": token, "Content-Type": "application/json"], body: body)
    }

    @MainActor static func waitUntil(_ label: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { fatalError("Timed out waiting for: \(label)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Queue, long poll and delivery deadline behavior over real sockets.
    @MainActor static func runCommandChannel(check: (Bool, String) -> Void) async {
        let (bridge, port) = makeBridge()
        defer { bridge.stop() }

        let health = await LoopbackHTTP.background { LoopbackHTTP.request(port: port, method: "GET", path: "/health") }
        check(health?.status == 200, "Health probe answers without a token over a real socket")
        let unauthorized = await LoopbackHTTP.background { poll(port, instance: "inst-a", token: "wrong-token-000000000").0 }
        check(unauthorized?.status == 401, "GET /commands without the token is rejected")

        // Long poll: the request is already waiting when the command is enqueued and
        // must return right away with it instead of at the end of the hold.
        let longPollStart = Date()
        // Blocking socket work runs on a Dispatch thread so a narrow Swift task pool (CI runners) never starves.
        let longPoll = Task { await LoopbackHTTP.background { poll(port, instance: "inst-a", wait: 15) } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let producer = Task { @MainActor in await bridge.enqueueBrowserCommand("listTabs", ["_browserInstanceID": "inst-a"]) }
        let (longPollResponse, delivered) = await longPoll.value
        let longPollSeconds = Date().timeIntervalSince(longPollStart)
        check(longPollResponse?.status == 200 && delivered.count == 1 && longPollSeconds < 3,
              "Long poll returns as soon as a command is enqueued (\(String(format: "%.2f", longPollSeconds))s)")
        check(longPollResponse?.headers["x-holmes-long-poll"] == "1", "Server advertises long poll support")
        check(delivered.first?["session"] as? String == bridge.commandQueue.session, "Delivered command carries the launch session")
        let id = delivered.first?["id"] as? Int ?? -1
        let posted = await LoopbackHTTP.background { postResult(port, ["id": id, "ok": true, "tabs": [Any](),
            "session": bridge.commandQueue.session]) }
        check(posted?.status == 200, "Result POST accepted")
        let producerResult = await producer.value
        check(producerResult["ok"] as? Bool == true, "Producer resolves with the posted result")

        // A long poll with nothing to deliver ends at its hold time, not never.
        let idleStart = Date()
        let idle = await LoopbackHTTP.background { poll(port, instance: "inst-a", wait: 1) }
        let idleSeconds = Date().timeIntervalSince(idleStart)
        check(idle.0?.status == 200 && idle.1.isEmpty && idleSeconds >= 0.9 && idleSeconds < 3,
              "Idle long poll is held for the requested wait then returns an empty array")

        // A busy main thread must not stall GET /commands. The old handler blocked on
        // DispatchQueue.main.sync and would take the whole sleep to answer.
        let busyProducer = Task { @MainActor in await bridge.enqueueBrowserCommand("listTabs", ["_browserInstanceID": "inst-busy"]) }
        await waitUntil("busy command queued") { bridge.testPendingCommandIDs.count == 1 }
        let busyTiming = LockedBox<(TimeInterval, Int)?>(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let start = Date()
            let (_, commands) = poll(port, instance: "inst-busy")
            busyTiming.value = (Date().timeIntervalSince(start), commands.count)
        }
        usleep(2_500_000)  // the main thread is deliberately blocked
        await waitUntil("busy poll finished") { busyTiming.value != nil }
        let (busySeconds, busyCount) = busyTiming.value!
        check(busyCount == 1 && busySeconds < 1.5,
              "GET /commands answers while the main thread is blocked (\(String(format: "%.2f", busySeconds))s)")
        let busyID = bridge.commandQueue.deliveredIDs.first ?? -1
        _ = await LoopbackHTTP.background { postResult(port, ["id": busyID, "ok": true]) }
        check((await busyProducer.value)["ok"] as? Bool == true, "Busy main thread command still completes")

        // Deadlines: undelivered gets the distinct asleep error.
        bridge.commandUndeliveredTimeout = 0.6
        bridge.commandResultTimeout = 0.8
        let asleepStart = Date()
        let asleep = await bridge.enqueueBrowserCommand("listTabs", ["_browserInstanceID": "never-polls"])
        check(asleep["error"] as? String == "extension_asleep" && asleep["undelivered"] as? Bool == true
              && Date().timeIntervalSince(asleepStart) < 2,
              "Never fetched command fails as extension_asleep, not a generic timeout")

        // The result clock starts at delivery, not at enqueue.
        let slowStart = Date()
        let slow = Task { @MainActor in await bridge.enqueueBrowserCommand("fillField", ["_browserInstanceID": "inst-slow", "value": "x"]) }
        try? await Task.sleep(nanoseconds: 450_000_000)
        let slowDelivered = await LoopbackHTTP.background { poll(port, instance: "inst-slow").1 }
        check(slowDelivered.count == 1, "Slow worker fetches the command before the undelivered deadline")
        let slowResult = await slow.value
        let slowSeconds = Date().timeIntervalSince(slowStart)
        check(slowResult["error"] as? String == "timeout" && slowResult["delivered"] as? Bool == true && slowSeconds >= 1.15,
              "Delivered command times out measured from delivery (\(String(format: "%.2f", slowSeconds))s)")
        let slowID = slowDelivered.first?["id"] as? Int ?? -1
        _ = await LoopbackHTTP.background { postResult(port, ["id": slowID, "ok": true, "filled": true]) }
        await waitUntil("late result recorded") { bridge.lateResultsIgnored == 1 }
        check(bridge.testPendingCommandIDs.isEmpty && bridge.testAwaitingCommandCount == 0 && bridge.commandQueue.deliveredIDs.isEmpty,
              "Late result after a timeout is logged and ignored without re-enqueueing")

        // A started ack from a worker that queued the command behind another one
        // restarts the result clock.
        let queued = Task { @MainActor in await bridge.enqueueBrowserCommand("click", ["_browserInstanceID": "inst-slow", "selector": "a"]) }
        let queuedDelivered = await LoopbackHTTP.background { poll(port, instance: "inst-slow").1 }
        let queuedID = queuedDelivered.first?["id"] as? Int ?? -1
        try? await Task.sleep(nanoseconds: 600_000_000)
        _ = await LoopbackHTTP.background { postResult(port, ["id": queuedID, "_holmesStarted": true]) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(bridge.testAwaitingCommandCount == 1, "Started ack keeps a command queued in the browser from timing out")
        _ = await LoopbackHTTP.background { postResult(port, ["id": queuedID, "ok": true, "clicked": true]) }
        check((await queued.value)["clicked"] as? Bool == true, "Command that started late still delivers its result")

        // A result from another launch's session never completes this launch's id.
        bridge.commandResultTimeout = 3
        let foreign = Task { @MainActor in await bridge.enqueueBrowserCommand("click", ["_browserInstanceID": "inst-s", "selector": "b"]) }
        let foreignID = await LoopbackHTTP.background { poll(port, instance: "inst-s").1.first?["id"] as? Int ?? -1 }
        _ = await LoopbackHTTP.background { postResult(port, ["id": foreignID, "ok": true, "session": "previous-launch"]) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(bridge.testAwaitingCommandCount == 1, "Result stamped with another session is ignored")
        _ = await LoopbackHTTP.background { postResult(port, ["id": foreignID, "ok": true, "session": bridge.commandQueue.session]) }
        check((await foreign.value)["ok"] as? Bool == true, "Matching session completes the command")

        // A long poll whose client hangs up must not swallow a later command.
        bridge.commandUndeliveredTimeout = 5
        LoopbackHTTP.abandon(port: port, path: "/commands", headers: ["X-Holmes-Token": token,
            "X-Holmes-Browser-Instance": "inst-h", "X-Holmes-Long-Poll": "20"], after: 0.2)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let afterHangup = Task { @MainActor in await bridge.enqueueBrowserCommand("listTabs", ["_browserInstanceID": "inst-h"]) }
        await waitUntil("hangup command queued") { bridge.testPendingCommandIDs.count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rescued = await LoopbackHTTP.background { poll(port, instance: "inst-h").1 }
        check(rescued.count == 1, "Abandoned long poll does not consume a command enqueued after the hangup")
        _ = await LoopbackHTTP.background { postResult(port, ["id": rescued.first?["id"] as? Int ?? -1, "ok": true]) }
        _ = await afterHangup.value
    }

    /// Body limits: /context stays small, /command-result takes large results, and
    /// an oversize body always gets a readable 413 instead of a reset connection.
    @MainActor static func runBodyLimits(check: (Bool, String) -> Void) async {
        let (bridge, port) = makeBridge()
        defer { bridge.stop() }
        bridge.commandResultTimeout = 10

        let big = Task { @MainActor in await bridge.enqueueBrowserCommand("screenshotTab", ["_browserInstanceID": "inst-big"]) }
        let bigID = await LoopbackHTTP.background { poll(port, instance: "inst-big").1.first?["id"] as? Int ?? -1 }
        let twoMegabytes = String(repeating: "A", count: 2 * 1024 * 1024)
        let accepted = await LoopbackHTTP.background { postResult(port, ["id": bigID, "ok": true, "dataUrl": twoMegabytes]) }
        check(accepted?.status == 200, "A 2 MB command result is accepted (the old 512 KB cap returned 413)")
        check(((await big.value)["dataUrl"] as? String)?.count == twoMegabytes.count, "The large result reaches the producer intact")

        let oversize = Data(repeating: 0x41, count: BridgeProtocol.maxCommandResultBytes + 1024)
        let rejected = await LoopbackHTTP.background {
            LoopbackHTTP.request(port: port, method: "POST", path: "/command-result",
                                 headers: ["X-Holmes-Token": token, "Content-Type": "application/json"], body: oversize, timeout: 20)
        }
        check(rejected?.status == 413, "A result over the 16 MB cap gets a readable 413 after the body is drained")
        check((rejected?.json as? [String: Any])?["limit"] as? Int == BridgeProtocol.maxCommandResultBytes,
              "The 413 names the limit so the extension can explain the size")

        let bigContext = Data(repeating: 0x41, count: BridgeProtocol.maxBodyBytes + 1)
        let contextRejected = await LoopbackHTTP.background {
            LoopbackHTTP.request(port: port, method: "POST", path: "/context",
                                 headers: ["X-Holmes-Token": token, "Content-Type": "application/json"], body: bigContext)
        }
        check(contextRejected?.status == 413, "Page context keeps its 512 KB cap")
        let after = await LoopbackHTTP.background { LoopbackHTTP.request(port: port, method: "GET", path: "/health") }
        check(after?.status == 200, "The server keeps serving after oversize requests")
    }

    /// accept/bind resilience and handler slot limits.
    @MainActor static func runLifecycle(check: (Bool, String) -> Void) async {
        var backoff = BridgeBackoff(base: 0.01, cap: 1)
        let delays = (0..<10).map { _ in backoff.failure() }
        check(delays[0] == 0.01 && delays[1] == 0.02 && delays[2] == 0.04 && delays.last == 1 && delays.allSatisfy { $0 <= 1 },
              "accept() failures back off exponentially and are capped at 1s instead of spinning")
        backoff.success()
        check(backoff.failure() == 0.01, "A successful accept resets the backoff")

        // Port already taken: the error is published and the bind retried.
        let (holder, port) = makeBridge()
        let environment = BrowserBridge.ContextEnvironment(frontmost: { nil }, ownBundleIdentifier: "test.holmes", nameForBundle: { _ in nil })
        let contender = BrowserBridge(testToken: token, environment: environment, port: port)
        contender.bindBackoff = BridgeBackoff(base: 0.2, cap: 0.4)
        contender.start()
        check(!contender.isRunning && contender.lastError?.contains("already in use") == true,
              "A taken port is reported through lastError: \(contender.lastError ?? "nil")")
        holder.stop()
        await waitUntil("contender binds after the port frees", timeout: 5) { contender.isRunning }
        check(contender.lastError == nil && contender.boundPort == port, "Background bind retry recovers and clears the error")
        let recovered = await LoopbackHTTP.background { LoopbackHTTP.request(port: port, method: "GET", path: "/health") }
        check(recovered?.status == 200, "The retried listener serves requests")

        // Long polls are capped so they can never occupy every handler slot.
        let holds = (0..<BridgeProtocol.maxConcurrentLongPolls).map { index in
            Task { await LoopbackHTTP.background { poll(port, instance: "hold-\(index)", wait: 8) } }
        }
        // Wait for the server to really hold every slot; a fixed sleep raced on slow CI runners.
        await waitUntil("every long poll slot is held", timeout: 10) {
            contender.testHeldLongPollCount == BridgeProtocol.maxConcurrentLongPolls
        }
        let extraStart = Date()
        let extra = await LoopbackHTTP.background { poll(port, instance: "hold-extra", wait: 4) }
        check(extra.0?.status == 200 && Date().timeIntervalSince(extraStart) < 1.5,
              "A long poll beyond the cap is answered immediately")
        check(extra.0?.headers["x-holmes-long-poll"] != "1",
              "A long poll beyond the cap is not reported as held, so the worker backs off")
        let beat = await LoopbackHTTP.background {
            LoopbackHTTP.request(port: port, method: "POST", path: "/heartbeat",
                                 headers: ["X-Holmes-Token": token, "Content-Type": "application/json"], body: Data("{}".utf8))
        }
        check(beat?.status == 200, "Heartbeats are still served while long polls wait")
        for hold in holds { _ = await hold.value }

        // Stalled clients filling every slot get a quick 503 instead of a hang.
        let idle = (0..<BridgeProtocol.maxConcurrentClients).map { _ in LoopbackHTTP.openIdle(port: port) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // A backlog of requests arriving together must all be refused at once, not
        // one slot wait after another (which pushed later ones past the extension's
        // 5s fetch timeout).
        let backlog = (0..<5).map { _ in
            Task { await LoopbackHTTP.background { () -> (Int, TimeInterval) in
                let start = Date()
                let response = LoopbackHTTP.request(port: port, method: "GET", path: "/health", timeout: 8)
                return (response?.status ?? -1, Date().timeIntervalSince(start))
            } }
        }
        var backlogResults: [(Int, TimeInterval)] = []
        for request in backlog { backlogResults.append(await request.value) }
        let slowest = backlogResults.map(\.1).max() ?? 99
        check(backlogResults.allSatisfy { $0.0 == 503 } && slowest < 1.0,
              "With every handler stalled a backlog of 5 requests all get 503 within \(String(format: "%.2f", slowest))s")
        idle.forEach { close($0) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let healthy = await LoopbackHTTP.background { LoopbackHTTP.request(port: port, method: "GET", path: "/health") }
        check(healthy?.status == 200, "Service resumes once stalled clients go away")
        contender.stop()
    }

    static func beat(_ port: UInt16, secret: String, origin: String?, instance: String? = nil, focused: Bool? = nil) -> Int {
        var headers = ["X-Holmes-Token": secret, "Content-Type": "application/json"]
        if let origin { headers["Origin"] = origin }
        if let instance { headers["X-Holmes-Browser-Instance"] = instance }
        if let focused { headers["X-Holmes-Browser-Focused"] = focused ? "1" : "0" }
        return LoopbackHTTP.request(port: port, method: "POST", path: "/heartbeat", headers: headers,
                                    body: Data("{}".utf8))?.status ?? -1
    }

    /// Several paired browsers, extension origin pairing, removal, and routing of
    /// commands that name no browser.
    @MainActor static func runPairing(check: (Bool, String) -> Void) async {
        let store = PairedExtensionStore.memory()
        let environment = BrowserBridge.ContextEnvironment(frontmost: { .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome") },
            ownBundleIdentifier: "test.holmes", nameForBundle: { _ in nil })
        let bridge = BrowserBridge(testToken: token, environment: environment, port: 0, pairingStore: store)
        bridge.start()
        let port = bridge.boundPort!
        let chrome = "chrome-extension-secret-0001", comet = "comet-extension-secret-00002"

        check(await LoopbackHTTP.background { beat(port, secret: chrome, origin: "chrome-extension://abc") } == 401,
              "An unknown token is refused while pairing is not armed")
        bridge.beginPairing()
        check(await LoopbackHTTP.background { beat(port, secret: chrome, origin: nil) } == 401,
              "A native client with no Origin cannot claim the pairing window")
        check(await LoopbackHTTP.background { beat(port, secret: chrome, origin: "https://evil.example") } == 401,
              "A web page origin cannot claim the pairing window")
        check(bridge.isPairing, "Refused attempts do not consume the window")
        check(await LoopbackHTTP.background { beat(port, secret: chrome, origin: "chrome-extension://abc", instance: "chrome-inst") } == 200,
              "An extension origin pairs inside the window")
        await waitUntil("chrome paired") { bridge.pairedExtensions.count == 1 }
        check(bridge.recentlyPairedExtension?.token == chrome,
              "The newly paired browser is surfaced right after adoption so an unexpected pairing is visible")
        check(!bridge.isPairing, "The window closes after one adoption")

        bridge.beginPairing()
        check(await LoopbackHTTP.background { beat(port, secret: comet, origin: "chrome-extension://def", instance: "comet-inst") } == 200,
              "A second browser pairs in a new window")
        await waitUntil("comet paired") { bridge.pairedExtensions.count == 2 }
        check(await LoopbackHTTP.background { beat(port, secret: chrome, origin: "chrome-extension://abc", instance: "chrome-inst") } == 200,
              "Pairing another browser keeps the first token valid")
        await waitUntil("instances labelled") { bridge.pairedExtensions.allSatisfy { $0.instanceID != nil } }
        check(store.load().count == 2 && Set(store.load().compactMap(\.instanceID)) == ["chrome-inst", "comet-inst"],
              "Both pairings are persisted with their browser instance")

        // Routing: a command that names no browser goes to the one most recently
        // in front, not to whichever polls first.
        _ = await LoopbackHTTP.background { beat(port, secret: comet, origin: "chrome-extension://def", instance: "comet-inst", focused: true) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        _ = await LoopbackHTTP.background { beat(port, secret: chrome, origin: "chrome-extension://abc", instance: "chrome-inst", focused: false) }
        let generic = Task { @MainActor in await bridge.enqueueBrowserCommand("listTabs", [:]) }
        await waitUntil("generic queued") { bridge.testPendingCommandIDs.count == 1 }
        let chromeFirst = await LoopbackHTTP.background { poll(port, instance: "chrome-inst", token: chrome).1 }
        check(chromeFirst.isEmpty, "A background browser polling first does not take a generic command")
        let cometGot = await LoopbackHTTP.background { poll(port, instance: "comet-inst", token: comet).1 }
        check(cometGot.count == 1, "The most recently focused browser receives the generic command")
        _ = await LoopbackHTTP.background { postResult(port, ["id": cometGot.first?["id"] as? Int ?? -1, "ok": true], token: comet) }
        _ = await generic.value
        _ = await LoopbackHTTP.background { beat(port, secret: chrome, origin: "chrome-extension://abc", instance: "chrome-inst", focused: true) }
        let secondGeneric = Task { @MainActor in await bridge.enqueueBrowserCommand("listTabs", [:]) }
        await waitUntil("second generic queued") { bridge.testPendingCommandIDs.count == 1 }
        let cometSecond = await LoopbackHTTP.background { poll(port, instance: "comet-inst", token: comet).1 }
        let chromeSecond = await LoopbackHTTP.background { poll(port, instance: "chrome-inst", token: chrome).1 }
        check(cometSecond.isEmpty && chromeSecond.count == 1, "Focusing the other browser moves generic commands to it")
        _ = await LoopbackHTTP.background { postResult(port, ["id": chromeSecond.first?["id"] as? Int ?? -1, "ok": true], token: chrome) }
        _ = await secondGeneric.value
        bridge.stop()

        // A relaunch keeps both pairings; removing one refuses only that token.
        let relaunched = BrowserBridge(testToken: token, environment: environment, port: 0, pairingStore: store)
        relaunched.start()
        let relaunchPort = relaunched.boundPort!
        let chromeAfterRelaunch = await LoopbackHTTP.background { beat(relaunchPort, secret: chrome, origin: "chrome-extension://abc") }
        let cometAfterRelaunch = await LoopbackHTTP.background { beat(relaunchPort, secret: comet, origin: "chrome-extension://def") }
        check(chromeAfterRelaunch == 200 && cometAfterRelaunch == 200, "Both pairings survive a relaunch")
        relaunched.removePairedExtension(chrome)
        check(await LoopbackHTTP.background { beat(relaunchPort, secret: chrome, origin: "chrome-extension://abc") } == 401,
              "A removed pairing is refused")
        let cometAfterRemoval = await LoopbackHTTP.background { beat(relaunchPort, secret: comet, origin: "chrome-extension://def") }
        check(cometAfterRemoval == 200 && store.load().map(\.token) == [comet], "Removing one pairing keeps the other")
        relaunched.stop()
    }

    /// Page context health, instance tracking without a context post, persistence
    /// across launches, and accurate per error messages.
    @MainActor static func runLiveness(check: (Bool, String) -> Void) async {
        var frontmost = BrowserBridge.AppIdentity(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let environment = BrowserBridge.ContextEnvironment(frontmost: { frontmost }, ownBundleIdentifier: "test.holmes",
            nameForBundle: { _ in "Google Chrome" })
        func sighting(_ instance: String, focused: Bool? = nil, script: String? = nil) -> BridgeSighting {
            let body = script.map { try! JSONSerialization.data(withJSONObject: ["activeTab": ["script": $0]]) }
            return BridgeSighting(token: token, instance: instance, focused: focused, body: body)
        }
        let page = try! JSONSerialization.data(withJSONObject: ["app": "Chrome", "site": "example.test", "url": "https://example.test/a",
            "title": "Example page", "headline": "Reading Example page", "isActiveTab": true, "visible": true, "focused": true,
            "browserInstanceId": "chrome-inst", "emailComposeProtocolVersion": 1])

        let bridge = BrowserBridge(testToken: token, environment: environment)
        bridge.testSighting(sighting("chrome-inst", focused: true, script: "missing"))
        check(bridge.isExtensionConnected && bridge.isPageContextStale && bridge.linkState == .pageContextStale,
              "Worker heartbeats with an orphaned active tab read as page context stale, not fully connected")
        _ = bridge.testIngest(page)
        check(!bridge.isPageContextStale && bridge.linkState == .connected, "A page context post clears the stale state")
        bridge.testSighting(sighting("chrome-inst", script: "restricted"))
        check(!bridge.isPageContextStale, "A browser internal page is not stale")
        bridge.testSighting(sighting("chrome-inst", script: "ok"))
        check(!bridge.isPageContextStale, "A live content script is not stale")

        let legacy = BrowserBridge(testToken: token, environment: environment)
        legacy.testSighting(sighting("old-inst"))
        legacy.testRefreshConnectionState(now: Date().addingTimeInterval(BrowserBridge.pageContextTimeout + 20))
        check(legacy.isExtensionConnected && legacy.isPageContextStale,
              "Without a probe, a frontmost browser whose page stays silent while the worker beats is stale")
        frontmost = .init(name: "Notes", bundleIdentifier: "com.apple.Notes")
        legacy.testSighting(sighting("old-inst"))
        legacy.testRefreshConnectionState(now: Date().addingTimeInterval(BrowserBridge.pageContextTimeout + 20))
        check(!legacy.isPageContextStale, "A silent page is not stale while the user is in another app")
        frontmost = .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        // After an app restart no context has posted yet; a focused heartbeat is
        // enough to target the right browser instead of saying reload.
        let defaults = UserDefaults(suiteName: "holmes.bridge.tests.\(UUID().uuidString)")!
        let restarted = BrowserBridge(testToken: token, environment: environment)
        restarted.testUseInstanceDefaults(defaults)
        restarted.testSighting(sighting("comet-inst", focused: true))
        check(defaults.string(forKey: BrowserBridge.lastInstanceDefaultsKey) == "comet-inst",
              "The browser instance seen in front is persisted")
        restarted.commandResultTimeout = 5
        let read = Task { @MainActor in await restarted.refreshEmailComposeContext() }
        await waitUntil("refresh targets instance") { restarted.testPendingCommandIDs.count == 1 }
        let delivered = try! JSONSerialization.jsonObject(with: restarted.testDrainCommands(instance: "comet-inst")) as! [[String: Any]]
        check(delivered.count == 1, "A compose refresh after restart targets the instance from heartbeats")
        restarted.testCommandResult(try! JSONSerialization.data(withJSONObject: ["id": delivered[0]["id"]!, "ok": false,
            "error": "Could not establish connection. Receiving end does not exist."]))
        check(await read.value == nil && restarted.emailComposeUnavailableReason?.contains("chrome://extensions") == true
              && restarted.emailComposeUnavailableReason?.contains("Refresh the email tab") == true,
              "A genuinely missing content script gets refresh then reload advice")

        let relaunched = BrowserBridge(testToken: token, environment: environment)
        relaunched.testUseInstanceDefaults(defaults)
        relaunched.commandUndeliveredTimeout = 0.3
        let asleep = await relaunched.refreshEmailComposeContext()
        check(asleep == nil && relaunched.emailComposeUnavailableReason?.contains("isn't picking up requests") == true
              && relaunched.emailComposeUnavailableReason?.contains("chrome://extensions") == false,
              "A remembered instance whose worker never polls is reported as asleep, not as needing reload")

        let messages: [([String: Any], String)] = [
            (["error": "timeout"], "didn't answer in time"),
            (["error": "queue_full"], "too many browser requests"),
            (["ok": false, "refused": true, "reason": "The composer is no longer in the active tab."], "Bring the email tab to the front"),
            (["ok": false, "refused": true, "reason": "No active compose window."], "Open the email you're writing"),
            (["ok": false, "error": "result too large (20000000 bytes)"], "too large"),
            (["ok": false, "refused": true, "reason": "The draft belongs to another browser session."], "another browser session")
        ]
        for (result, expected) in messages {
            let message = BrowserBridge.browserFailureMessage(result)
            check(message.contains(expected) && !message.contains("chrome://extensions"),
                  "\(result) maps to an accurate message without reload advice")
        }

        // The remembered browser (comet-inst, from the previous launch) is not alive
        // now; a different browser is polling. Refresh must target the live one
        // instead of waiting out the undelivered deadline for a dead instance.
        let switched = BrowserBridge(testToken: token, environment: environment)
        switched.testUseInstanceDefaults(defaults)
        switched.commandQueue.noteSeen(instance: "new-inst", focused: false)
        switched.commandUndeliveredTimeout = 1
        switched.commandResultTimeout = 5
        let switchedRead = Task { @MainActor in await switched.refreshEmailComposeContext() }
        await waitUntil("switched refresh queued") { switched.testPendingCommandIDs.count == 1 }
        let toLive = try! JSONSerialization.jsonObject(with: switched.testDrainCommands(instance: "new-inst")) as! [[String: Any]]
        check(toLive.count == 1, "A remembered browser that is not alive this launch does not win over the live one")
        if let id = toLive.first?["id"] {
            switched.testCommandResult(try! JSONSerialization.data(withJSONObject: ["id": id, "ok": false, "error": "timeout"]))
        }
        _ = await switchedRead.value
    }
}

extension LoopbackHTTP {
    /// Connects and sends nothing, holding a server handler slot until closed.
    static func openIdle(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    /// Opens a request, then closes the socket without reading the response.
    static func abandon(port: UInt16, path: String, headers: [String: String], after delay: TimeInterval) {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            for (key, value) in headers { head += "\(key): \(value)\r\n" }
            head += "\r\n"
            _ = head.withCString { send(fd, $0, strlen($0), 0) }
            Thread.sleep(forTimeInterval: delay)
            close(fd)
        }
    }
}
