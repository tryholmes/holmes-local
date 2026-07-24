// Portions derived from OpenClicky (MIT, © 2025 Jason Kneen), which embeds a
// subset of trycua/cua-driver (MIT, © 2025 Cua AI, Inc.,
// https://github.com/trycua/cua). See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

// MARK: - ComputerActionOutcome
// The result of one computer-use primitive. It carries an optional base64 JPEG so
// a `screenshot` (or a post-action frame) can be handed back to the model as an
// image tool_result, plus flags that let HolmesBrain translate it into a
// ToolResult without re-deriving intent:
//   • isError   — the call failed (bad coordinate, missing permission, event
//                 creation refused). Surfaces as an error tool_result.
//   • isRefused — the master switch is OFF. Distinct from a failure: it means
//                 "the user has to enable this", not "something broke".
//   • isTerminal — the run was cancelled (kill switch). The loop should wind down.
struct ComputerActionOutcome {
    let text: String
    let imageBase64: String?
    let isError: Bool
    let isRefused: Bool
    let isTerminal: Bool

    static func ok(_ text: String, image: String? = nil) -> ComputerActionOutcome {
        ComputerActionOutcome(text: text, imageBase64: image, isError: false, isRefused: false, isTerminal: false)
    }
    static func error(_ text: String) -> ComputerActionOutcome {
        ComputerActionOutcome(text: text, imageBase64: nil, isError: true, isRefused: false, isTerminal: false)
    }
    static func refused(_ text: String) -> ComputerActionOutcome {
        ComputerActionOutcome(text: text, imageBase64: nil, isError: true, isRefused: true, isTerminal: false)
    }
    static func terminal(_ text: String) -> ComputerActionOutcome {
        ComputerActionOutcome(text: text, imageBase64: nil, isError: true, isRefused: false, isTerminal: true)
    }
}

// MARK: - ComputerUseEngine
// The gated orchestrator between Claude's `computer` tool and the raw input/capture
// primitives. It reimplements OpenClicky's `OpenClickyNativeComputerUseController`
// semantics (OpenClickyComputerUseRuntime.swift:20-127) in Holmes' idiom: a single
// persisted master switch checked in every MUTATING primitive, a session kill flag
// checked before every event post, and permission preflighting that refuses rather
// than forcing anything on.
//
// It is deliberately USER-INITIATED ONLY. Nothing here is reachable from the
// autonomous playbook path — HolmesBrain never offers the `computer` tool in
// playbook mode, and even if it were smuggled in, dispatch default-denies it. This
// class holds no autonomous entry point.
//
// @MainActor because it reads NSScreen / the Accessibility tree and drives
// ScreenEngine (all main-thread). The blocking work — CGEvent posting + the small
// usleeps inside InputController — is hopped OFF the main actor via `postOffMain`
// so a multi-step session never freezes the UI.
@MainActor
final class ComputerUseEngine {
    static let shared = ComputerUseEngine()
    private init() {}

    // MARK: - Diagnostics
    //
    // Every hop logs to the unified system log (Console.app → filter subsystem
    // "com.grain.holmes", category "ComputerUse"). This is the single most useful
    // thing for "computer actions don't seem to do anything": the log says WHY at
    // each step — the master switch state, Accessibility trust, the model→global
    // coordinate mapping, and whether the CGEvent was actually posted. Also mirrored
    // to stdout so it shows up when the app is run from Xcode/terminal.
    static let log = Logger(subsystem: "com.grain.holmes", category: "ComputerUse")

    private static func diag(_ message: String) {
        log.log("\(message, privacy: .public)")
        print("[ComputerUse] \(message)")
    }

    /// One-time gate so we surface the macOS Accessibility grant dialog at most
    /// once per process instead of on every blocked action.
    private var didPromptForAccessibility = false

    // MARK: - Master switch (persisted, default OFF)

    /// UserDefaults key for the master enable switch. Mirrors OpenClicky's
    /// `AppBundleConfiguration.userNativeComputerUseDefaultsKey` (OC:29). Default
    /// false: `UserDefaults.bool(forKey:)` returns false for an unset key, so a
    /// fresh install has computer control OFF until the user flips the Settings
    /// toggle. Refuse-don't-force-enable — no primitive ever writes this true.
    static let enabledDefaultsKey = "com.grain.holmes.computerUse.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    // MARK: - Session kill switch

    /// Set by the global ⌘⌥Esc hotkey (and any "Stop" affordance) to abort an
    /// in-flight run. Checked at the top of every `perform` — i.e. before any
    /// event is posted — so the very next primitive the model asks for returns a
    /// terminal outcome and the loop winds down. Reset by `beginRun()`.
    private(set) var isCancelled: Bool = false

    /// The most recent frame the model was shown. A click/type/scroll is mapped
    /// through THIS capture's geometry, so coordinates are always interpreted in
    /// the pixel space of the screenshot the model actually reasoned about (never
    /// a fresher frame the model hasn't seen). Reset by `beginRun()`.
    private var lastCapture: ComputerUseCapture?

    /// Clears the kill flag and the stale capture at the start of a user-initiated
    /// run. Called by HolmesBrain.run(goal:) — the only path that offers `computer`.
    func beginRun() {
        isCancelled = false
        lastCapture = nil
    }

    /// Flips the kill flag. Idempotent and safe to call from the hotkey handler
    /// mid-run; the in-flight primitive finishes, and the next one aborts.
    func cancelRun() {
        isCancelled = true
    }

    // MARK: - Permissions (refuse, never force-enable)

    /// Wraps the existing PermissionManager probes. Accessibility authorizes
    /// CGEvent posting (the same grant keyboard posting already uses); Screen
    /// Recording authorizes the `screenshot` capture. A missing grant makes the
    /// engine REFUSE with a clear message rather than silently no-op (CGEvent
    /// posts land nowhere without Accessibility; capture returns black frames
    /// without Screen Recording).
    func permissionsReady() -> (accessibility: Bool, screenRecording: Bool) {
        (PermissionManager.checkAccessibilityPermission(),
         PermissionManager.checkScreenRecordingPermission())
    }

    // MARK: - Switchboard

    /// Executes one computer action the model requested. Coordinate flow for the
    /// pointing verbs: model `[x,y]` (declared-resolution pixels, top-left) →
    /// `WindowCapture.modelPointToGlobalAppKit` (global AppKit, bottom-left) →
    /// `InputController.Mouse.*` (which does the final per-display AppKit→Quartz
    /// conversion and posts the CGEvents off-main).
    ///
    /// Gating, per primitive:
    ///   • kill switch — checked FIRST, before any work, for every action.
    ///   • `screenshot` / `cursor_position` — read-only; NO master-switch gate.
    ///   • everything else (mutations) — `guard isEnabled` + the relevant
    ///     permission, or the call is refused.
    func perform(action: String, input: [String: Any]) async -> ComputerActionOutcome {
        // One line at the top of every action so the Console shows the gate state
        // for each request even when the action is refused before doing any work.
        let axTrusted = PermissionManager.checkAccessibilityPermission()
        Self.diag("perform action=\(action) enabled=\(isEnabled) axTrusted=\(axTrusted) cancelled=\(isCancelled)")

        // Kill switch: before ANY event post. A cancelled run refuses everything
        // from here on so the model's loop terminates promptly (the maxIterations
        // cap is the backstop).
        guard !isCancelled else {
            Self.diag("action=\(action) TERMINAL — kill switch active (⌘⌥Esc)")
            return .terminal("Computer control was stopped by the user (kill switch). Do not continue — end your turn.")
        }

        switch action {
        // ---- Read-only / non-posting: no master-switch gate ----
        case "screenshot":
            return await doScreenshot()
        case "cursor_position":
            return doCursorPosition()
        case "wait":
            // The model uses `wait` to let the UI settle between steps. It posts no
            // events, so it needs neither the master switch nor Accessibility —
            // handle it here so a legitimate pause never surfaces as an "unknown
            // action" error that stalls the sequence.
            return await doWait(input)

        // ---- Structured app launch: master-switch gated, but NOT Accessibility-
        // gated — NSWorkspace launches post no CGEvents, so they work even while
        // an Accessibility grant is stale. This is the reliable route for "open
        // Finder"-class steps (no fragile Dock click).
        case "open_app":
            guard isEnabled else {
                Self.diag("action=open_app REFUSED — master switch OFF (Settings ▸ Privacy ▸ Computer control)")
                return .refused("Computer control is off. Enable it in Settings ▸ Privacy ▸ Computer control before Holmes can act on the Mac.")
            }
            return await doOpenApp(input)

        // ---- Mutations: gated ----
        case "mouse_move", "left_click", "right_click", "middle_click",
             "double_click", "triple_click", "left_mouse_down", "left_mouse_up",
             "left_click_drag", "scroll", "key", "hold_key", "type":
            guard isEnabled else {
                Self.diag("action=\(action) REFUSED — master switch OFF (Settings ▸ Privacy ▸ Computer control)")
                return .refused("Computer control is off. Enable it in Settings ▸ Privacy ▸ Computer control before Holmes can act on the Mac.")
            }
            // The mutating verbs need Accessibility. Use the instant
            // AXIsProcessTrusted probe directly (NOT permissionsReady(), whose
            // Screen-Recording branch blocks the main thread up to 1s).
            guard axTrusted else {
                // Actively surface the macOS grant dialog once (in addition to the
                // clear text the model relays) — without Accessibility trust every
                // CGEvent post silently lands nowhere, which is exactly the "nothing
                // happens" symptom. The prompt makes the missing grant impossible to
                // miss instead of leaving it to the user to find in Settings.
                Self.diag("action=\(action) BLOCKED — Accessibility NOT granted OR the grant is stale (macOS applies a grant made while the app runs only after relaunch). Prompting (once).")
                requestAccessibilityPromptOnce()
                return .error("Accessibility permission is required to post mouse/keyboard events. If the user has NOT granted it yet: System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable Holmes. If they say they ALREADY granted it: macOS applies an Accessibility grant made while an app is running only after that app relaunches — tell the user to click the \"Relaunch Holmes\" button in Settings ▸ Privacy (or quit and reopen Holmes), then start this task again. (Without active trust, clicks and keystrokes are silently dropped.)")
            }
            return await doMutation(action, input)

        default:
            Self.diag("action=\(action) UNKNOWN — no handler")
            return .error("Unknown computer action '\(action)'.")
        }
    }

    /// Shows the macOS Accessibility grant dialog at most once per process. Wraps
    /// PermissionManager.requestAccessibilityPermission (AXIsProcessTrustedWithOptions
    /// with kAXTrustedCheckOptionPrompt), which both re-probes trust and, when
    /// untrusted, pops the system prompt that deep-links to the Accessibility pane.
    private func requestAccessibilityPromptOnce() {
        guard !didPromptForAccessibility else { return }
        didPromptForAccessibility = true
        PermissionManager.requestAccessibilityPermission()
    }

    /// A no-op pause the model asks for to let the UI settle. Bounded to 3s so a
    /// bad `duration` can't wedge the run; defaults to ~0.5s.
    private func doWait(_ input: [String: Any]) async -> ComputerActionOutcome {
        let requested = doubleValue(input["duration"] ?? 0.5).map { Double($0) } ?? 0.5
        let seconds = min(3.0, max(0.0, requested))
        Self.diag("action=wait duration=\(seconds)s")
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        return .ok("Waited \(String(format: "%.1f", seconds))s.")
    }

    // MARK: - Read-only primitives

    /// Grabs a fresh frame, stashes it as the run's `lastCapture` (so a following
    /// click maps against exactly what the model is about to see), and returns it
    /// as an image payload. A nil/blank capture is surfaced as an error — the
    /// model must never be handed black pixels to reason about.
    private func doScreenshot() async -> ComputerActionOutcome {
        guard let capture = await WindowCapture.captureForModel() else {
            Self.diag("action=screenshot FAILED — nil/blank capture (Screen Recording missing or stale). Clicks that follow have no frame to map against.")
            return .error("Screen capture failed or returned a blank frame — Screen Recording permission may be missing or stale (System Settings ▸ Privacy & Security ▸ Screen Recording). Cannot proceed until a real frame is available.")
        }
        lastCapture = capture
        Self.diag("action=screenshot OK \(capture.screenshotWidthInPixels)×\(capture.screenshotHeightInPixels)px (declared \(WindowCapture.declaredWidth)×\(WindowCapture.declaredHeight)) displayFrame=\(NSStringFromRect(capture.displayFrame))")
        return .ok(
            "Screenshot captured at \(capture.screenshotWidthInPixels)×\(capture.screenshotHeightInPixels) px (coordinates you return are interpreted in this pixel space, top-left origin).",
            image: capture.jpegBase64
        )
    }

    /// Reports the current cursor position in the model's pixel space when a
    /// capture is available (so the model can reason about it against the frame it
    /// saw); otherwise reports the raw global point. Read-only.
    private func doCursorPosition() -> ComputerActionOutcome {
        let global = NSEvent.mouseLocation // global AppKit point (bottom-left origin)
        guard let capture = lastCapture else {
            return .ok("Cursor is at global point (\(Int(global.x)), \(Int(global.y))). Take a screenshot first to get a coordinate in the model's pixel space.")
        }
        let pixel = globalAppKitToModelPixel(global, in: capture)
        return .ok("Cursor is at (\(Int(pixel.x)), \(Int(pixel.y))) in the current screenshot's pixel space.")
    }

    // MARK: - Clicky on-screen pointer flash
    //
    // The product's core feel: the user WATCHES Clicky act. Before every mutating
    // pointer event that has a resolved global target, we briefly draw a glowing
    // ring AT that point so the user sees where Holmes is about to click/drag/move.
    // This runs in BOTH the autonomous path and the user-initiated agent path
    // automatically, because both flow through this single `perform` choke point.

    /// Whether to draw the "Show Clicky on screen" pointer ring at each action
    /// point. Persisted, DEFAULT ON (an unset key reads true). Toggled in
    /// Settings ▸ Voice & Guidance.
    private var showClickyOnScreen: Bool {
        UserDefaults.standard.object(forKey: ClickyController.Defaults.showPointer) as? Bool ?? true
    }

    /// Draws the ring at `global` and lets it settle ~120ms so it paints BEFORE
    /// the CGEvent lands. The ring auto-hides on its own timer; the only cost to
    /// the click is the short settle, and nothing blocks the main thread
    /// (`Task.sleep` suspends; the draw is a quick window order-front). No-op when
    /// the pref is off.
    private func flashClickyPointer(at global: CGPoint, label: String? = nil) async {
        guard showClickyOnScreen else { return }
        VisualGuidanceOverlay.shared.flashPointer(atGlobalPoint: global, label: label)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // MARK: - Mutating primitives

    private func doMutation(_ action: String, _ input: [String: Any]) async -> ComputerActionOutcome {
        switch action {
        case "mouse_move":      return await doMove(input)
        case "left_click":      return await doClick(input, kind: .left)
        case "right_click":     return await doClick(input, kind: .right)
        case "middle_click":    return await doClick(input, kind: .middle)
        case "double_click":    return await doClick(input, kind: .double)
        case "triple_click":    return await doClick(input, kind: .triple)
        case "left_mouse_down": return await doMouseEdge(input, down: true)
        case "left_mouse_up":   return await doMouseEdge(input, down: false)
        case "left_click_drag": return await doDrag(input)
        case "scroll":          return await doScroll(input)
        case "key":             return await doKey(input)
        case "hold_key":        return await doHoldKey(input)
        case "type":            return await doType(input)
        default:                return .error("Unhandled mutating action '\(action)'.")
        }
    }

    private enum ClickKind { case left, right, middle, double, triple }

    /// Modifiers to HOLD during a pointing action, from the click's `text` field
    /// (Anthropic's computer-use convention: e.g. text:"shift" or "cmd+shift"
    /// alongside a left_click). Reuses the chord parser and keeps only modifier
    /// tokens — a stray non-modifier key in a click's text is ignored, never typed.
    private func clickModifiers(_ input: [String: Any]) -> [String] {
        guard let text = input["text"] as? String, !text.isEmpty else { return [] }
        return parseKeyChord(text).modifiers
    }

    private func doClick(_ input: [String: Any], kind: ClickKind) async -> ComputerActionOutcome {
        let verb: String
        switch kind {
        case .left:   verb = "left_click"
        case .right:  verb = "right_click"
        case .middle: verb = "middle_click"
        case .double: verb = "double_click"
        case .triple: verb = "triple_click"
        }
        guard let global = resolveGlobalPoint(from: input) else {
            Self.diag("action=\(verb) UNMAPPED — no screenshot taken yet (lastCapture is nil) or malformed coordinate. Model must screenshot before clicking.")
            return .error("Missing or unmappable 'coordinate'. Take a screenshot first, then pass coordinate:[x,y] in that frame's pixel space.")
        }
        let mods = clickModifiers(input)
        // Show WHERE Clicky is about to click — and NAME the action — before the
        // event lands, so the on-screen ring carries a "Click"/"Double-click" bubble.
        let clickLabel: String
        switch kind {
        case .left:   clickLabel = "Click"
        case .right:  clickLabel = "Right-click"
        case .middle: clickLabel = "Middle-click"
        case .double: clickLabel = "Double-click"
        case .triple: clickLabel = "Triple-click"
        }
        await flashClickyPointer(at: global, label: clickLabel)
        let error: String? = await postOffMain {
            switch kind {
            case .left:   try InputController.Mouse.leftClick(at: global, modifiers: mods)
            case .right:  try InputController.Mouse.rightClick(at: global, modifiers: mods)
            case .middle: try InputController.Mouse.middleClick(at: global, modifiers: mods)
            case .double: try InputController.Mouse.doubleClick(at: global, modifiers: mods)
            case .triple: try InputController.Mouse.tripleClick(at: global, modifiers: mods)
            }
        }
        logPosted(verb, model: input, global: global, error: error)
        let name: String
        switch kind {
        case .left:   name = "Left-clicked"
        case .right:  name = "Right-clicked"
        case .middle: name = "Middle-clicked"
        case .double: name = "Double-clicked"
        case .triple: name = "Triple-clicked"
        }
        let held = mods.isEmpty ? "" : " (holding \(mods.joined(separator: "+")))"
        return finish(error, ok: "\(name) at \(describeModelPoint(from: input))\(held).")
    }

    /// `left_mouse_down` / `left_mouse_up` — the two halves of a manual click,
    /// for press-and-hold UI and hand-rolled drags. Coordinate is optional: with
    /// none given the edge is posted at the CURRENT cursor position, so
    /// down → mouse_move → up composes naturally.
    private func doMouseEdge(_ input: [String: Any], down: Bool) async -> ComputerActionOutcome {
        let verb = down ? "left_mouse_down" : "left_mouse_up"
        let global = resolveGlobalPoint(from: input) ?? NSEvent.mouseLocation
        let mods = clickModifiers(input)
        await flashClickyPointer(at: global, label: down ? "Press" : "Release")
        let error = await postOffMain {
            if down {
                try InputController.Mouse.leftMouseDown(at: global, modifiers: mods)
            } else {
                try InputController.Mouse.leftMouseUp(at: global, modifiers: mods)
            }
        }
        logPosted(verb, model: input, global: global, error: error)
        return finish(error, ok: down
            ? "Pressed the left button down at \(describeModelPoint(from: input)) (it stays held until left_mouse_up)."
            : "Released the left button at \(describeModelPoint(from: input)).")
    }

    private func doMove(_ input: [String: Any]) async -> ComputerActionOutcome {
        guard let global = resolveGlobalPoint(from: input) else {
            Self.diag("action=mouse_move UNMAPPED — no screenshot taken yet (lastCapture is nil) or malformed coordinate.")
            return .error("Missing or unmappable 'coordinate'. Take a screenshot first, then pass coordinate:[x,y].")
        }
        await flashClickyPointer(at: global, label: "Move")
        let error = await postOffMain { try InputController.Mouse.moveCursor(to: global) }
        logPosted("mouse_move", model: input, global: global, error: error)
        return finish(error, ok: "Moved the cursor to \(describeModelPoint(from: input)).")
    }

    private func doDrag(_ input: [String: Any]) async -> ComputerActionOutcome {
        // End point is the model's `coordinate`; a start may be given explicitly
        // via `start_coordinate`, else we start from the current cursor position.
        guard let capture = lastCapture else {
            return .error("Take a screenshot first so drag coordinates can be mapped.")
        }
        guard let endPoint = coordinate(from: input) else {
            return .error("Missing 'coordinate' (drag end point).")
        }
        let end = WindowCapture.modelPointToGlobalAppKit(endPoint, in: capture)
        let start: CGPoint
        if let startPoint = coordinate(from: input, key: "start_coordinate") {
            start = WindowCapture.modelPointToGlobalAppKit(startPoint, in: capture)
        } else {
            start = NSEvent.mouseLocation
        }
        // Point at the drag DESTINATION before the drag lands.
        await flashClickyPointer(at: end, label: "Drag here")
        let error = await postOffMain { try InputController.Mouse.drag(from: start, to: end) }
        Self.diag("action=left_click_drag start=(\(Int(start.x)),\(Int(start.y))) end=(\(Int(end.x)),\(Int(end.y))) posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
        return finish(error, ok: "Dragged to \(describeModelPoint(from: input)).")
    }

    private func doScroll(_ input: [String: Any]) async -> ComputerActionOutcome {
        guard let global = resolveGlobalPoint(from: input) else {
            return .error("Missing or unmappable 'coordinate' for scroll. Take a screenshot first, then pass coordinate:[x,y].")
        }
        // Anthropic's scroll carries a direction + an amount in "clicks"; convert
        // to pixel deltas. wheel1 (dy) is vertical, wheel2 (dx) horizontal:
        // up/left are positive, down/right negative, matching content that moves
        // opposite the wheel.
        let direction = (input["scroll_direction"] as? String)?.lowercased() ?? "down"
        let amount = intValue(input["scroll_amount"]) ?? 3
        let step = max(1, amount) * 100
        // Immutable so the @Sendable off-main closure captures them cleanly.
        let dx: Int, dy: Int
        switch direction {
        case "up":    (dx, dy) = (0, step)
        case "down":  (dx, dy) = (0, -step)
        case "left":  (dx, dy) = (step, 0)
        case "right": (dx, dy) = (-step, 0)
        default:      (dx, dy) = (0, -step)
        }
        let error = await postOffMain { try InputController.Mouse.scroll(at: global, dx: dx, dy: dy) }
        Self.diag("action=scroll dir=\(direction) amount=\(max(1, amount)) model=\(describeModelPoint(from: input)) global=(\(Int(global.x)),\(Int(global.y))) posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
        return finish(error, ok: "Scrolled \(direction) by \(max(1, amount)) at \(describeModelPoint(from: input)).")
    }

    private func doKey(_ input: [String: Any]) async -> ComputerActionOutcome {
        let raw = keyChordString(input)
        guard !raw.isEmpty else { return .error("Missing 'text' for key press.") }
        let (key, mods) = parseKeyChord(raw)
        guard !key.isEmpty else { return .error("Could not parse a key from '\(raw)'.") }
        let error = await postOffMain { try InputController.Keyboard.press(key, modifiers: mods) }
        Self.diag("action=key chord=\(raw) key=\(key) mods=\(mods.joined(separator: "+")) posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
        return finish(error, ok: "Pressed \(raw).")
    }

    /// `hold_key`: hold a key down for `duration` seconds, then release. The key
    /// is usually a bare modifier ("shift" while inspecting hover state) but any
    /// named key works. parseKeyChord classifies bare modifiers as modifiers and
    /// leaves the key slot empty — in that case the LAST modifier token IS the
    /// key to hold (it has its own hardware keycode in InputController's table).
    private func doHoldKey(_ input: [String: Any]) async -> ComputerActionOutcome {
        let raw = keyChordString(input)
        guard !raw.isEmpty else { return .error("Missing 'text' — the key to hold (e.g. \"shift\").") }
        var (key, mods) = parseKeyChord(raw)
        if key.isEmpty, !mods.isEmpty {
            key = mods.removeLast()
        }
        guard !key.isEmpty else { return .error("Could not parse a key to hold from '\(raw)'.") }
        let requested = doubleValue(input["duration"] ?? 1.0).map { Double($0) } ?? 1.0
        let seconds = min(10.0, max(0.05, requested))
        // Immutable copies so the @Sendable off-main closure captures cleanly.
        let heldKey = key, heldMods = mods
        let error = await postOffMain { try InputController.Keyboard.holdKey(heldKey, modifiers: heldMods, seconds: seconds) }
        Self.diag("action=hold_key chord=\(raw) key=\(heldKey) duration=\(seconds)s posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
        return finish(error, ok: "Held \(raw) for \(String(format: "%.1f", seconds))s.")
    }

    // MARK: - Structured app launch (open_app)

    /// `open_app`: launch or foreground an app by NAME through NSWorkspace — the
    /// COMPUTER-CONTROL-PRIMARY exception where a structured API is strictly
    /// better than pixels (a Dock click depends on icon position, magnification,
    /// and the app even being in the Dock; this route always works). Reversible
    /// (the user can quit the app), so it runs with no confirm card, and it needs
    /// no Accessibility because it posts no CGEvents.
    private func doOpenApp(_ input: [String: Any]) async -> ComputerActionOutcome {
        let raw = (input["name"] as? String) ?? (input["text"] as? String) ?? (input["app"] as? String) ?? ""
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .error("Missing 'name'. Call open_app as {\"action\":\"open_app\",\"name\":\"Finder\"}.")
        }
        guard let url = resolveAppURL(named: name) else {
            Self.diag("action=open_app FAILED — nothing installed resolves from '\(name)'")
            return .error("No installed app matches '\(name)'. Use the exact app name (e.g. \"Safari\", \"Finder\") or its bundle identifier.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Finder wrinkle: if Finder is already running (it always is),
            // "opening" it merely activates it — with zero windows open the next
            // screenshot would show no change and the model would flounder. Open
            // the home folder so a window reliably appears.
            if app.bundleIdentifier == "com.apple.finder" {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            }
            Self.diag("action=open_app OK name=\(name) url=\(url.path)")
            // Clicky "opens it": draw a clicking ring where the app's window is
            // about to appear (center of the active display) + a notch banner, so
            // the user WATCHES Holmes open the thing rather than it just popping up.
            let appLabel = app.localizedName ?? name
            let openScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            if let openScreen {
                await flashClickyPointer(
                    at: CGPoint(x: openScreen.frame.midX, y: openScreen.frame.midY),
                    label: "Opening \(appLabel)")
            }
            NotchWindowController.shared.flashAction(
                "Opening \(appLabel)",
                subtitle: "Holmes is launching the app",
                symbol: "cursorarrow.click.2")
            return .ok("Opened \(appLabel). Take a screenshot to see its window before clicking anything in it.")
        } catch {
            Self.diag("action=open_app FAILED — \(error.localizedDescription)")
            return .error("Failed to launch '\(name)': \(error.localizedDescription)")
        }
    }

    /// App name → bundle URL, tried cheapest-first: bundle-id form, a table of
    /// well-known aliases (system apps live outside /Applications), then a
    /// case-insensitive scan of the standard app folders (exact "<name>.app"
    /// first, prefix match as a last resort).
    private func resolveAppURL(named name: String) -> URL? {
        let workspace = NSWorkspace.shared
        // 1) Bundle-identifier form ("com.apple.Safari") — has dots, resolve directly.
        if name.contains("."), let url = workspace.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        // 2) Well-known names → bundle ids. Covers the system apps whose bundles
        //    live in /System/... and whose marketing name differs from the bundle.
        let aliases: [String: String] = [
            "finder": "com.apple.finder",
            "safari": "com.apple.Safari",
            "mail": "com.apple.mail",
            "messages": "com.apple.MobileSMS",
            "notes": "com.apple.Notes",
            "calendar": "com.apple.iCal",
            "reminders": "com.apple.reminders",
            "music": "com.apple.Music",
            "photos": "com.apple.Photos",
            "maps": "com.apple.Maps",
            "facetime": "com.apple.FaceTime",
            "preview": "com.apple.Preview",
            "textedit": "com.apple.TextEdit",
            "terminal": "com.apple.Terminal",
            "app store": "com.apple.AppStore",
            "system settings": "com.apple.systempreferences",
            "system preferences": "com.apple.systempreferences",
            "settings": "com.apple.systempreferences",
            "activity monitor": "com.apple.ActivityMonitor",
            "disk utility": "com.apple.DiskUtility",
            "xcode": "com.apple.dt.Xcode",
            "chrome": "com.google.Chrome",
            "google chrome": "com.google.Chrome"
        ]
        let lowered = name.lowercased()
        if let bundleID = aliases[lowered], let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        // 3) Scan the standard app folders. Exact (case-insensitive) match first
        //    across ALL folders, then a prefix match ("open activity" → Activity
        //    Monitor.app) so a near-name still resolves.
        let fm = FileManager.default
        let folders = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        for folder in folders {
            let exact = URL(fileURLWithPath: folder).appendingPathComponent(name + ".app")
            if fm.fileExists(atPath: exact.path) { return exact }
        }
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            if let hit = entries.first(where: { $0.lowercased() == lowered + ".app" }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(hit)
            }
        }
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            if let hit = entries.first(where: { $0.lowercased().hasSuffix(".app") && $0.lowercased().hasPrefix(lowered) }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(hit)
            }
        }
        return nil
    }

    private func doType(_ input: [String: Any]) async -> ComputerActionOutcome {
        guard let text = input["text"] as? String, !text.isEmpty else {
            return .error("Missing 'text' to type.")
        }
        let error = await postOffMain { try InputController.Keyboard.typeCharacters(text) }
        Self.diag("action=type chars=\(text.count) posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
        let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return finish(error, ok: "Typed: \(preview)")
    }

    // MARK: - Irreversibility classifier
    //
    // The session-approval safety envelope: reversible actions run FREELY (no
    // per-action card, clicky-style); only genuinely irreversible / outward-facing
    // actions re-confirm once. HolmesBrain calls this BEFORE `perform` to decide
    // whether to raise a ConfirmationBus card. The rules mirror Holmes' shipping
    // extension guard (holmes-extension/automation.js): a curated set of commit
    // key chords, and any click/type whose resolved AX target label matches the
    // same send-verb regex the extension refuses on.

    /// The exact send-verb list the browser extension refuses on
    /// (automation.js SEND_RE), reused verbatim so the pixel path and the DOM path
    /// draw the "never commit on the user's behalf" line in the same place.
    private static let sendVerbRegex = try! NSRegularExpression(
        pattern: #"\b(send|submit|post|publish|tweet|reply|confirm|pay|buy|order|delete|archive)\b"#,
        options: [.caseInsensitive]
    )

    /// True for the actions that must re-confirm once even under session approval.
    func isIrreversible(action: String, input: [String: Any]) -> Bool {
        switch action {
        case "key", "hold_key":
            // hold_key rides the same lane as key: HOLDING Return/Enter commits
            // exactly like pressing it, so the commit-chord gate must cover both.
            return isCommitKeyChord(keyChordString(input))
        case "left_click", "right_click", "middle_click", "double_click",
             "triple_click", "left_click_drag", "left_mouse_down", "left_mouse_up":
            // Every pointing verb that can activate a control goes through the SAME
            // AX-label gate — including the down/up halves, or a manual
            // down-then-up on a Send button would sidestep the send-verb check.
            // For the edge verbs a missing coordinate means "at the cursor", so
            // classify the element under the CURRENT cursor, mirroring doMouseEdge.
            let fallback: CGPoint? = (action == "left_mouse_down" || action == "left_mouse_up")
                ? NSEvent.mouseLocation : nil
            guard let global = resolveGlobalPoint(from: input) ?? fallback else { return false }
            let target = axTarget(atGlobalAppKit: global)
            // A Send/Submit/Delete/… label means "outward-facing" → re-confirm.
            if matchesSendVerb(target.label) { return true }
            // FAIL CLOSED for the hole label-matching can't see: a custom-drawn
            // button/link with NO accessible name inside a native messaging app.
            // WhatsApp/Messages/Discord/Slack/etc. often expose their send control
            // as a nameless AXButton, so a label check alone would let a real
            // outward send fire with no confirmation. In those apps a nameless
            // clickable control re-confirms; everywhere else nameless clicks stay
            // free (clicky-like). The deterministic Return/⌘ key lane still gates
            // send-by-keyboard regardless of app.
            if target.label.isEmpty, target.isClickableControl, Self.isNativeMessagingApp(target.appName) {
                return true
            }
            return false
        case "type":
            // Typing text is reversible, EXCEPT when the focused control itself is a
            // commit affordance (rare, but e.g. a focused "Send" button).
            return matchesSendVerb(axFocusedElementLabel())
        default:
            // mouse_move, scroll, wait, open_app, screenshot, cursor_position →
            // reversible / read-only. (open_app is a launch the user can quit.)
            return false
        }
    }

    /// A key chord that commits or is otherwise hard to undo: anything containing
    /// return/enter, or ⌘S / ⌘W / ⌘Q / ⌘Delete.
    private func isCommitKeyChord(_ raw: String) -> Bool {
        let tokens = chordTokens(raw)
        if tokens.contains("return") || tokens.contains("enter") { return true }
        let hasCmd = tokens.contains(where: { ["cmd", "command", "super", "meta", "⌘"].contains($0) })
        guard hasCmd else { return false }
        if tokens.contains("s") || tokens.contains("w") || tokens.contains("q") { return true }
        if tokens.contains("delete") || tokens.contains("backspace") { return true }
        return false
    }

    private func matchesSendVerb(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return Self.sendVerbRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - Human-readable descriptions (for the confirmation card)

    /// A short title for the approval card ("Click", "Press", "Type", …).
    func actionTitle(_ action: String) -> String {
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click": return "Click"
        case "left_mouse_down": return "Press mouse button"
        case "left_mouse_up": return "Release mouse button"
        case "left_click_drag": return "Drag"
        case "mouse_move": return "Move cursor"
        case "scroll": return "Scroll"
        case "key": return "Press keys"
        case "hold_key": return "Hold key"
        case "type": return "Type"
        case "open_app": return "Open app"
        default: return action
        }
    }

    /// A one-line preview describing the action and, where relevant, the resolved
    /// AX target — the thing the user is being asked to approve.
    func describeAction(action: String, input: [String: Any]) -> String {
        switch action {
        case "left_click", "right_click", "middle_click", "double_click",
             "triple_click", "left_click_drag", "left_mouse_down", "left_mouse_up":
            let target = resolveGlobalPoint(from: input).map { axTarget(atGlobalAppKit: $0).label } ?? ""
            let where_ = describeModelPoint(from: input)
            return target.isEmpty ? "\(actionTitle(action)) at \(where_)"
                                  : "\(actionTitle(action)) “\(shorten(target))” at \(where_)"
        case "type":
            let text = input["text"] as? String ?? ""
            return "Type: \(shorten(text))"
        case "key":
            return "Press: \(keyChordString(input))"
        case "hold_key":
            return "Hold: \(keyChordString(input))"
        case "open_app":
            let name = (input["name"] as? String) ?? (input["text"] as? String) ?? "?"
            return "Open the app “\(name)”"
        case "scroll":
            return "Scroll \((input["scroll_direction"] as? String) ?? "down") at \(describeModelPoint(from: input))"
        case "mouse_move":
            return "Move cursor to \(describeModelPoint(from: input))"
        default:
            return action
        }
    }

    // MARK: - Coordinate helpers

    /// Maps the model's `input[key]` = `[x,y]` (declared-resolution pixels,
    /// top-left) into a global AppKit point, using the run's stashed capture.
    /// Returns nil if there is no capture yet or the coordinate is malformed.
    private func resolveGlobalPoint(from input: [String: Any], key: String = "coordinate") -> CGPoint? {
        guard let capture = lastCapture, let point = coordinate(from: input, key: key) else { return nil }
        return WindowCapture.modelPointToGlobalAppKit(point, in: capture)
    }

    private func coordinate(from input: [String: Any], key: String = "coordinate") -> CGPoint? {
        guard let array = input[key] as? [Any], array.count == 2,
              let x = doubleValue(array[0]), let y = doubleValue(array[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// "(640, 360)" for the card/result text — echoes the model's own pixel coords.
    private func describeModelPoint(from input: [String: Any], key: String = "coordinate") -> String {
        guard let p = coordinate(from: input, key: key) else { return "(?, ?)" }
        return "(\(Int(p.x)), \(Int(p.y)))"
    }

    /// Inverse of `WindowCapture.modelPointToGlobalAppKit` for the primary display:
    /// global AppKit point (bottom-left) → model pixel space (top-left). Used only
    /// by `cursor_position`, which is informational.
    private func globalAppKitToModelPixel(_ point: CGPoint, in capture: ComputerUseCapture) -> CGPoint {
        let localX = point.x - capture.displayFrame.origin.x
        let localYFromBottom = point.y - capture.displayFrame.origin.y
        let localYFromTop = CGFloat(capture.displayHeightInPoints) - localYFromBottom
        let px = localX * CGFloat(capture.screenshotWidthInPixels) / CGFloat(max(1, capture.displayWidthInPoints))
        let py = localYFromTop * CGFloat(capture.screenshotHeightInPixels) / CGFloat(max(1, capture.displayHeightInPoints))
        return CGPoint(x: px, y: py)
    }

    // MARK: - Accessibility target resolution
    //
    // Resolves the AX element under a global point so the irreversibility check can
    // read its label. The conversion global-AppKit → global-Quartz mirrors
    // InputController's private `quartzPoint` (its copy is not visible here); AX
    // position queries want top-left global coordinates.

    /// What the irreversibility check needs to know about the element under a point.
    struct AXTarget {
        let label: String
        let role: String
        let appName: String
        /// A control a click would activate — button / link / menu-button / checkbox.
        var isClickableControl: Bool {
            ["AXButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXCheckBox", "AXRadioButton"].contains(role)
        }
    }

    /// Native chat/compose apps whose send affordance is frequently a custom-drawn,
    /// LABEL-LESS control — so a nameless clickable target there must fail closed.
    private static let nativeMessagingApps: Set<String> = [
        "whatsapp", "messages", "discord", "slack", "telegram", "signal",
        "mail", "microsoft outlook", "outlook", "messenger"
    ]

    private static func isNativeMessagingApp(_ app: String) -> Bool {
        let a = app.lowercased()
        return nativeMessagingApps.contains(where: { a.contains($0) })
    }

    private func axTarget(atGlobalAppKit point: CGPoint) -> AXTarget {
        let appName = ScreenEngine.shared.latestActiveApp
        guard let quartz = globalAppKitToQuartz(point) else {
            return AXTarget(label: "", role: "", appName: appName)
        }
        var elementRef: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        // Cap AX round-trips: AXUIElementCopyElementAtPosition can block on a wedged
        // app, and this runs before every mutating click. 0.5s is far longer than a
        // healthy query; past it we treat the target as unknown rather than hang.
        AXUIElementSetMessagingTimeout(system, 0.5)
        let err = AXUIElementCopyElementAtPosition(system, Float(quartz.x), Float(quartz.y), &elementRef)
        guard err == .success, let element = elementRef else {
            return AXTarget(label: "", role: "", appName: appName)
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
                    ? (roleRef as? String) : nil) ?? ""
        return AXTarget(label: axLabelBag(element), role: role, appName: appName)
    }

    private func axFocusedElementLabel() -> String {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "" }
        return axLabelBag(focused as! AXUIElement)
    }

    /// Everything about an element that could reveal a commit intent — title,
    /// description, role description, help, string value, identifier — joined so
    /// the send-verb regex can be tested against it in one shot.
    private func axLabelBag(_ element: AXUIElement) -> String {
        func str(_ attribute: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let s = ref as? String else { return "" }
            return s
        }
        return [
            str(kAXTitleAttribute as String),
            str(kAXDescriptionAttribute as String),
            str(kAXRoleDescriptionAttribute as String),
            str(kAXHelpAttribute as String),
            str(kAXValueAttribute as String),
            str("AXIdentifier")
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Global AppKit point (bottom-left) → global Quartz point (top-left), per
    /// display. Same math InputController.Mouse.quartzPoint runs internally for
    /// CGEvent posting; duplicated here because that helper is private and the AX
    /// position query needs the identical conversion.
    private func globalAppKitToQuartz(_ point: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.screens.min(by: { screenDistance($0.frame, point) < screenDistance($1.frame, point) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        let appKitFrame = screen.frame
        let quartzFrame = CGDisplayBounds(displayID)
        let localX = point.x - appKitFrame.origin.x
        let localYFromTop = appKitFrame.maxY - point.y
        return CGPoint(x: quartzFrame.origin.x + localX, y: quartzFrame.origin.y + localYFromTop)
    }

    private func screenDistance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return (dx * dx) + (dy * dy)
    }

    // MARK: - Key-chord parsing

    /// The raw chord string from the model — Anthropic's `key` action puts it in
    /// `text` (e.g. "cmd+s", "Return"); tolerate `key`/`keys` variants too.
    private func keyChordString(_ input: [String: Any]) -> String {
        if let text = input["text"] as? String, !text.isEmpty { return text }
        if let key = input["key"] as? String, !key.isEmpty { return key }
        if let keys = input["keys"] as? [String], !keys.isEmpty { return keys.joined(separator: "+") }
        return ""
    }

    private func chordTokens(_ raw: String) -> [String] {
        raw.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" })
            .map { $0.replacingOccurrences(of: "_", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Splits an xdotool-style chord ("cmd+shift+s") into (key, modifiers) for
    /// InputController.Keyboard.press. The last non-modifier token is the key.
    private func parseKeyChord(_ raw: String) -> (key: String, modifiers: [String]) {
        var modifiers: [String] = []
        var key = ""
        for token in chordTokens(raw) {
            switch token {
            case "cmd", "command", "super", "meta", "⌘": modifiers.append("cmd")
            case "ctrl", "control": modifiers.append("ctrl")
            case "alt", "option", "opt": modifiers.append("option")
            case "shift": modifiers.append("shift")
            case "fn": modifiers.append("fn")
            default: key = token
            }
        }
        return (key, modifiers)
    }

    // MARK: - Value coercion

    private func doubleValue(_ value: Any) -> CGFloat? {
        if let d = value as? Double { return CGFloat(d) }
        if let i = value as? Int { return CGFloat(i) }
        if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private func shorten(_ text: String, max: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }

    // MARK: - Off-main event posting

    /// Runs the blocking InputController call (CGEvent posting + its small
    /// usleeps) off the main actor and returns an error message on throw, or nil
    /// on success. The InputController verbs are static and capture only Sendable
    /// value types, so there is no actor-isolation escape here.
    private func postOffMain(_ work: @Sendable @escaping () throws -> Void) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    /// Folds a `postOffMain` result into an outcome: the error text on failure,
    /// the supplied success text otherwise.
    private func finish(_ error: String?, ok: String) -> ComputerActionOutcome {
        if let error { return .error(error) }
        return .ok(ok)
    }

    /// The single diagnostic line the task asks for on every pointing verb:
    /// "action=… model=(x,y) global=(x,y) posted=true/false". `error == nil` after
    /// `postOffMain` means the CGEvents were created and `.post(tap:)` was reached
    /// without throwing (the closest signal to "posted" CoreGraphics exposes —
    /// a post that lands nowhere due to a stale grant does not raise, which is why
    /// axTrusted is logged separately at the top of `perform`).
    private func logPosted(_ action: String, model input: [String: Any], global: CGPoint, error: String?) {
        Self.diag("action=\(action) model=\(describeModelPoint(from: input)) global=(\(Int(global.x)),\(Int(global.y))) posted=\(error == nil)\(error.map { " error=\($0)" } ?? "")")
    }
}
