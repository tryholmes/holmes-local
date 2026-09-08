import AppKit
import Foundation

// MARK: - ExtensionInstaller
// Gets the Holmes browser extension from inside the app bundle into the user's
// browser and paired with the bridge, with as few clicks as a browser allows.
//
// Chromium browsers do not let a native app install an extension silently
// (that is a deliberate browser policy, not a Holmes limitation), so the
// installer does everything around that one gesture:
//   1. copies the bundled extension to a stable folder the user can point
//      "Load unpacked" at,
//   2. arms the bridge's pairing window so the extension is adopted the
//      moment it first posts,
//   3. opens the browser's extensions page and reveals the folder in Finder.
// The user turns on Developer mode, presses Load unpacked, picks the folder.
// When a Web Store listing exists, `storeURL` short-circuits all of that.

enum ExtensionInstaller {

    /// Set once the extension is published; onboarding then offers the store
    /// first and the unpacked path as fallback.
    static let storeURL: URL? = nil

    /// Where the unpacked extension lives on the user's disk.
    static var installedFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Holmes/extension", isDirectory: true)
    }

    /// The copy shipped inside Holmes.app (Resources/holmes-extension).
    static var bundledFolder: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let url = res.appendingPathComponent("holmes-extension", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    static var bundledVersion: String? { version(at: bundledFolder) }
    static var installedVersion: String? { version(at: installedFolder) }

    private static func version(at folder: URL?) -> String? {
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// Copies (or refreshes) the unpacked extension. Returns the folder.
    @discardableResult
    static func installUnpacked() throws -> URL {
        guard let source = bundledFolder else {
            throw NSError(domain: "Holmes.ExtensionInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This build of Holmes does not include the browser extension."])
        }
        let fm = FileManager.default
        let dest = installedFolder
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replace atomically: stage next to the target, then swap, so a browser
        // that already loaded the folder never sees a half-copied tree.
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".extension-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
        return dest
    }

    // MARK: Browsers

    struct Browser: Identifiable, Hashable {
        let id: String          // bundle identifier
        let name: String
        let appURL: URL
        let extensionsPage: String
    }

    /// Chromium-based browsers the MV3 extension runs in, in preference order.
    private static let candidates: [(bundleID: String, name: String, page: String)] = [
        ("ai.perplexity.comet",        "Comet",          "chrome://extensions"),
        ("com.google.Chrome",          "Google Chrome",  "chrome://extensions"),
        ("company.thebrowser.Browser", "Arc",            "arc://extensions"),
        ("company.thebrowser.dia",     "Dia",            "chrome://extensions"),
        ("com.brave.Browser",          "Brave",          "brave://extensions"),
        ("com.microsoft.edgemac",      "Microsoft Edge", "edge://extensions"),
        ("com.vivaldi.Vivaldi",        "Vivaldi",        "vivaldi://extensions"),
        ("com.operasoftware.Opera",    "Opera",          "opera://extensions"),
        ("com.google.Chrome.canary",   "Chrome Canary",  "chrome://extensions"),
        ("org.chromium.Chromium",      "Chromium",       "chrome://extensions")
    ]

    static func installedBrowsers() -> [Browser] {
        candidates.compactMap { c in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundleID) else { return nil }
            return Browser(id: c.bundleID, name: c.name, appURL: url, extensionsPage: c.page)
        }
    }

    /// Opens the browser's extensions page. Internal schemes (chrome://) are
    /// accepted on the command line, which is what `open -a` passes through;
    /// NSWorkspace refuses them as URLs.
    static func openExtensionsPage(in browser: Browser) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", browser.appURL.path, browser.extensionsPage]
        try? p.run()
    }

    static func revealInstalledFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([installedFolder])
    }

    /// The whole guided flow for one browser: copy, arm pairing, open the
    /// extensions page, reveal the folder. Throws only if the copy fails.
    @MainActor
    static func beginGuidedInstall(in browser: Browser) throws {
        try installUnpacked()
        BrowserBridge.shared.start()
        BrowserBridge.shared.beginPairing()
        openExtensionsPage(in: browser)
        revealInstalledFolder()
    }
}
