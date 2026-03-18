import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class ScreenEngine {
    static let shared = ScreenEngine()

    private(set) var latestSnapshot: CGImage?
    private(set) var latestActiveApp: String = ""
    private(set) var latestActiveWindowTitle: String = ""
    private(set) var latestOCROverride: String? = nil

    // Last non-Holmes app — persists even when Holmes panel is frontmost
    private var lastKnownApp: String = ""
    private var lastKnownWindowTitle: String = ""

    private var timer: Timer?
    private let interval: TimeInterval = 3
    private var cachedFilter: SCContentFilter?
    private var cachedConfig: SCStreamConfiguration?

    var onNewSnapshot: ((CGImage, String, String) -> Void)?

    private init() {}

    func start() async {
        // Build SCK filter once — never triggers permission dialog again
        await buildSCKCache()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureNow() }
        }
        captureNow()
    }

    private func buildSCKCache() async {
        guard #available(macOS 13.0, *) else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.width  = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            cachedFilter = SCContentFilter(display: display, excludingWindows: [])
            cachedConfig = config
            print("[Holmes] SCK ready: \(display.width)x\(display.height)pts")
        } catch {
            print("[Holmes] SCK init failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func captureNow() {
        updateActiveApp()
        Task {
            // 1. Try AX text (works on native apps, fails on Electron)
            let axText = extractTextViaAccessibility()
            if axText.count > 100 {
                print("[Holmes] AX: \(axText.count) chars — \(String(axText.prefix(80)).replacingOccurrences(of: "\n", with: "|"))")
                latestOCROverride = axText
                onNewSnapshot?(makePlaceholder(), latestActiveApp, latestActiveWindowTitle)
                return
            }

            // 2. SCK screenshot + OCR (for Electron apps like Comet)
            latestOCROverride = nil
            if let image = await captureScreen() {
                print("[Holmes] SCK image: \(image.width)x\(image.height)px")
                latestSnapshot = image
                onNewSnapshot?(image, latestActiveApp, latestActiveWindowTitle)
            } else {
                print("[Holmes] All capture methods failed")
            }
        }
    }

    // MARK: - SCK capture (uses cached filter — no permission re-prompt)

    private func captureScreen() async -> CGImage? {
        guard #available(macOS 13.0, *),
              let filter = cachedFilter,
              let config = cachedConfig else { return nil }
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("[Holmes] SCK capture error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - AX text extraction

    private func extractTextViaAccessibility() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty
        else { return "" }

        var lines: [String] = []
        for window in windows.prefix(2) {
            collectText(from: window, into: &lines, depth: 0)
        }
        return lines.joined(separator: "\n")
    }

    private func collectText(from element: AXUIElement, into result: inout [String], depth: Int) {
        guard depth < 15 else { return }

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let s = ref as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty, s.count < 2000 {
            result.append(s)
        } else if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success,
                  let s = ref as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty, s.count < 500 {
            result.append(s)
        }

        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children.prefix(60) {
            collectText(from: child, into: &result, depth: depth + 1)
        }
    }

    private func makePlaceholder() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - Active app detection

    private func updateActiveApp() {
        // Find the frontmost non-Holmes app
        let allApps = NSWorkspace.shared.runningApplications
        let nonHolmes = allApps.filter { app in
            guard let name = app.localizedName else { return false }
            let n = name.lowercased()
            let bid = app.bundleIdentifier ?? ""
            return !n.contains("holmes") && !bid.contains("holmes")
        }

        // Primary: the currently active non-Holmes app
        if let active = nonHolmes.first(where: { $0.isActive }),
           let name = active.localizedName, !name.isEmpty {
            latestActiveApp = name
            lastKnownApp = name
        } else if !lastKnownApp.isEmpty {
            // Holmes panel is frontmost — use the last known real app
            latestActiveApp = lastKnownApp
        }

        // Window title: prefer the focused window of the last known real app
        let targetApp: NSRunningApplication?
        if let active = nonHolmes.first(where: { $0.isActive }) {
            targetApp = active
        } else {
            // Fall back to finding the last known app by name
            targetApp = nonHolmes.first { $0.localizedName == lastKnownApp }
        }

        if let app = targetApp {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let win = winRef {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, !title.isEmpty {
                    latestActiveWindowTitle = title
                    lastKnownWindowTitle = title
                }
            }
        } else if !lastKnownWindowTitle.isEmpty {
            latestActiveWindowTitle = lastKnownWindowTitle
        }
    }
}
