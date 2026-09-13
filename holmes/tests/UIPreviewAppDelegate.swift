// Used ONLY by render-ui-previews.sh, which copies this file over AppDelegate
// in a temporary project. Never add it to the production Xcode target.
import AppKit
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var report: [[String: Any]] = []
    private var outputDirectory: URL!
    private let glassMode = ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_GLASS"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_OUTPUT"],
              Bundle.main.bundleIdentifier?.hasPrefix("com.zeroprompt.holmes.ui-preview.") == true else {
            fputs("Refusing preview launch without an isolated bundle and output directory.\n", stderr)
            exit(2)
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        // Fixture values live in the process's argument domain, above the unique
        // preview application domain. Nothing is saved to the user's Holmes prefs.
        UserDefaults.standard.setVolatileDomain([
            "ollama.host": "http://127.0.0.1:11434",
            "ollama.model": "qwen3-vl:4b-instruct",
            "ollama.autoStartServer": false,
            "ollama.numCtx": 32768,
            "ollama.keepAlive": "10m",
            "ollama.thinkingEnabled": false,
            "com.grain.holmes.autonomy.masterEnabled": false,
            "com.grain.holmes.computerUse.enabled": false
        ], forName: UserDefaults.argumentDomain)
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try registerFonts()
        } catch { fail(error) }
        Task { @MainActor in
            do {
                try await renderFixtures()
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: outputDirectory.appendingPathComponent("previews.json"))
                print("UI previews saved to \(outputDirectory.path)")
                NSApp.terminate(nil)
            } catch { fail(error) }
        }
    }

    // No production start/stop handlers, menus, hotkeys, microphone, screen
    // capture, agent, calendar, MCP, or Ollama monitor are initialized here.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerFonts() throws {
        var rows: [[String: Any]] = []
        if let resourceURL = Bundle.main.resourceURL,
           let files = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil) {
            for case let url as URL in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                var error: Unmanaged<CFError>?
                let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                for descriptor in descriptors {
                    let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? "unknown"
                    rows.append(["file": url.lastPathComponent, "name": name,
                                 "registered": registered, "available": NSFont(name: name, size: 14) != nil])
                }
                if let error { _ = error.takeRetainedValue() }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("fonts.json"))
        print("Preview fonts: \(rows.count) faces, \(rows.filter { $0["available"] as? Bool == true }.count) available")
    }

    private func renderFixtures() async throws {
        if glassMode {
            try await render("glass-surfaces", size: CGSize(width: 720, height: 420), view:
                ZStack {
                    AppleGlassBackground(cornerRadius: 18)
                    VStack(alignment: .leading, spacing: 24) {
                        Text("holmes").font(NoirFonts.brand(size: 36))
                        Text("Window glass").font(NoirFonts.title())
                        Text("The colored backdrop should remain visible through every surface.")
                            .font(NoirFonts.body())
                        HStack(spacing: 20) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Approval card").font(NoirFonts.title())
                                    Text("Readable text over frosted glass.").font(NoirFonts.body())
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .padding(16)
                            }
                            ZStack {
                                HeavyGlassBackground(cornerRadius: 12)
                                Text("Elevated glass").font(NoirFonts.title())
                            }
                            .frame(maxWidth: .infinity, minHeight: 152)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(NoirColors.textPrimary)
                    .padding(24)
                })
        }
        // Viewing this pane only synchronizes fields; no refresh/download button
        // is invoked. The disconnected initial status is intentional fixture data.
        try await render("settings-local-model", size: CGSize(width: 680, height: 620), view: SettingsView())
        try await render("settings-local-model-minimum", size: CGSize(width: 640, height: 520), view: SettingsView())
        if ProcessInfo.processInfo.environment["HOLMES_UI_PREVIEW_EXPAND_ADVANCED"] == "1" {
            try await render("settings-advanced-top", size: CGSize(width: 680, height: 620),
                             view: SettingsView(), scrollOffset: 340)
            try await render("settings-advanced-bottom", size: CGSize(width: 680, height: 620),
                             view: SettingsView(), scrollOffset: 780)
        }
        if !glassMode {
            try await render("local-model-compact", size: CGSize(width: 450, height: 460),
                             view: LocalModelSettingsView(compact: true))
        }

        let bus = ConfirmationBus.shared
        // Assign directly: propose()/proposeDraft() would show real controller
        // windows. No handler is installed and no action is approved or executed.
        bus.pendingAction = PendingAction(
            title: "Review the next step", preview: "Open the selected project in your editor.\n\nThis is fixture copy for visual review; no action will run.",
            appName: "Your Mac", actionType: .agentToolCall)
        try await render("review-action", size: CGSize(width: 420, height: 410),
                         view: ScrollView { ConfirmationView() })
        bus.pendingAction = nil
        bus.pendingDraft = ProactiveDraft(
            playbookId: "preview-reply", kind: .chatReply, title: "Reply to Alex",
            body: "sounds good — I’ll share the updated design after checking the layout and text on a few window sizes.",
            contextSummary: "Messages · conversation with Alex", target: .clipboard)
        try await render("review-draft", size: CGSize(width: 420, height: 520),
                         view: ScrollView { ConfirmationView() })
        bus.pendingDraft = nil

        let incoming = ReplyComposer.IncomingMessage(surface: ReplyComposer.surfaceIMessage,
            sender: "Alex", text: "hey, what is holmes?", threadID: "preview-only", app: "Messages")
        let memory = MemoryEvent(id: 9001, date: Date().addingTimeInterval(-3600), kind: "context",
            app: "Browser", windowTitle: "holmes project", activity: "reading",
            summary: "Reading the holmes project overview", detail: "Synthetic preview fixture",
            source: "browserExtension", confidence: "exact", site: "github.com",
            entitiesJSON: "{\"repo\":\"tryholmes/holmes-local\"}")
        let reply = ReplyComposer.DraftedReply(
            body: "it’s a local macOS assistant that understands what’s on your screen and prepares useful next steps for you to review.",
            groundedIn: [memory], background: [], confidence: .exact,
            recallHits: [MemoryStore.RecallHit(event: memory, score: 0.9, matchedOn: "project entity")], topics: ["holmes"])
        try await render("reply-ready", size: CGSize(width: 420, height: 540),
                         view: ScrollView { ReplyReadyCard(draft: reply, incoming: incoming) })
        let unsourced = ReplyComposer.DraftedReply(body: "let me check and get back to you", groundedIn: [],
            background: [], confidence: .inferred, recallHits: [], topics: ["holmes"])
        try await render("reply-unsourced", size: CGSize(width: 420, height: 540),
                         view: ScrollView { ReplyReadyCard(draft: unsourced, incoming: incoming) })

        // The notch intentionally stays black to match the physical cutout.
        // Its offscreen geometry previews are independent of desktop glass.
        if glassMode { return }
        let geometry = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 910),
            safeAreaTop: 32, leftAreaWidth: 660, rightAreaWidth: 660)
        let vm = NotchViewModel(geometry: geometry)
        vm.contextLine = "Reviewing the holmes design and checking the next implementation steps"
        vm.contextSymbol = "doc.text"
        vm.taskActive = true
        vm.taskStep = "Checking that the text and controls stay below the camera housing"
        vm.taskProgress = 0.6
        vm.open()
        try await render("notch-expanded", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.close()
        try await render("notch-task", size: geometry.windowSize, view: NotchView(vm: vm))
        vm.taskActive = false
        vm.sneakPeek = NotchSneakPeek(show: true, title: "Reading a document", subtitle: vm.contextLine, symbol: "doc.text")
        try await render("notch-context", size: geometry.windowSize, view: NotchView(vm: vm))
    }

    private func render<V: View>(_ name: String, size: CGSize, view: V,
                                 scrollOffset: CGFloat? = nil) async throws {
        // Default mode keeps the existing offscreen layout/font snapshots.
        // Glass mode needs the WindowServer compositor: an opaque synthetic
        // backdrop covers the entire captured area behind a clear fixture host.
        // Both windows ignore input and cannot activate; no controls are clicked.
        let farEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        var frame = CGRect(x: farEdge + 4096, y: 0, width: size.width, height: size.height)
        let margin: CGFloat = glassMode ? 24 : 0
        if glassMode {
            guard let screen = NSScreen.screens.max(by: {
                $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height
            }), screen.visibleFrame.width >= size.width + margin * 2,
                screen.visibleFrame.height >= size.height + margin * 2 else {
                throw PreviewError.screenTooSmall(name)
            }
            frame.origin = CGPoint(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                                   y: (screen.visibleFrame.midY - size.height / 2).rounded())
        }
        let window = UIPreviewWindow(contentRect: frame,
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = glassMode ? .clear : NSColor(hex: "060606")
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        var backdrop: UIPreviewWindow?
        if glassMode {
            let backing = UIPreviewWindow(contentRect: frame.insetBy(dx: -margin, dy: -margin),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
            backing.isReleasedWhenClosed = false
            backing.ignoresMouseEvents = true
            backing.isOpaque = true
            backing.backgroundColor = .black
            backing.hasShadow = false
            backing.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 10)
            backing.contentView = UIPreviewBackdropView(frame: CGRect(origin: .zero, size: backing.frame.size))
            backing.orderFrontRegardless()
            backdrop = backing
            window.level = NSWindow.Level(rawValue: backing.level.rawValue + 1)
        }
        let host = NSHostingView(rootView:
            ZStack(alignment: .top) {
                if !glassMode { Color(hex: "060606") }
                view
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .preferredColorScheme(.dark))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        windows.append(window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            backdrop?.orderOut(nil)
            backdrop?.contentView = nil
            windows.removeAll { $0 === window }
        }
        window.orderFrontRegardless()
        // Settle SwiftUI onAppear and native subview layout without running a
        // blocking sleep on the main thread.
        try await Task.sleep(for: .milliseconds(glassMode ? 500 : 250))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let scrollOffset, let scroll = descendantScrollView(in: host), let document = scroll.documentView {
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? scrollOffset : maxY - scrollOffset
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        let destination = outputDirectory.appendingPathComponent(name + ".png")
        let bitmap: NSBitmapImageRep
        if glassMode {
            bitmap = try await captureComposited(frame: frame.insetBy(dx: -margin, dy: -margin), to: destination)
        } else {
            guard let cached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PreviewError.render(name)
            }
            host.cacheDisplay(in: host.bounds, to: cached)
            guard let png = cached.representation(using: .png, properties: [:]) else { throw PreviewError.render(name) }
            try png.write(to: destination)
            bitmap = cached
        }
        report.append(["name": name, "pointsWide": host.bounds.width, "pointsHigh": host.bounds.height,
                       "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
                       "capture": glassMode ? "composited-screen" : "view-bitmap",
                       "backdropMargin": margin])
        print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
    }

    private func captureComposited(frame: CGRect, to destination: URL) async throws -> NSBitmapImageRep {
        // screencapture uses top-left coordinates relative to the primary screen;
        // AppKit uses a bottom-left origin. Capture only our synthetic backdrop.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let requestURL = outputDirectory.appendingPathComponent(".glass-capture-request.json")
        let resultURL = outputDirectory.appendingPathComponent(".glass-capture-result.json")
        try? FileManager.default.removeItem(at: resultURL)
        let request: [String: Any] = [
            "rect": [Int(frame.minX), Int(primaryTop - frame.maxY), Int(frame.width), Int(frame.height)],
            "file": destination.lastPathComponent
        ]
        // The CLI driver owns screen capture so it can use the terminal's
        // existing access. The unique, offline preview app never asks for a new
        // privacy grant. Keep its run loop alive while the compositor captures.
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: resultURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let resultData = try? Data(contentsOf: resultURL),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw PreviewError.screenCaptureUnavailable("CLI capture driver timed out")
        }
        guard result["status"] as? Int == 0,
              let data = try? Data(contentsOf: destination),
              let bitmap = NSBitmapImageRep(data: data) else {
            throw PreviewError.screenCaptureUnavailable(result["error"] as? String ?? "No image produced")
        }
        return bitmap
    }

    private func descendantScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = descendantScrollView(in: child) { return found }
        }
        return nil
    }

    private func fail(_ error: Error) -> Never {
        fputs("UI preview failed: \(error)\n", stderr)
        exit(1)
    }

    enum PreviewError: Error {
        case render(String)
        case screenTooSmall(String)
        case screenCaptureUnavailable(String)
    }
}

private final class UIPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Broad colored bands remain identifiable through blur, while the visible
/// border gives a reference for the unblurred desktop behind each fixture.
private final class UIPreviewBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors = ["286C87", "A96642", "758955", "70629E"]
        for (index, color) in colors.enumerated() {
            NSColor(hex: color).setFill()
            NSRect(x: bounds.width * CGFloat(index) / CGFloat(colors.count), y: 0,
                   width: bounds.width / CGFloat(colors.count) + 1, height: bounds.height).fill()
        }
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: bounds.height * 0.44, width: bounds.width, height: bounds.height * 0.12).fill()
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
