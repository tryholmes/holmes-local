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
        try await render("local-model-compact", size: CGSize(width: 450, height: 460),
                         view: LocalModelSettingsView(compact: true))

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
        // A real host window lets TextEditor, NSVisualEffectView, and ProgressView
        // render through AppKit. It lives outside every display, cannot activate,
        // and ignores input, so preview buttons cannot perform their real actions.
        let farEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        let window = UIPreviewWindow(contentRect: CGRect(x: farEdge + 4096, y: 0, width: size.width, height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = NSColor(hex: "060606")
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView:
            ZStack(alignment: .top) {
                Color(hex: "060606")
                view
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .preferredColorScheme(.dark))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        windows.append(window)
        window.orderFrontRegardless()
        // Settle SwiftUI onAppear and native subview layout without running a
        // blocking sleep on the main thread.
        try await Task.sleep(for: .milliseconds(250))
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
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw PreviewError.render(name)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.render(name) }
        try png.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        report.append(["name": name, "pointsWide": host.bounds.width, "pointsHigh": host.bounds.height,
                       "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh])
        window.orderOut(nil)
        window.contentView = nil
        windows.removeAll { $0 === window }
        print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
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

    enum PreviewError: Error { case render(String) }
}

private final class UIPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
