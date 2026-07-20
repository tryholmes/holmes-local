import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// The precise locus of the user's attention, read from the Accessibility tree:
/// which control is focused, what it contains, and what (if anything) is
/// selected. This is the structural signal OCR can never give — it's the
/// difference between "you're in Gmail" and "your cursor is in the To: field".
struct FocusedContext {
    let role: String            // AX role, e.g. "AXTextField", "AXTextArea"
    let roleDescription: String // human role, e.g. "text field", "text entry area"
    let label: String           // the control's label/description/placeholder
    let value: String           // its current contents (truncated)
    let selectedText: String    // the current selection (truncated)

    /// True for controls the user types into — so callers can phrase
    /// "editing …" vs merely "focused on …".
    var isEditable: Bool {
        let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        return editable.contains(role)
    }

    var isMeaningful: Bool {
        !value.isEmpty || !selectedText.isEmpty || (isEditable && !label.isEmpty)
    }
}

/// One self-consistent capture: image, app/window identity, AX text, and focus
/// are all read together and delivered as a bundle, so an overlapping capture
/// (the 3s timer racing the app-switch observer) can never pair one screen's
/// pixels with another's app name or focused control.
struct CaptureResult {
    let image: CGImage?         // real screenshot (OCR + vision), or nil on the fast AX path
    let appName: String
    let windowTitle: String
    let axOverride: String?     // AX text, or the __NO_SCREEN_ACCESS__ sentinel; nil = OCR the image
    let focused: FocusedContext?
    let visionUsable: Bool      // image is present and non-blank (safe to hand to vision)
}

@MainActor
final class ScreenEngine {
    static let shared = ScreenEngine()

    private(set) var latestSnapshot: CGImage?
    private(set) var latestActiveApp: String = ""
    private(set) var latestActiveWindowTitle: String = ""
    private(set) var latestOCROverride: String? = nil
    /// Focused control + selection, refreshed every capture (sub-ms, native).
    private(set) var latestFocusedContext: FocusedContext? = nil

    // Last non-Holmes app — persists even when Holmes panel is frontmost
    private var lastKnownApp: String = ""
    private var lastKnownWindowTitle: String = ""

    private var timer: Timer?
    private let interval: TimeInterval = 3
    private var cachedFilter: SCContentFilter?
    private var cachedConfig: SCStreamConfiguration?

    // Event-driven capture: fire the instant the user switches apps instead of
    // waiting up to a full 3s tick. Generation counter coalesces rapid
    // cmd-tabbing so only the app the user LANDS on gets captured.
    private var appSwitchObserver: NSObjectProtocol?
    private var appSwitchGeneration = 0

    var onNewSnapshot: ((CaptureResult) -> Void)?

    private init() {}

    func start() async {
        // Force the Screen Recording prompt if we don't truly have access yet.
        // A rebuilt Xcode binary often has a STALE grant that returns black frames
        // instead of prompting — preflight catches that and re-requests.
        if CGPreflightScreenCaptureAccess() {
            print("[Holmes] Screen Recording: granted ✓")
        } else {
            print("[Holmes] Screen Recording: NOT granted — requesting…")
            let granted = CGRequestScreenCaptureAccess()
            print("[Holmes] Screen Recording request returned \(granted) — if false, grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, then fully quit and relaunch Holmes.")
        }

        // Build SCK filter once — never triggers permission dialog again
        await buildSCKCache()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureNow() }
        }

        // Instant context on app switch — a short beat lets the new app's
        // window and AX tree settle before we read it.
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appSwitchGeneration += 1
                let generation = self.appSwitchGeneration
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard generation == self.appSwitchGeneration else { return }
                self.captureNow()
            }
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
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
    }

    func captureNow() {
        Task {
            // Read app identity, focus, and AX text SYNCHRONOUSLY into locals
            // (no suspension yet), then deliver those exact values. An overlapping
            // capture can't tear them apart because there's no await in between,
            // and everything downstream is delivered in one CaptureResult rather
            // than re-read from shared state after a suspension.
            updateActiveApp()
            let app = latestActiveApp
            let title = latestActiveWindowTitle
            let focused = extractFocusedContext()
            latestFocusedContext = focused
            let axText = extractTextViaAccessibility()

            // Fast path: rich AX text (native apps). Deliver IMMEDIATELY — no
            // screenshot, no suspension. Vision, when it's actually wanted, is
            // captured on demand during enrichment (grabScreenshotForVision), so
            // the common native path stays instant and never burns a full-display
            // capture per tick.
            if axText.count > 100 {
                print("[Holmes] AX: \(axText.count) chars — \(String(axText.prefix(80)).replacingOccurrences(of: "\n", with: "|"))")
                latestOCROverride = axText
                onNewSnapshot?(CaptureResult(image: nil, appName: app, windowTitle: title,
                                             axOverride: axText, focused: focused, visionUsable: false))
                return
            }

            // No usable AX text — screenshot for OCR (Electron apps like Comet).
            latestOCROverride = nil
            if let image = await captureScreen() {
                let blank = isLikelyBlank(image)
                if !blank { latestSnapshot = image }
                print("[Holmes] SCK image: \(image.width)x\(image.height)px\(blank ? " (blank)" : "")")
                onNewSnapshot?(CaptureResult(image: image, appName: app, windowTitle: title,
                                             axOverride: nil, focused: focused, visionUsable: !blank))
            } else {
                // Capture unavailable (Screen Recording permission usually goes stale
                // after an Xcode rebuild). NEVER dead-end here — that leaves the panel
                // frozen on "Analyzing your screen…". Fire with whatever AX gave us, or
                // a marker so the UI shows a clear "grant permission" message instead.
                print("[Holmes] Capture failed — Screen Recording permission may be stale; firing fallback so the UI never freezes")
                latestOCROverride = axText.isEmpty ? "__NO_SCREEN_ACCESS__" : axText
                onNewSnapshot?(CaptureResult(image: nil, appName: app, windowTitle: title,
                                             axOverride: latestOCROverride, focused: focused, visionUsable: false))
            }
        }
    }

    /// Captures a fresh, non-blank screenshot on demand — used by the enrichment
    /// path to escalate to vision on the AX/native path (where captureNow()
    /// deliberately skips the screenshot to stay fast). Returns nil on a
    /// failed or blank capture, so vision never runs on black pixels.
    func grabScreenshotForVision() async -> CGImage? {
        guard let image = await captureScreen(), !isLikelyBlank(image) else { return nil }
        return image
    }

    // MARK: - SCK capture (uses cached filter — no permission re-prompt)

    private func captureScreen() async -> CGImage? {
        guard #available(macOS 13.0, *) else { return nil }
        // If permission was granted AFTER launch, the cache is still empty — rebuild
        // it now so capture starts working without needing an app restart.
        if cachedConfig == nil { await buildSCKCache() }
        guard let config = cachedConfig else {
            print("[Holmes] No capture config — Screen Recording permission missing")
            return nil
        }
        do {
            // Rebuild filter each capture to exclude Holmes windows — no permission re-prompt,
            // just refreshes window list so OCR only sees the background app.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let holmesWindows = content.windows.filter {
                let bid = $0.owningApplication?.bundleIdentifier ?? ""
                let name = $0.owningApplication?.applicationName.lowercased() ?? ""
                return bid.contains("holmes") || name.contains("holmes")
            }
            let filter = SCContentFilter(display: display, excludingWindows: holmesWindows)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if isLikelyBlank(image) {
                print("[Holmes] ⚠️ Captured frame is BLANK/black — Screen Recording permission is stale for this build. Re-grant in System Settings ▸ Privacy & Security ▸ Screen Recording, then fully quit and relaunch Holmes.")
            }
            return image
        } catch {
            print("[Holmes] SCK capture error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Cheap all-black check: downscale to 8×8 and look for any non-dark pixel.
    /// A blank result almost always means the Screen Recording grant is stale.
    private func isLikelyBlank(_ image: CGImage) -> Bool {
        let w = 8, h = 8
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var maxV: UInt8 = 0
        for i in 0..<(w * h * 4) { maxV = max(maxV, ptr[i]) }
        return maxV < 12
    }

    // MARK: - Focused element + selection (structural attention signal)

    private func extractFocusedContext() -> FocusedContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let frontName = app.localizedName?.lowercased() ?? ""
        guard !frontName.contains("holmes") else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        func attr(_ name: String, cap: Int) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
                  let s = ref as? String else { return "" }
            return String(s.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let role = attr(kAXRoleAttribute as String, cap: 60)
        let roleDesc = attr(kAXRoleDescriptionAttribute as String, cap: 60)
        // Best available label: explicit description, then title, then placeholder.
        let label = [attr(kAXDescriptionAttribute as String, cap: 140),
                     attr(kAXTitleAttribute as String, cap: 140),
                     attr("AXPlaceholderValue", cap: 140)].first { !$0.isEmpty } ?? ""
        let value = attr(kAXValueAttribute as String, cap: 800)
        let selected = attr(kAXSelectedTextAttribute as String, cap: 800)

        let ctx = FocusedContext(role: role, roleDescription: roleDesc,
                                 label: label, value: value, selectedText: selected)
        return ctx.isMeaningful ? ctx : nil
    }

    // MARK: - AX text extraction

    private func extractTextViaAccessibility() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        // When Holmes is frontmost, skip AX — fall through to screenshot which
        // now excludes Holmes windows, so OCR sees only the background app.
        let frontName = app.localizedName?.lowercased() ?? ""
        guard !frontName.contains("holmes") else { return "" }
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
