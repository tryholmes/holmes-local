import Foundation

// Bridge reliability soak: N command round trips through the REAL BrowserBridge
// server on a loopback port, driven by a simulated extension worker that long polls,
// gets evicted for seconds at a time, drops and retries result posts, posts
// duplicates, while the main thread is repeatedly blocked. Prints the success rate
// and exits nonzero unless every round trip succeeds.

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

final class SoakStats: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    func bump(_ key: String, by amount: Int = 1) { lock.lock(); counters[key, default: 0] += amount; lock.unlock() }
    subscript(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[key, default: 0] }
}

/// A fake MV3 worker speaking the production wire protocol over real sockets.
final class SimulatedWorker: @unchecked Sendable {
    let port: UInt16
    let token: String
    let instance = "soak-instance"
    let stats: SoakStats
    private let random: LockedBox<SplitMix64>
    private let evictedUntil = LockedBox(Date.distantPast)
    private let stopped = LockedBox(false)
    private let executors = DispatchQueue(label: "soak.worker.executors", attributes: .concurrent)

    init(port: UInt16, token: String, seed: UInt64, stats: SoakStats) {
        self.port = port
        self.token = token
        self.stats = stats
        random = LockedBox(SplitMix64(seed: seed))
    }

    private func roll() -> Double {
        var value = 0.0
        random.mutate { value = $0.unit() }
        return value
    }

    private var isEvicted: Bool { Date() < evictedUntil.value }

    func start() {
        Thread.detachNewThread { [self] in pollLoop() }
        Thread.detachNewThread { [self] in heartbeatLoop() }
    }

    func stop() { stopped.value = true }

    private func headers() -> [String: String] {
        ["X-Holmes-Token": token, "X-Holmes-Browser-Instance": instance, "X-Holmes-Browser-Focused": "1"]
    }

    private func heartbeatLoop() {
        while !stopped.value {
            if !isEvicted {
                var beat = headers()
                beat["Content-Type"] = "application/json"
                let body = Data(#"{"activeTab":{"script":"ok"}}"#.utf8)
                _ = LoopbackHTTP.request(port: port, method: "POST", path: "/heartbeat", headers: beat, body: body, timeout: 5)
            }
            usleep(1_000_000)
        }
    }

    private func pollLoop() {
        while !stopped.value {
            if isEvicted { usleep(50_000); continue }
            var request = headers()
            request["X-Holmes-Long-Poll"] = "20"
            guard let response = LoopbackHTTP.request(port: port, method: "GET", path: "/commands",
                                                      headers: request, timeout: 28),
                  response.status == 200,
                  let commands = response.json as? [[String: Any]] else {
                stats.bump("pollFailures")
                usleep(200_000)
                continue
            }
            stats.bump("polls")
            for command in commands { execute(command) }
            // Eviction: MV3 kills the worker; nothing polls until it is woken again.
            if roll() < 0.06 {
                let gap = 1 + roll() * 3
                evictedUntil.value = Date().addingTimeInterval(gap)
                stats.bump("evictions")
            }
        }
    }

    private func execute(_ command: [String: Any]) {
        let workMicros = UInt32(roll() * 40_000)
        let dropFirstPost = roll() < 0.10
        let duplicatePost = roll() < 0.05
        executors.async { [self] in
            usleep(workMicros)
            let params = command["params"] as? [String: Any] ?? [:]
            var result: [String: Any] = ["id": command["id"] ?? -1, "action": command["action"] ?? "",
                                         "ok": true, "echo": params["n"] ?? -1]
            if let session = command["session"] { result["session"] = session }
            let body = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            var postHeaders = headers()
            postHeaders["Content-Type"] = "application/json"
            if dropFirstPost {
                // The first POST is lost (worker hiccup); the retry with backoff lands.
                stats.bump("droppedFirstPosts")
                usleep(200_000)
            }
            var attempts = 0
            while attempts < 4 {
                attempts += 1
                if let response = LoopbackHTTP.request(port: port, method: "POST", path: "/command-result",
                                                       headers: postHeaders, body: body, timeout: 10),
                   response.status == 200 { break }
                stats.bump("resultRetries")
                usleep(UInt32(250_000 * attempts))
            }
            if duplicatePost {
                // Idempotent re-delivery of a stored result must be harmless.
                _ = LoopbackHTTP.request(port: port, method: "POST", path: "/command-result",
                                         headers: postHeaders, body: body, timeout: 10)
                stats.bump("duplicatePosts")
            }
        }
    }
}

@main struct BridgeSoak {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let total = Int(ProcessInfo.processInfo.environment["SOAK_COMMANDS"] ?? "") ?? 200
        let seed = UInt64(ProcessInfo.processInfo.environment["SOAK_SEED"] ?? "") ?? 20260913
        let concurrency = 4
        let token = "soak-test-token-000000001"
        let environment = BrowserBridge.ContextEnvironment(frontmost: { .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome") },
            ownBundleIdentifier: "test.holmes", nameForBundle: { _ in "Google Chrome" })
        let bridge = BrowserBridge(testToken: token, environment: environment, port: 0)
        bridge.start()
        guard let port = bridge.boundPort else {
            print("Bridge soak: server did not start (\(bridge.lastError ?? "unknown"))")
            exit(1)
        }
        let stats = SoakStats()
        let worker = SimulatedWorker(port: port, token: token, seed: seed, stats: stats)
        worker.start()

        // Busy main thread: repeatedly block the main actor for up to ~0.9s.
        let blocker = Task { @MainActor in
            var generator = SplitMix64(seed: seed ^ 0xFFFF)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                usleep(UInt32(200_000 + generator.unit() * 700_000))
                stats.bump("mainThreadStalls")
            }
        }

        let started = Date()
        var failures: [String] = []
        var succeeded = 0
        await withTaskGroup(of: (Int, [String: Any]).self) { group in
            var next = 0
            func launch(_ index: Int) {
                group.addTask { @MainActor in
                    // Every fifth command names no browser and relies on routing.
                    var params: [String: Any] = ["n": index]
                    if index % 5 != 0 { params["_browserInstanceID"] = worker.instance }
                    return (index, await bridge.enqueueBrowserCommand("extract", params))
                }
            }
            while next < min(concurrency, total) { launch(next); next += 1 }
            for await (index, result) in group {
                if result["ok"] as? Bool == true, result["echo"] as? Int == index {
                    succeeded += 1
                } else {
                    failures.append("#\(index): \(result)")
                }
                if next < total { launch(next); next += 1 }
            }
        }
        blocker.cancel()
        worker.stop()
        let seconds = Date().timeIntervalSince(started)
        let rate = Double(succeeded) / Double(total) * 100
        print(String(format: "Bridge soak: %d/%d command round trips succeeded (%.1f%%) in %.1fs", succeeded, total, rate, seconds))
        print("  evictions \(stats["evictions"]), main thread stalls \(stats["mainThreadStalls"]), dropped first result posts \(stats["droppedFirstPosts"]), duplicate result posts \(stats["duplicatePosts"]), result retries \(stats["resultRetries"]), polls \(stats["polls"]), poll failures \(stats["pollFailures"])")
        print("  late results ignored \(bridge.lateResultsIgnored), pending \(bridge.testPendingCommandIDs.count), awaiting \(bridge.testAwaitingCommandCount)")
        for failure in failures.prefix(10) { print("  FAILED \(failure)") }
        bridge.stop()
        exit(succeeded == total ? 0 : 1)
    }
}
