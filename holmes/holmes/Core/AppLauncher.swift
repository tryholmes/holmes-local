import AppKit
import Foundation

struct AppLaunchResult: Equatable, Sendable {
    let appName: String
    let message: String
    let succeeded: Bool
}

/// Native app opening, independent of the model and pixel-control permissions.
/// Callers decide authorization: explicit user requests may use this directly;
/// ComputerUseEngine retains its own master switch and kill switch.
enum AppLauncher {
    struct AppIdentity {
        let name: String
        let bundleIdentifier: String?
        let url: URL
    }

    private static let aliases: [String: String] = [
        "finder": "com.apple.finder", "safari": "com.apple.Safari",
        "mail": "com.apple.mail", "messages": "com.apple.MobileSMS",
        "notes": "com.apple.Notes", "calendar": "com.apple.iCal",
        "reminders": "com.apple.reminders", "music": "com.apple.Music",
        "photos": "com.apple.Photos", "maps": "com.apple.Maps",
        "facetime": "com.apple.FaceTime", "preview": "com.apple.Preview",
        "textedit": "com.apple.TextEdit", "terminal": "com.apple.Terminal",
        "app store": "com.apple.AppStore", "system settings": "com.apple.systempreferences",
        "system preferences": "com.apple.systempreferences", "settings": "com.apple.systempreferences",
        "activity monitor": "com.apple.ActivityMonitor", "disk utility": "com.apple.DiskUtility",
        "xcode": "com.apple.dt.Xcode", "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome", "spotify": "com.spotify.client"
    ]

    nonisolated static func resolve(named name: String, allowPrefixMatch: Bool = false) -> URL? {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.compactMap { app -> AppIdentity? in
            guard let url = app.bundleURL else { return nil }
            return AppIdentity(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                               bundleIdentifier: app.bundleIdentifier, url: url)
        }
        let directories = ["/Applications", "/Applications/Utilities", "/System/Applications",
                           "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return resolve(named: name, allowPrefixMatch: allowPrefixMatch,
                       runningApplications: running,
                       workspaceLookup: { workspace.urlForApplication(withBundleIdentifier: $0) },
                       appDirectories: directories)
    }

    /// Dependency boundary for resolver tests; reads only application identities
    /// and bundle metadata, never opens an app or searches user documents.
    nonisolated static func resolve(named raw: String, allowPrefixMatch: Bool = false,
                                    runningApplications: [AppIdentity],
                                    workspaceLookup: (String) -> URL?,
                                    appDirectories: [URL]) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // Try a bundle identifier BEFORE trimming .app: an identifier may itself
        // end in .app. Launch Services is the authority for apps outside the usual
        // folders, including apps installed by other package managers.
        if raw.contains("."), let url = workspaceLookup(raw) { return url }
        if let running = runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(raw) == .orderedSame
        }) { return running.url }
        if let canonicalID = aliases.values.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }),
           let url = workspaceLookup(canonicalID) { return url }

        let name = raw.lowercased().hasSuffix(".app") ? String(raw.dropLast(4)) : raw
        guard !name.isEmpty else { return nil }
        if let running = runningApplications.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return running.url
        }
        if let identifier = aliases[name.lowercased()], let url = workspaceLookup(identifier) { return url }

        let fm = FileManager.default
        let candidates = appDirectories.flatMap { directory -> [URL] in
            let entries = (try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            return entries.filter { url in
                url.pathExtension.lowercased() == "app"
                    && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        // Exact names across ALL folders outrank every prefix candidate.
        if let exact = candidates.first(where: {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }) { return exact }
        if raw.contains("."), let byID = candidates.first(where: {
            Bundle(url: $0)?.bundleIdentifier?.caseInsensitiveCompare(raw) == .orderedSame
        }) { return byID }
        // A prefix remains available only for the existing model computer tool;
        // a deterministic user launch must not turn 'Spot' into an arbitrary app.
        if allowPrefixMatch {
            return candidates.first { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(name.lowercased()) }
        }
        return nil
    }

    /// The closures describe only the returned app and make launch failure,
    /// activation, and Finder behavior testable without starting real processes.
    @MainActor struct OpenedApplication {
        let name: String
        let bundleIdentifier: String?
        let isTerminated: () -> Bool
        let isActive: () -> Bool
        let unhide: () -> Void
        let activate: () -> Bool
    }

    @MainActor static func launch(named name: String, allowPrefixMatch: Bool = false) async -> AppLaunchResult {
        await launch(named: name, allowPrefixMatch: allowPrefixMatch,
                     resolver: { resolve(named: $0, allowPrefixMatch: $1) },
                     opener: { url in
                         let configuration = NSWorkspace.OpenConfiguration()
                         configuration.activates = true
                         let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                         return OpenedApplication(
                            name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                            bundleIdentifier: app.bundleIdentifier,
                            isTerminated: { app.isTerminated }, isActive: { app.isActive },
                            unhide: { _ = app.unhide() }, activate: { app.activate() })
                     },
                     openFinderWindow: {
                         NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                     })
    }

    @MainActor static func launch(named raw: String, allowPrefixMatch: Bool = false,
                                  resolver: (String, Bool) -> URL?,
                                  opener: (URL) async throws -> OpenedApplication,
                                  openFinderWindow: () -> Bool) async -> AppLaunchResult {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return AppLaunchResult(appName: "", message: "Choose an app to open.", succeeded: false)
        }
        guard let url = resolver(name, allowPrefixMatch) else {
            return AppLaunchResult(appName: name, message: "No installed app matches '\(name)'. Use its exact name or bundle identifier.", succeeded: false)
        }
        do {
            let app = try await opener(url)
            guard !app.isTerminated() else {
                return AppLaunchResult(appName: app.name, message: "\(app.name) quit before it finished opening.", succeeded: false)
            }
            app.unhide()
            let activationRequested = app.activate()
            guard activationRequested || app.isActive() else {
                return AppLaunchResult(appName: app.name,
                                       message: "\(app.name) is running, but macOS couldn't bring it to the front.", succeeded: false)
            }
            if app.bundleIdentifier == "com.apple.finder", !openFinderWindow() {
                return AppLaunchResult(appName: app.name, message: "Finder is running, but its window couldn't be opened.", succeeded: false)
            }
            return AppLaunchResult(appName: app.name, message: "Opened \(app.name).", succeeded: true)
        } catch {
            return AppLaunchResult(appName: name, message: "Couldn't open \(name): \(error.localizedDescription)", succeeded: false)
        }
    }
}
