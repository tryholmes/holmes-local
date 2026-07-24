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

// MARK: - ScreenReading

/// A STRUCTURED Accessibility reading — richer than a flat blob of text so the
/// LiveContext builder can phrase a specific headline (file + line + symbol, or
/// cwd + command) instead of dumping raw text and hoping a classifier recovers
/// the facts. Every field here was read from a TARGETED AX attribute, which is
/// why the builder is allowed to raise it to `.structural` confidence.
///
/// `kind` records which family of app produced it; the builder trusts the
/// per-kind fields (fileName/command/…) over anything scraped from `bodyText`.
struct ScreenReading {
    enum Kind: String { case editor, terminal, chat, generic }

    var appName: String
    var windowTitle: String
    /// Human-visible text (editor buffer, terminal scrollback tail, or a deep
    /// walk for generic apps). Capped; safe to quote (never OCR mush).
    var bodyText: String
    var kind: Kind

    // Editors (Xcode / VS Code / Cursor)
    var documentPath: String?   // AXDocument — full on-disk path of the open file
    var fileName: String?       // basename of documentPath, or parsed from the title
    var workspace: String?      // project / folder ("holmes"), from the window title
    var symbol: String?         // nearest enclosing declaration at the caret ("struct FocusedContext")
    var lineNumber: Int?        // 1-based caret line, from AXInsertionPointLineNumber
    var selectedText: String?   // current selection, if any

    // Terminals (Ghostty / Terminal / iTerm2 / Alacritty / kitty / WezTerm …)
    var command: String?        // the command on the last prompt line
    var workingDir: String?     // cwd, from the window title or the prompt (home → ~)

    // Web-hosting native views
    var url: String?            // AXURL, when the app exposes one

    // Native chat apps (Messages / WhatsApp / Discord / Slack / Telegram / Signal)
    var contact: String?        // conversation / chat title (the person or room)
    var lastMessage: String?    // text of the most recent visible bubble

    init(appName: String, windowTitle: String, bodyText: String = "", kind: Kind = .generic,
         documentPath: String? = nil, fileName: String? = nil, workspace: String? = nil,
         symbol: String? = nil, lineNumber: Int? = nil, selectedText: String? = nil,
         command: String? = nil, workingDir: String? = nil, url: String? = nil,
         contact: String? = nil, lastMessage: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.bodyText = bodyText
        self.kind = kind
        self.documentPath = documentPath
        self.fileName = fileName
        self.workspace = workspace
        self.symbol = symbol
        self.lineNumber = lineNumber
        self.selectedText = selectedText
        self.command = command
        self.workingDir = workingDir
        self.url = url
        self.contact = contact
        self.lastMessage = lastMessage
    }

    /// True when the reading carries enough to describe the screen — either a
    /// meaningful body OR a targeted structural fact (open file, running command,
    /// cwd, url). Xcode with a tiny file, or a terminal at a bare prompt, still
    /// qualifies via the structural fields even when `bodyText` is thin.
    var isUsable: Bool {
        bodyText.count > 100
            || fileName != nil
            || command != nil
            || (workingDir?.isEmpty == false)
            || ((url?.count ?? 0) > 8)
            || lastMessage != nil       // a native chat transcript was read
    }
}

// MARK: - VisionEncoder

/// Screenshot → base64 JPEG, for the rare tick where text falls short and the
/// pixels have to go to Claude (Opus 4.8 is a vision model). Non-isolated on
/// purpose: the downscale + encode is tens of milliseconds and must run off the
/// main actor, so callers hop to a background queue and call this there.
enum VisionEncoder {
    /// Downscales to `maxDimension` on the long edge and JPEG-encodes.
    /// ~1024px keeps UI text legible while staying small enough to upload fast.
    static func encode(_ cgImage: CGImage,
                       maxDimension: CGFloat = 1024,
                       quality: CGFloat = 0.6) -> String? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        guard w > 1, h > 1 else { return nil }
        let scale = min(1, maxDimension / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]) else { return nil }
        return jpeg.base64EncodedString()
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
    let reading: ScreenReading? // structured AX reading (native apps); nil on the OCR path
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
                // 120ms: long enough for the new app's key window + AX tree to
                // exist, short enough that context feels instant. (350ms was a
                // third of a second of guaranteed staleness on every cmd-tab.)
                try? await Task.sleep(nanoseconds: 120_000_000)
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
            // Pin to the MAIN display. SCShareableContent.displays ordering is not
            // guaranteed to lead with CGMainDisplayID, and WindowCapture derives the
            // computer-use coordinate geometry from CGMainDisplayID() — if the two
            // pick different displays on a multi-monitor setup, every model
            // coordinate maps to the wrong screen and clicks land in the wrong place.
            // Capturing the main display keeps pixels and geometry on one surface.
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { return }
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
            let reading = extractAccessibilityReading(windowTitle: title)
            let axText = reading?.bodyText ?? ""

            // Fast path: a usable structured AX reading (native apps). Deliver
            // IMMEDIATELY — no screenshot, no suspension. Vision, when it's actually
            // wanted, is captured on demand during enrichment
            // (grabScreenshotForVision), so the common native path stays instant and
            // never burns a full-display capture per tick.
            if let reading, reading.isUsable {
                print("[Holmes] AX(\(reading.kind.rawValue)): \(axText.count) chars — file=\(reading.fileName ?? "-") cmd=\(reading.command ?? "-") cwd=\(reading.workingDir ?? "-") sym=\(reading.symbol ?? "-")")
                latestOCROverride = axText.isEmpty ? nil : axText
                onNewSnapshot?(CaptureResult(image: nil, appName: app, windowTitle: title,
                                             axOverride: axText.isEmpty ? nil : axText,
                                             reading: reading, focused: focused, visionUsable: false))
                return
            }

            // No usable AX text — screenshot for OCR (Electron apps like Comet).
            latestOCROverride = nil
            if let image = await captureScreen() {
                let blank = isLikelyBlank(image)
                if !blank { latestSnapshot = image }
                print("[Holmes] SCK image: \(image.width)x\(image.height)px\(blank ? " (blank)" : "")")
                onNewSnapshot?(CaptureResult(image: image, appName: app, windowTitle: title,
                                             axOverride: nil, reading: nil,
                                             focused: focused, visionUsable: !blank))
            } else {
                // Capture unavailable (Screen Recording permission usually goes stale
                // after an Xcode rebuild). NEVER dead-end here — that leaves the panel
                // frozen on "Analyzing your screen…". Fire with whatever AX gave us, or
                // a marker so the UI shows a clear "grant permission" message instead.
                print("[Holmes] Capture failed — Screen Recording permission may be stale; firing fallback so the UI never freezes")
                latestOCROverride = axText.isEmpty ? "__NO_SCREEN_ACCESS__" : axText
                onNewSnapshot?(CaptureResult(image: nil, appName: app, windowTitle: title,
                                             axOverride: latestOCROverride, reading: reading,
                                             focused: focused, visionUsable: false))
            }
        }
    }

    /// Captures a fresh, non-blank screenshot on demand — used by the enrichment
    /// path to escalate to vision on the AX/native path (where captureNow()
    /// deliberately skips the screenshot to stay fast). Returns nil on a
    /// failed or blank capture, so vision never runs on black pixels.
    func grabScreenshotForVision(targetDisplayID: CGDirectDisplayID? = nil) async -> CGImage? {
        guard let image = await captureScreen(targetDisplayID: targetDisplayID), !isLikelyBlank(image) else { return nil }
        return image
    }

    // MARK: - SCK capture (uses cached filter — no permission re-prompt)

    private func captureScreen(targetDisplayID: CGDirectDisplayID? = nil) async -> CGImage? {
        guard #available(macOS 13.0, *) else { return nil }
        // If permission was granted AFTER launch, the cache is still empty — rebuild
        // it now so capture starts working without needing an app restart.
        if cachedConfig == nil { await buildSCKCache() }
        guard cachedConfig != nil else {
            print("[Holmes] No capture config — Screen Recording permission missing")
            return nil
        }
        do {
            // Rebuild filter each capture to exclude Holmes windows — no permission re-prompt,
            // just refreshes window list so OCR only sees the background app.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // The requested display (the one the user is looking at — cursor display for
            // the vision/computer-use path), falling back to main. Capture + geometry
            // must agree on this display or coordinates map to the wrong screen.
            let wantID = targetDisplayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == wantID })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { return nil }
            let holmesWindows = content.windows.filter {
                let bid = $0.owningApplication?.bundleIdentifier ?? ""
                let name = $0.owningApplication?.applicationName.lowercased() ?? ""
                return bid.contains("holmes") || name.contains("holmes")
            }
            let filter = SCContentFilter(display: display, excludingWindows: holmesWindows)
            // Size the config to THIS display — the cached config is sized to the main
            // display, so reusing it for a differently-sized monitor would rescale and
            // distort the capture (and desync the declared pixel dims).
            let config = SCStreamConfiguration()
            config.width  = display.width
            config.height = display.height
            config.showsCursor = false
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

    // MARK: - AX text extraction (structured, app-aware)
    //
    // COST MODEL. Every AXUIElementCopyAttributeValue is a synchronous IPC
    // round-trip into the target app: a scalar attribute is ~0.05–0.5ms, a large
    // string value (a whole source file, terminal scrollback) a few ms. This runs
    // on the 3s loop, so the rule is: read TARGETED attributes for the app family
    // we recognise (a handful of reads, no tree walk), and only fall back to a
    // BUDGETED deep walk (capped nodes + chars) for generic apps.

    /// Bounds a single AX subtree walk so a pathological hierarchy (Slack, a giant
    /// web view) can't stall the loop. Any breach stops the walk immediately.
    ///   maxNodes    3000 — each node costs up to 3 reads (value, title, children)
    ///                       ⇒ ≤ ~9k IPC calls worst case (~a few ms); the char cap
    ///                       almost always trips first on a text-heavy app.
    ///   maxChars   12000 — enough to describe any screen; hard ceiling on cost.
    ///   maxDepth      60 — native trees (Xcode, Slack) are genuinely deep; the
    ///                       node/char caps are the real guards, so depth is generous.
    ///   maxChildren  120 — skip only absurdly wide containers (long lists/tables).
    private final class Budget {
        private(set) var nodes = 0
        private(set) var chars = 0
        let maxNodes: Int, maxChars: Int, maxDepth: Int, maxChildren: Int
        init(maxNodes: Int = 3000, maxChars: Int = 12_000, maxDepth: Int = 60, maxChildren: Int = 120) {
            self.maxNodes = maxNodes; self.maxChars = maxChars
            self.maxDepth = maxDepth; self.maxChildren = maxChildren
        }
        var exhausted: Bool { nodes >= maxNodes || chars >= maxChars }
        func visit() { nodes += 1 }
        func add(_ n: Int) { chars += n }
    }

    // MARK: AX read helpers (one IPC round-trip each)

    private func axCopy(_ element: AXUIElement?, _ attribute: String) -> CFTypeRef? {
        guard let element else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }
    private func axString(_ element: AXUIElement?, _ attribute: String) -> String? {
        guard let ref = axCopy(element, attribute) else { return nil }
        if let s = ref as? String { return s }
        // AXDocument / AXURL sometimes return a URL rather than a bare path string.
        if let url = ref as? NSURL { return url.path ?? url.absoluteString }
        return nil
    }
    private func axElement(_ element: AXUIElement?, _ attribute: String) -> AXUIElement? {
        guard let ref = axCopy(element, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
    private func axElements(_ element: AXUIElement?, _ attribute: String) -> [AXUIElement] {
        (axCopy(element, attribute) as? [AXUIElement]) ?? []
    }
    private func axInt(_ element: AXUIElement?, _ attribute: String) -> Int? {
        guard let ref = axCopy(element, attribute) else { return nil }
        if let n = ref as? Int { return n }
        if let n = ref as? NSNumber { return n.intValue }
        return nil
    }
    private func axRole(_ element: AXUIElement?) -> String { axString(element, kAXRoleAttribute as String) ?? "" }

    // MARK: Family routing

    private enum AppFamily { case xcode, terminal, electronEditor, chat, generic }

    private func appFamily(name: String, bundleID: String) -> AppFamily {
        let n = name.lowercased(), b = bundleID.lowercased()
        if b == "com.apple.dt.xcode" || n == "xcode" { return .xcode }
        let terminals = ["ghostty", "terminal", "iterm", "alacritty", "kitty", "wezterm", "warp", "tabby", "hyper"]
        if terminals.contains(where: { n.contains($0) || b.contains($0) }) { return .terminal }
        // VS Code family (VS Code, Cursor, VSCodium, Windsurf) — Electron editors.
        if b.contains("com.microsoft.vscode") || b.contains("com.vscodium")
            || b.contains("com.todesktop")            // Cursor ships under todesktop.*
            || n == "code" || n == "cursor" || n.contains("vscodium") || n.contains("windsurf") {
            return .electronEditor
        }
        // Native chat apps (Messages / WhatsApp / Discord / Slack / Telegram /
        // Signal). Read via Accessibility exactly like Messages, not OCR — the
        // app-identity table is MessagesReader's, the single source of truth.
        if MessagesReader.chatAppDisplayName(name: name, bundleID: bundleID) != nil { return .chat }
        return .generic
    }

    /// The single entry point: a structured reading of the frontmost app, or nil
    /// when Holmes is frontmost / nothing readable is exposed.
    private func extractAccessibilityReading(windowTitle: String) -> ScreenReading? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = app.localizedName ?? ""
        // When Holmes is frontmost, skip AX — fall through to screenshot which
        // now excludes Holmes windows, so OCR sees only the background app.
        guard !appName.lowercased().contains("holmes") else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Two cheap targeted reads shared by every family.
        let window = axElement(axApp, kAXFocusedWindowAttribute as String)
        let focused = axElement(axApp, kAXFocusedUIElementAttribute as String)

        var reading = ScreenReading(appName: appName, windowTitle: windowTitle, kind: .generic)

        switch appFamily(name: appName, bundleID: bundleID) {
        case .xcode:          extractXcode(window: window, focused: focused, into: &reading)
        case .terminal:       extractTerminal(window: window, focused: focused, into: &reading)
        case .electronEditor: extractElectronEditor(window: window, focused: focused, into: &reading)
        case .chat:           extractChat(into: &reading)
        case .generic:        extractGeneric(window: window, focused: focused, into: &reading)
        }

        return reading.isUsable ? reading : nil
    }

    // MARK: Xcode

    /// Xcode exposes the open file via the window's AXDocument, the caret line via
    /// AXInsertionPointLineNumber on the source editor's AXTextArea, and the buffer
    /// via that text area's AXValue. All targeted — no tree walk unless focus is
    /// off the editor (navigator, etc.), where a small budgeted walk gives a body.
    private func extractXcode(window: AXUIElement?, focused: AXUIElement?, into r: inout ScreenReading) {
        r.kind = .editor

        // Open document path — one read (AXDocument on the focused window).
        if let doc = axString(window, kAXDocumentAttribute as String) {
            let path = doc.hasPrefix("file://") ? (URL(string: doc)?.path ?? doc) : doc
            r.documentPath = path
            r.fileName = (path as NSString).lastPathComponent
        }
        if r.fileName == nil { r.fileName = LiveContextFormat.fileName(inWindowTitle: r.windowTitle) }
        r.workspace = Self.workspaceName(fromTitle: r.windowTitle, fileName: r.fileName)

        // Caret line + buffer, only when focus is actually the source editor.
        if let focused, axRole(focused) == "AXTextArea" {
            if let raw = axInt(focused, "AXInsertionPointLineNumber") { r.lineNumber = raw + 1 } // 0-based → 1-based
            if let sel = axString(focused, kAXSelectedTextAttribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sel.isEmpty { r.selectedText = String(sel.prefix(300)) }
            if let value = axString(focused, kAXValueAttribute as String), !value.isEmpty {
                r.bodyText = String(value.prefix(16_000))
                if let line = r.lineNumber {
                    r.symbol = Self.enclosingSymbol(in: value, caretLine1Based: line)
                }
            }
        }

        // Focus is off the editor (issue navigator, jump bar…) — give a budgeted
        // body so the reading is still usable and the classifier has material.
        if r.bodyText.isEmpty, let window {
            var lines: [String] = []
            collectText(from: window, into: &lines, budget: Budget(maxChars: 6000))
            r.bodyText = lines.joined(separator: "\n")
        }
    }

    // MARK: Terminals

    /// Terminals expose their visible screen through an AXTextArea (its AXValue is
    /// the on-screen text, bounded — NOT the megabyte scrollback) or, failing that,
    /// through AXStaticText rows. The last ~40 non-empty lines are the prompt +
    /// recent output the user is actually looking at. cwd + command come from the
    /// window title first (terminals conventionally put them there) then the prompt.
    private func extractTerminal(window: AXUIElement?, focused: AXUIElement?, into r: inout ScreenReading) {
        r.kind = .terminal

        var textArea: AXUIElement?
        if let focused, axRole(focused) == "AXTextArea" { textArea = focused }
        if textArea == nil, let window { textArea = findFirstTextArea(in: window, depth: 6) }

        var screen = ""
        if let textArea {
            screen = axString(textArea, kAXValueAttribute as String) ?? ""
            if screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Some terminals only expose AXStaticText children (one per row).
                var lines: [String] = []
                collectText(from: textArea, into: &lines, budget: Budget(maxChars: 8000))
                screen = lines.joined(separator: "\n")
            }
        } else if let window {
            var lines: [String] = []
            collectText(from: window, into: &lines, budget: Budget(maxChars: 8000))
            screen = lines.joined(separator: "\n")
        }

        let tail = Array(screen
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00a0}", with: " ")
                     .trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
            .suffix(40))
        r.bodyText = tail.joined(separator: "\n")

        r.workingDir = Self.cwd(fromTitle: r.windowTitle) ?? Self.cwd(fromPrompt: tail)
        r.command = Self.command(fromPrompt: tail)
        if let dir = r.workingDir { r.workingDir = Self.abbreviateHome(dir) }
    }

    // MARK: Electron editors (VS Code / Cursor)

    /// Electron exposes the editor as an AXTextArea. The document identity lives in
    /// the WINDOW TITLE ("file — folder — Visual Studio Code"), not AXDocument.
    private func extractElectronEditor(window: AXUIElement?, focused: AXUIElement?, into r: inout ScreenReading) {
        r.kind = .editor
        r.fileName = Self.fileName(fromEditorTitle: r.windowTitle)
        r.workspace = Self.workspaceName(fromTitle: r.windowTitle, fileName: r.fileName)

        if let focused, axRole(focused) == "AXTextArea" {
            if let raw = axInt(focused, "AXInsertionPointLineNumber") { r.lineNumber = raw + 1 }
            if let sel = axString(focused, kAXSelectedTextAttribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sel.isEmpty { r.selectedText = String(sel.prefix(300)) }
            if let value = axString(focused, kAXValueAttribute as String), !value.isEmpty {
                r.bodyText = String(value.prefix(16_000))
                if let line = r.lineNumber {
                    r.symbol = Self.enclosingSymbol(in: value, caretLine1Based: line)
                }
            }
        }
        if r.bodyText.isEmpty, let window {
            var lines: [String] = []
            collectText(from: window, into: &lines, budget: Budget(maxChars: 6000))
            r.bodyText = lines.joined(separator: "\n")
        }
    }

    // MARK: Native chat apps (Messages / WhatsApp / Discord / Slack / Telegram / Signal)

    /// Reads the conversation on screen through MessagesReader — the SAME
    /// fail-closed AX transcript logic the incoming-reply watcher uses: find the
    /// right-pinned transcript pane, collect the AXStaticText bubbles, attribute
    /// from-me by right-edge margin (right = me), filter timestamps/receipts.
    /// Delegating keeps ONE place that knows how to read a native chat transcript.
    ///
    /// FRAGILE by nature (undocumented, per-app AX trees that shift between
    /// releases): when the tree doesn't match, MessagesReader returns nil, this
    /// leaves `contact`/`lastMessage` unset, `isUsable` stays false, and the
    /// capture falls through to the generic walk / OCR rather than inventing a
    /// conversation or a from-me/from-them attribution.
    private func extractChat(into r: inout ScreenReading) {
        r.kind = .chat
        guard let thread = MessagesReader.shared.readFrontmostThread(),
              let last = thread.messages.last else { return }  // fail closed

        let raw = thread.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        // A "Message yourself" chat titles the window with the account's own
        // name / "You"; phrase that as "yourself" rather than echoing the name.
        r.contact = Self.selfChatContact(raw) ?? (raw.isEmpty ? nil : raw)
        r.lastMessage = last.text

        // A clean transcript for prompt-building (never OCR mush). Attribution
        // is the reader's right=me heuristic, trusted verbatim.
        let who = raw.isEmpty ? "Them" : raw
        r.bodyText = thread.messages
            .map { "\($0.isFromMe ? "Me" : who): \($0.text)" }
            .joined(separator: "\n")
    }

    /// "yourself" when a chat title names the user themself — WhatsApp's
    /// "Message yourself" titles the window with the account's own name or
    /// "You". Presentation only: the reader returns the literal title, this
    /// decides how the headline phrases it. Returns nil for a real contact.
    static func selfChatContact(_ title: String) -> String? {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a trailing "(You)" marker some clients append.
        if let paren = t.range(of: "(you)", options: [.caseInsensitive, .backwards]) {
            t = String(t[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let low = t.lowercased()
        if low.isEmpty { return title.isEmpty ? nil : "yourself" }
        if ["you", "me", "myself"].contains(low) { return "yourself" }
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces).lowercased()
        if !full.isEmpty, low == full { return "yourself" }
        if let first = full.split(separator: " ").first.map(String.init),
           first.count >= 3, low == first { return "yourself" }
        return nil
    }

    // MARK: Generic (Finder, Notes, Slack, Messages …)

    private func extractGeneric(window: AXUIElement?, focused: AXUIElement?, into r: inout ScreenReading) {
        r.kind = .generic
        var lines: [String] = []
        if let window { collectText(from: window, into: &lines, budget: Budget()) }
        r.bodyText = lines.joined(separator: "\n")
        if let sel = axString(focused, kAXSelectedTextAttribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sel.isEmpty { r.selectedText = String(sel.prefix(300)) }
        // Harmless when absent: Safari-family web views expose the page URL here.
        if let url = axString(window, "AXURL"), url.count > 8 { r.url = url }
    }

    // MARK: Tree helpers

    private func findFirstTextArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth < 0 { return nil }
        if axRole(element) == "AXTextArea" { return element }
        for child in axElements(element, kAXChildrenAttribute as String).prefix(40) {
            if let hit = findFirstTextArea(in: child, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// Budgeted depth-first text walk. One value read (fall back to one title read)
    /// per node, then recurse — stopping the instant the node or char cap is hit.
    private func collectText(from element: AXUIElement, into result: inout [String], budget: Budget, depth: Int = 0) {
        guard depth < budget.maxDepth, !budget.exhausted else { return }
        budget.visit()

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let s = ref as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.count < 5000 { result.append(t); budget.add(t.count) }
        } else if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success,
                  let s = ref as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.count < 1000 { result.append(t); budget.add(t.count) }
        }
        if budget.exhausted { return }

        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children.prefix(budget.maxChildren) {
            if budget.exhausted { return }
            collectText(from: child, into: &result, budget: budget, depth: depth + 1)
        }
    }

    // MARK: Deterministic parsing (pure — unit-testable, no AX)

    /// The nearest enclosing declaration at or above the caret line, e.g.
    /// "struct FocusedContext", "func captureNow", "extension FocusedField".
    /// Scans upward from the caret; restricted to type/function keywords so a
    /// local `let` doesn't masquerade as the symbol the user is inside.
    static func enclosingSymbol(in text: String, caretLine1Based line: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty, line >= 1 else { return nil }
        let start = min(line, lines.count) - 1
        for i in stride(from: start, through: 0, by: -1) {
            if let sym = declaration(in: lines[i]) { return sym }
        }
        return nil
    }

    private static let declKeywords = ["struct", "class", "enum", "protocol", "extension",
                                       "actor", "func", "init", "subscript"]

    /// "  public struct FocusedContext {" → "struct FocusedContext".
    /// "    func captureNow() {"           → "func captureNow".
    private static func declaration(in rawLine: String) -> String? {
        let words = rawLine
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        for (idx, word) in words.enumerated() where declKeywords.contains(word) {
            if word == "init" || word == "subscript" { return word }
            guard idx + 1 < words.count else { continue }
            let nameToken = words[idx + 1]
            // Trim trailing punctuation/generics/signature: "FocusedContext<" → "FocusedContext".
            let name = nameToken.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            return "\(word) \(name)"
        }
        return nil
    }

    // The prompt sigil sits BEFORE the command; each already carries a trailing
    // space so it can't match "$VAR"/"80%" glued to the next character. Only "% "
    // additionally requires a leading word boundary, because a percentage in output
    // ("Coverage: 80% done") otherwise reads as a zsh prompt — whereas default bash
    // glues "$" to the path ("~/dev/holmes$ "), so "$"/"#" must NOT require one.
    private static let promptMarkers: [(sigil: String, needsLeadingBoundary: Bool)] = [
        ("❯ ", false), ("➜ ", false), ("▶ ", false), ("» ", false), ("› ", false),
        ("$ ", false), ("# ", false), ("% ", true)
    ]

    /// The command on the last prompt line of a terminal, e.g. from
    /// "~/dev/holmes ❯ npm test" → "npm test". Literal text after the prompt sigil;
    /// nil when the bottom prompt is bare (nothing being run). Per line we take the
    /// EARLIEST valid sigil (the prompt precedes the command) and scan the tail
    /// bottom-up, returning the first line that yields a command.
    static func command(fromPrompt tail: [String]) -> String? {
        for line in tail.reversed() {
            var earliest: String.Index?
            var markerLen = 0
            for (sigil, needsBoundary) in promptMarkers {
                var from = line.startIndex
                while let range = line.range(of: sigil, range: from..<line.endIndex) {
                    let boundary = range.lowerBound == line.startIndex
                        || line[line.index(before: range.lowerBound)].isWhitespace
                    if !needsBoundary || boundary {
                        if earliest == nil || range.lowerBound < earliest! {
                            earliest = range.lowerBound; markerLen = sigil.count
                        }
                        break
                    }
                    from = range.upperBound
                }
            }
            if let earliest {
                let cmd = String(line[line.index(earliest, offsetBy: markerLen)...])
                    .trimmingCharacters(in: .whitespaces)
                if cmd.count >= 2 { return String(cmd.prefix(120)) }
            }
        }
        return nil
    }

    /// A working directory parsed from a prompt line — a path-shaped token
    /// (starts with ~ or /, or contains a slash) sitting before the prompt marker.
    static func cwd(fromPrompt tail: [String]) -> String? {
        let markers: [Character] = ["❯", "➜", "▶", "»", "›", "$", "%", "#"]
        for line in tail.reversed() {
            let head: Substring
            if let markerIdx = line.firstIndex(where: { markers.contains($0) }) {
                head = line[..<markerIdx]
            } else {
                head = Substring(line)
            }
            // "user@host:~/dev/holmes" → take the part after the colon.
            let segment = head.split(separator: ":").last.map(String.init) ?? String(head)
            for token in segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).reversed() {
                if token.hasPrefix("~") || token.hasPrefix("/") || token.contains("/") {
                    return token
                }
            }
        }
        return nil
    }

    /// A working directory carried in a terminal's window title — the first
    /// path-shaped component. Titles look like "holmes — -zsh — 80×24",
    /// "~/dev/holmes", or "user@host: ~/dev/holmes".
    static func cwd(fromTitle title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // "user@host: ~/dev/holmes" → everything after the colon.
        let afterColon = t.contains(": ") ? String(t[t.range(of: ": ")!.upperBound...]) : t
        let parts = afterColon
            .components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }) }
            .map(String.init)
        for part in parts where part.hasPrefix("~") || part.hasPrefix("/") {
            return part
        }
        return nil
    }

    /// Replaces the user's home-directory prefix with "~".
    static func abbreviateHome(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The filename in an Electron editor title: its first " — " segment, minus a
    /// leading dirty marker ("● file.ts — folder" → "file.ts"). Falls back to the
    /// generic file-in-title regex.
    static func fileName(fromEditorTitle title: String) -> String? {
        let first = title
            .components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " ●•*·◦"))
            ?? ""
        if first.range(of: "\\.[A-Za-z0-9]{1,6}$", options: .regularExpression) != nil, !first.contains("/") {
            return first
        }
        return LiveContextFormat.fileName(inWindowTitle: title)
    }

    /// The project/folder name from an editor window title — the first segment
    /// that is neither the filename nor a noise word ("Edited", the app name, a
    /// terminal size like "80×24"). Xcode "ScreenEngine.swift — Edited — holmes"
    /// and VS Code "ScreenEngine.swift — holmes — Visual Studio Code" both → "holmes".
    static func workspaceName(fromTitle title: String, fileName: String?) -> String? {
        let noise: Set<String> = ["edited", "xcode", "visual studio code", "code",
                                  "cursor", "vscodium", "windsurf", "ready", "updated"]
        let parts = title
            .components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ●•*·◦")) }
            .filter { !$0.isEmpty }
        for part in parts {
            let low = part.lowercased()
            if let fileName, part == fileName { continue }
            if part.range(of: "\\.[A-Za-z0-9]{1,6}$", options: .regularExpression) != nil, !part.contains("/") {
                continue // looks like a filename
            }
            if noise.contains(low) { continue }
            if part.range(of: "^\\d+\\s*[×xX]\\s*\\d+$", options: .regularExpression) != nil { continue } // 80×24
            return part
        }
        return nil
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
