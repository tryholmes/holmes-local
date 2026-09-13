import AppKit
import Foundation

@main
struct AppLauncherTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.dropFirst() == ["--open-spotify"] {
            try await openAppOnce(name: "Spotify", identifier: "com.spotify.client")
            return
        }
        if CommandLine.arguments.dropFirst() == ["--open-messages"] {
            try await openAppOnce(name: "Messages", identifier: "com.apple.MobileSMS")
            return
        }
        precondition(CommandLine.arguments.count == 1, "Only --open-spotify or --open-messages enables an explicit live check")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holmes-app-resolver-\(UUID().uuidString)")
        let first = directory.appendingPathComponent("First")
        let second = directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func bundle(_ name: String, id: String, in folder: URL, extension suffix: String = "app") throws -> URL {
            let url = folder.appendingPathComponent(name + "." + suffix)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let lite = try bundle("Spotify Lite", id: "test.spotify-lite", in: first)
        let spotify = try bundle("Spotify", id: "com.spotify.client", in: second)
        let editor = try bundle("Sample Editor", id: "com.Example.Editor", in: second)
        try Data().write(to: first.appendingPathComponent("NotAnApplication.app"))
        let external = directory.appendingPathComponent("External")
        let portable = try bundle("Portable", id: "com.Example.Portable", in: external)
        let externalSpotify = try bundle("Spotify", id: "com.spotify.client", in: external)
        let identifierEndingInApp = try bundle("Suffix", id: "com.example.app", in: external)
        let finderURL = try bundle("Finder", id: "com.apple.finder", in: external)
        let messages = try bundle("Messages", id: "com.apple.MobileSMS", in: second)
        let simulatorMessages = try bundle("Messages", id: "com.apple.MobileSMS", in: external.appendingPathComponent("SimulatorRuntime"))
        let assistant = try bundle("Messages Assistant Extension", id: "com.apple.messages.AssistantExtension",
                                   in: messages.appendingPathComponent("Contents/PlugIns"), extension: "appex")
        let misleadingApp = try bundle("Quick Look Simulator", id: "com.apple.QuickLookSimulator", in: external)
        let running = [
            AppLauncher.AppIdentity(name: "Messages", bundleIdentifier: "com.apple.messages.AssistantExtension", url: assistant),
            AppLauncher.AppIdentity(name: "Assistant", bundleIdentifier: "com.apple.messages.AssistantExtension", url: assistant),
            AppLauncher.AppIdentity(name: "Messages", bundleIdentifier: "com.apple.QuickLookSimulator", url: misleadingApp),
            AppLauncher.AppIdentity(name: "Portable", bundleIdentifier: "com.Example.Portable", url: portable)
        ]
        func resolve(_ name: String, prefix: Bool = false, lookup: (String) -> URL? = { _ in nil }) -> URL? {
            AppLauncher.resolve(named: name, allowPrefixMatch: prefix, runningApplications: running,
                                workspaceLookup: lookup, appDirectories: [first, second])
        }

        func sameURL(_ candidate: URL?, _ expected: URL) -> Bool {
            candidate?.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
        }

        expect(sameURL(resolve(" Spotify "), spotify), "Whitespace must not prevent exact app resolution")
        expect(sameURL(resolve("sPoTiFy"), spotify), "Application names must match case-insensitively")
        expect(sameURL(resolve("SPOTIFY.APP"), spotify), "An optional .app suffix must be normalized")
        expect(sameURL(resolve("Spotify", prefix: true), spotify), "An exact app in a later directory must beat an earlier prefix")
        expect(resolve("Spot") == nil, "Direct requests must not choose a prefix match")
        expect(sameURL(resolve("Spot", prefix: true), lite), "The existing computer tool may opt into prefix matching")
        expect(sameURL(resolve("portable"), portable), "Running apps outside standard folders must resolve by name")
        expect(sameURL(resolve("COM.EXAMPLE.PORTABLE"), portable), "Running app bundle identifiers match case-insensitively")
        expect(sameURL(resolve("COM.EXAMPLE.EDITOR"), editor), "Installed bundle identifiers match case-insensitively")
        expect(sameURL(resolve("Spotify", lookup: { $0 == "com.spotify.client" ? externalSpotify : nil }), spotify),
               "A normal installation must outrank other registered copies")
        expect(sameURL(AppLauncher.resolve(named: "Spotify", runningApplications: [],
                                           workspaceLookup: { $0 == "com.spotify.client" ? externalSpotify : nil },
                                           appDirectories: [first]), externalSpotify),
               "The Spotify alias must still resolve valid nonstandard installations")
        expect(sameURL(resolve("COM.SPOTIFY.CLIENT", lookup: { $0 == "com.spotify.client" ? spotify : nil }), spotify),
               "Known bundle identifiers resolve using their canonical case")
        expect(sameURL(resolve("com.example.app", lookup: { $0 == "com.example.app" ? identifierEndingInApp : nil }), identifierEndingInApp),
               "A bundle identifier ending in .app must be resolved before suffix normalization")
        expect(resolve("") == nil && resolve(".app") == nil, "Empty names must not resolve")
        expect(resolve("NotAnApplication") == nil, "A regular file named .app is not an application")
        expect(resolve("../../Spotify") == nil, "A relative path must not be treated as an app name")

        expect(sameURL(resolve("Messages"), messages),
               "The Messages app must outrank its running assistant extension and misleading display names")
        expect(sameURL(resolve("Messages.app", prefix: true), messages),
               "Model-driven launches must select the same Messages app as direct launches")
        expect(sameURL(resolve("Messages", lookup: { _ in simulatorMessages }), messages),
               "Installed Messages must outrank a registered simulator copy with the same bundle identifier")
        expect(sameURL(resolve("COM.APPLE.MOBILESMS", lookup: { _ in simulatorMessages }), messages),
               "An explicit Messages identifier must also reject the simulator duplicate")
        expect(resolve("Assistant") == nil && resolve("com.apple.messages.AssistantExtension") == nil,
               "Running app extensions must not be launched by name or bundle identifier")
        expect(AppLauncher.resolve(named: "Messages", runningApplications: running,
                                   workspaceLookup: { _ in assistant }, appDirectories: []) == nil,
               "A Launch Services app-extension result must not be opened")
        expect(AppLauncher.resolve(named: "Messages", runningApplications: running,
                                   workspaceLookup: { _ in misleadingApp }, appDirectories: []) == nil,
               "Canonical aliases must reject a registered result with a different bundle identity")
        expect(AppLauncher.resolve(named: "com.example.missing", runningApplications: [],
                                   workspaceLookup: { _ in portable }, appDirectories: []) == nil,
               "Explicit bundle identifiers must validate the registered app's metadata")

        var opens = 0
        var unhides = 0
        var activations = 0
        var finderOpens = 0
        func opened(_ name: String = "Spotify", id: String = "com.spotify.client",
                    terminated: Bool = false, active: Bool = false, activationAccepted: Bool = true) -> AppLauncher.OpenedApplication {
            AppLauncher.OpenedApplication(name: name, bundleIdentifier: id,
                                          isTerminated: { terminated }, isActive: { active },
                                          unhide: { unhides += 1 }, activate: { activations += 1; return activationAccepted })
        }
        let success = await AppLauncher.launch(named: "spotify",
                                              resolver: { name, prefix in expect(!prefix, "Direct launches use exact resolution"); return resolve(name) },
                                              opener: { url in expect(sameURL(url, spotify), "Launch uses the resolved URL"); opens += 1; return opened() },
                                              openFinderWindow: { finderOpens += 1; return true })
        expect(success == AppLaunchResult(appName: "Spotify", message: "Opened Spotify.", succeeded: true),
               "Success uses the launched app's actual display name")
        expect(opens == 1 && unhides == 1 && activations == 1 && finderOpens == 0,
               "Successful launch must unhide/activate exactly once and leave Finder alone")
        let mismatch = await AppLauncher.launch(named: "Messages", resolver: { _, _ in messages },
                                               opener: { _ in opened("Quick Look Simulator", id: "com.apple.QuickLookSimulator") },
                                               openFinderWindow: { false })
        expect(!mismatch.succeeded && mismatch.appName == "Messages" && mismatch.message.contains("different application"),
               "An unexpected returned app must never be announced as the requested launch")
        expect(unhides == 1 && activations == 1, "A mismatched returned app must not be foregrounded")
        let missing = await AppLauncher.launch(named: "Missing", resolver: { _, _ in nil },
                                              opener: { _ in fatalError("Missing apps must not launch") }, openFinderWindow: { false })
        expect(!missing.succeeded && missing.message.contains("No installed app"), "Missing apps return an actionable failure")
        let failed = await AppLauncher.launch(named: "Spotify", resolver: { _, _ in spotify },
                                             opener: { _ in throw NSError(domain: "launch-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch Services rejected the app"]) },
                                             openFinderWindow: { false })
        expect(!failed.succeeded && failed.message.contains("Launch Services rejected the app"), "Native launch errors must reach the caller")
        let terminated = await AppLauncher.launch(named: "Spotify", resolver: { _, _ in spotify },
                                                 opener: { _ in opened(terminated: true) }, openFinderWindow: { false })
        expect(!terminated.succeeded && activations == 1, "An app that immediately quits must not report success")
        let inactive = await AppLauncher.launch(named: "Spotify", resolver: { _, _ in spotify },
                                               opener: { _ in opened(activationAccepted: false) }, openFinderWindow: { false })
        expect(!inactive.succeeded && inactive.message.contains("front"), "Activation refusal must be reported truthfully")
        let alreadyActive = await AppLauncher.launch(named: "Spotify", resolver: { _, _ in spotify },
                                                    opener: { _ in opened(active: true, activationAccepted: false) }, openFinderWindow: { false })
        expect(alreadyActive.succeeded, "An app already in front does not need another successful activation request")
        let finder = await AppLauncher.launch(named: "Finder", resolver: { _, _ in finderURL },
                                             opener: { _ in opened("Finder", id: "com.apple.finder") },
                                             openFinderWindow: { finderOpens += 1; return true })
        expect(finder.succeeded && finderOpens == 1, "Finder launch must also request a visible home window")
        let finderFailed = await AppLauncher.launch(named: "Finder", resolver: { _, _ in finderURL },
                                                   opener: { _ in opened("Finder", id: "com.apple.finder") }, openFinderWindow: { false })
        expect(!finderFailed.succeeded, "A failed Finder window request must not report full success")
        print("Passed \(checks) native app-launch regression checks; no real apps were launched")
    }

    /// Explicit opt-in helper. This is the only path in this test executable that
    /// opens a real app. It checks process identity and visibility, never message
    /// content, playback, or mouse/keyboard events.
    @MainActor private static func openAppOnce(name: String, identifier: String) async throws {
        guard let parsedName = AppLaunchIntent.appName(in: "open \(name)"), parsedName == name else {
            fatalError("The production intent parser failed to recognize open \(name)")
        }
        guard let url = AppLauncher.resolve(named: name),
              url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier == identifier else {
            fatalError("\(name) did not resolve to the expected application bundle")
        }
        print("Resolved \(name): \(url.path)")
        let result = await AppLauncher.launch(named: name)
        print(result.message)
        guard result.succeeded else { fatalError("Native \(name) launch failed") }
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == identifier,
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == identifier }),
               !app.isTerminated, !app.isHidden {
                print("Verified production 'open \(name)': running, unhidden, and frontmost (pid \(app.processIdentifier))")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        fatalError("\(name) did not become a visible foreground app after launch")
    }
}
