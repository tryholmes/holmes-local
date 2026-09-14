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
        let longPoll = Task.detached { poll(port, instance: "inst-a", wait: 15) }
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
}

extension LoopbackHTTP {
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
