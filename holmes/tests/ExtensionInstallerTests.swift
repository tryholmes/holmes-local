import Foundation

// The production installer is exercised with temporary source/destination URLs.
// Pairing, browsers, Finder and the clipboard are never invoked by these tests.
@MainActor final class BrowserBridge {
    static let shared = BrowserBridge()
    func start() { fatalError("Tests must not start the bridge") }
    func beginPairing() { fatalError("Tests must not pair a browser") }
}

@main struct ExtensionInstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("holmes-extension-test-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("Downloads/Holmes Extension")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try writeManifest(version: "1.0", in: source)
        try "first".write(to: source.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        check(ExtensionInstaller.installedFolder == downloads.appendingPathComponent("Holmes Extension", isDirectory: true),
              "Install location must be a visible folder in Downloads")
        let installed = try ExtensionInstaller.installUnpacked(from: source, to: destination)
        check(installed == destination, "Installer must return the folder Chrome should load")
        check(fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path), "Manifest must be directly inside the selected folder")
        check(try String(contentsOf: destination.appendingPathComponent("background.js"), encoding: .utf8) == "first", "Extension assets must be copied")

        try "old".write(to: destination.appendingPathComponent("obsolete.js"), atomically: true, encoding: .utf8)
        try writeManifest(version: "2.0", in: source)
        try "updated".write(to: source.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try ExtensionInstaller.installUnpacked(from: source, to: destination)
        check(try String(contentsOf: destination.appendingPathComponent("background.js"), encoding: .utf8) == "updated", "Refreshing must update extension assets at the same path")
        check(!fm.fileExists(atPath: destination.appendingPathComponent("obsolete.js").path), "Refreshing must remove obsolete extension files")
        check(try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Holmes Extension"], "Staging must not leave extra folders in Downloads")

        try fm.removeItem(at: destination)
        let recreated = try ExtensionInstaller.installUnpacked(from: source, to: destination)
        let recreatedAsset = try String(contentsOf: destination.appendingPathComponent("background.js"), encoding: .utf8)
        check(recreated == destination && recreatedAsset == "updated"
              && fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path),
              "Repeated setup must recreate a removed export folder with the current manifest and assets")

        let invalid = root.appendingPathComponent("invalid")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        expectFailure { try ExtensionInstaller.installUnpacked(from: invalid, to: destination) }
        check(try String(contentsOf: destination.appendingPathComponent("background.js"), encoding: .utf8) == "updated", "A missing package must leave the installed copy intact")

        let unrelated = root.appendingPathComponent("unrelated")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "keep me".write(to: unrelated.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        expectFailure { try ExtensionInstaller.installUnpacked(from: source, to: unrelated) }
        check(try String(contentsOf: unrelated.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep me", "A same-named personal folder must remain untouched")

        let link = root.appendingPathComponent("shortcut")
        try fm.createSymbolicLink(at: link, withDestinationURL: destination)
        expectFailure { try ExtensionInstaller.installUnpacked(from: source, to: link) }
        check(try fm.destinationOfSymbolicLink(atPath: link.path) == destination.path, "A symlink must remain untouched")
        print("Extension installer: \(checks) checks passed")
    }

    private static var checks = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    private static func expectFailure(_ operation: () throws -> URL) {
        do { _ = try operation(); fatalError("Expected installation to fail") }
        catch { checks += 1 }
    }
    private static func writeManifest(version: String, in folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Holmes", "version": version])
        try data.write(to: folder.appendingPathComponent("manifest.json"))
    }
}
