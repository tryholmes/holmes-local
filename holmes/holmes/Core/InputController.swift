// Portions derived from OpenClicky (MIT, © 2025 Jason Kneen), which embeds a
// subset of trycua/cua-driver (MIT, © 2025 Cua AI, Inc.,
// https://github.com/trycua/cua). See THIRD_PARTY_NOTICES.md.

import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog

// MARK: - InputController
// The raw "hands" of computer-use: synthesized keyboard and mouse events posted
// straight through CoreGraphics. This is the primitive layer — it does NO
// permission or enable-gate checking. That gating lives one level up in
// ComputerUseEngine (mirroring OpenClicky, where the keyboard/mouse enums have
// no gate and the controller that drives them does). Everything here is
// stateless and self-contained: the only dependencies are CoreGraphics and
// AppKit, so it compiles and runs with no reference to the rest of Holmes.
//
// Three coordinate spaces meet in the mouse layer and each conversion is
// load-bearing (this is the "M9 bug" OpenClicky documents inline): a caller
// hands in a *global AppKit* point (bottom-left origin, union of all displays);
// `clampToNearestScreen` pulls an off-screen point back onto a real display;
// `quartzPoint(fromAppKitPoint:)` converts that per-display into *Quartz* space
// (top-left origin, the space CGEvent actually consumes). Skipping either step
// lands the click somewhere unrelated.

enum InputController {

    // MARK: - Diagnostics
    // Deepest hop in the computer-use path: this is where synthesized CGEvents are
    // actually posted. Logging the final Quartz coordinate here (Console.app →
    // subsystem "com.grain.holmes", category "InputController") confirms the post
    // site was reached and shows the exact pixel the event was aimed at, so a
    // "nothing happened" report can be split into "never reached the post" vs
    // "posted at coordinate X" (which, if wrong, points at the coordinate mapping,
    // and if right, points at a stale Accessibility grant swallowing the event).
    static let log = Logger(subsystem: "com.grain.holmes", category: "InputController")

    private static func diag(_ message: String) {
        log.log("\(message, privacy: .public)")
        print("[InputController] \(message)")
    }

    // MARK: - Event delivery

    /// Deliver a synthesized event. Ported from OpenClicky's `post(_:toPid:)`
    /// (OpenClickyComputerUseRuntime.swift:1029-1037) MINUS the private SkyLight
    /// path: when a target pid is given we post directly to that process, which
    /// lands the event even when the app is not frontmost; otherwise we post to
    /// the global HID event tap. We intentionally do not link the private
    /// SkyLight framework (App-Store risk + fragile struct-offset probing).
    static func post(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
        diag("posted keyboard event type=\(event.type.rawValue) via=\(pid != nil ? "pid" : "cghidEventTap")")
    }

    // MARK: - Keyboard
    // Ported verbatim from OpenClickyComputerUseRuntime.swift:986-1093. Named
    // keys, single letters, and digits resolve through the three keycode tables
    // below; anything else is typed as a Unicode string on virtual key 0.

    enum Keyboard {

        /// Press a named key (optionally with modifiers held) as a full
        /// down-then-up chord. `key` is a table name ("return", "esc", "f5") or
        /// a single character ("a", "7"). `modifiers` are held for both edges.
        static func press(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil) throws {
            guard let code = virtualKeyCode(for: key) else {
                throw InputControllerError.unknownKey(key)
            }
            let flags = modifierMask(for: modifiers)
            try sendKey(code: code, down: true, flags: flags, toPid: pid)
            try sendKey(code: code, down: false, flags: flags, toPid: pid)
        }

        /// Hold a key DOWN for a duration, then release it — the primitive behind
        /// the model's `hold_key` action (e.g. hold shift while something else
        /// happens, or hold an arrow key to repeat-scrub). `key` may be a named
        /// key, a single character, or a bare modifier ("shift"/"cmd" — those have
        /// their own hardware keycodes in the table below). Duration is clamped to
        /// 0.05–10s so a bad value can neither no-op nor wedge the posting thread.
        static func holdKey(_ key: String, modifiers: [String] = [], seconds: Double, toPid pid: pid_t? = nil) throws {
            guard let code = virtualKeyCode(for: key) else {
                throw InputControllerError.unknownKey(key)
            }
            let flags = modifierMask(for: modifiers)
            let clamped = max(0.05, min(10.0, seconds))
            try sendKey(code: code, down: true, flags: flags, toPid: pid)
            usleep(UInt32(clamped * 1_000_000))
            try sendKey(code: code, down: false, flags: flags, toPid: pid)
        }

        /// Type a string one character at a time as Unicode key events. The
        /// inter-character delay is clamped to 0...200ms — a small pause between
        /// characters keeps fast-redrawing text fields from dropping keystrokes.
        static func typeCharacters(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
            let clampedDelay = max(0, min(200, delayMilliseconds))
            for character in text {
                try sendUnicodeCharacter(character, toPid: pid)
                if clampedDelay > 0 {
                    usleep(UInt32(clampedDelay) * 1_000)
                }
            }
        }

        /// Post one keycode edge (down or up) carrying the modifier flags.
        private static func sendKey(code: Int, down: Bool, flags: CGEventFlags, toPid pid: pid_t?) throws {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else {
                throw InputControllerError.eventCreationFailed("code=\(code) down=\(down)")
            }
            event.flags = flags
            InputController.post(event, toPid: pid)
        }

        /// Type a single character by stuffing its UTF-16 code units into a
        /// synthetic key event on virtual key 0. This sidesteps keyboard-layout
        /// keycode lookup entirely, so it handles any character (accents, emoji)
        /// the layout can't otherwise reach.
        private static func sendUnicodeCharacter(_ character: Character, toPid pid: pid_t?) throws {
            let utf16 = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                    throw InputControllerError.eventCreationFailed("unicode character \"\(character)\" down=\(keyDown)")
                }
                utf16.withUnsafeBufferPointer { buffer in
                    if let baseAddress = buffer.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                    }
                }
                InputController.post(event, toPid: pid)
            }
        }

        /// Fold a list of modifier names into a CGEventFlags mask. Accepts the
        /// common aliases the model tends to emit ("cmd"/"command", "alt"/"option").
        /// Internal (not private) because Mouse reuses it for modifier-held clicks
        /// (shift-click, cmd-click) — the flags ride on the mouse events themselves.
        static func modifierMask(for modifiers: [String]) -> CGEventFlags {
            var mask: CGEventFlags = []
            for modifier in modifiers {
                switch modifier.lowercased() {
                case "cmd", "command": mask.insert(.maskCommand)
                case "shift": mask.insert(.maskShift)
                case "option", "alt": mask.insert(.maskAlternate)
                case "ctrl", "control": mask.insert(.maskControl)
                case "fn": mask.insert(.maskSecondaryFn)
                default: break
                }
            }
            return mask
        }

        /// Resolve a key name to a hardware virtual keycode: named keys first,
        /// then single-character letter/digit/punctuation fallbacks.
        private static func virtualKeyCode(for name: String) -> Int? {
            let lowercasedName = name.lowercased()
            if let named = namedKeys[lowercasedName] { return named }
            guard lowercasedName.count == 1, let first = lowercasedName.first else { return nil }
            if let letter = letterKeys[first] { return letter }
            if let digit = digitKeys[first] { return digit }
            if let punctuation = punctuationKeys[first] { return punctuation }
            return nil
        }

        // MARK: Keycode tables (verbatim, ANSI/US layout)

        private static let namedKeys: [String: Int] = [
            "return": 0x24, "enter": 0x24,
            "tab": 0x30,
            "space": 0x31,
            "delete": 0x33, "backspace": 0x33,
            "forwarddelete": 0x75, "del": 0x75,
            "escape": 0x35, "esc": 0x35,
            "left": 0x7B, "leftarrow": 0x7B,
            "right": 0x7C, "rightarrow": 0x7C,
            "down": 0x7D, "downarrow": 0x7D,
            "up": 0x7E, "uparrow": 0x7E,
            "home": 0x73, "end": 0x77,
            "pageup": 0x74, "pagedown": 0x79,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
            // Bare modifier keys, for hold_key ("hold shift for 2s"). Pressing a
            // modifier AS the key posts its own hardware keycode; holding it as a
            // flag on another key still goes through modifierMask above.
            "shift": 0x38, "cmd": 0x37, "command": 0x37,
            "option": 0x3A, "alt": 0x3A, "opt": 0x3A,
            "ctrl": 0x3B, "control": 0x3B,
            "fn": 0x3F, "capslock": 0x39,
            // Named punctuation — chords like "cmd+," (Settings) or "cmd+-"
            // (zoom out) previously threw unknownKey and failed the whole step.
            "comma": 0x2B, "period": 0x2F, "dot": 0x2F, "slash": 0x2C,
            "semicolon": 0x29, "quote": 0x27, "apostrophe": 0x27,
            "minus": 0x1B, "dash": 0x1B, "hyphen": 0x1B,
            "equals": 0x18, "equal": 0x18, "plus": 0x18,
            "leftbracket": 0x21, "rightbracket": 0x1E,
            "backslash": 0x2A, "grave": 0x32, "backtick": 0x32, "tilde": 0x32
        ]

        private static let letterKeys: [Character: Int] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
            "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
            "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
            "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
            "y": 0x10, "z": 0x06
        ]

        private static let digitKeys: [Character: Int] = [
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19
        ]

        /// ANSI/US punctuation keycodes — the literal characters a chord can
        /// carry ("cmd+,", "cmd+/", "cmd+[").
        private static let punctuationKeys: [Character: Int] = [
            ",": 0x2B, ".": 0x2F, "/": 0x2C, ";": 0x29, "'": 0x27,
            "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, "`": 0x32
        ]
    }

    // MARK: - Mouse
    // `leftClick`, `clampToNearestScreen`, `distance`, `quartzPoint`, and
    // `postMouseEvent` are ported verbatim from OpenClicky
    // (OpenClickyComputerUseRuntime.swift:1095-1162). Every public verb takes a
    // *global AppKit* point (bottom-left origin) and runs it through the same
    // clamp → per-display Quartz conversion before posting. The remaining verbs
    // (doubleClick, rightClick, moveCursor, drag, scroll) do not exist in
    // OpenClicky — they are built here on the same ported CGEvent base.

    enum Mouse {

        /// Move-then-press-then-release a left click at a global AppKit point.
        /// `modifiers` (e.g. ["shift"], ["cmd"]) are carried as CGEventFlags on the
        /// down/up events so shift-click / cmd-click select and multi-select work.
        static func leftClick(at point: CGPoint, modifiers: [String] = []) throws {
            // M9: clamp an off-screen point to the nearest screen before
            // converting, instead of handing an unconverted AppKit point
            // (wrong-Y) to a CGEvent — which previously landed an
            // intended-but-off-screen click at an unrelated on-screen location.
            // Now we find the nearest screen, clamp into its frame, and convert.
            // If no screen exists at all, we throw.
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("leftClick appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) mods=\(modifiers.joined(separator: "+")) → posting down/up via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            try postMouseEvent(type: .leftMouseDown, at: quartz, flags: flags)
            usleep(35_000)
            try postMouseEvent(type: .leftMouseUp, at: quartz, flags: flags)
        }

        /// Double-click at a global AppKit point. A double-click is two down/up
        /// cycles whose events carry an increasing `mouseEventClickState`: the
        /// window server reads the pair whose click state is 2 as the second
        /// click of a sequence. A bare single click at click-state 2 without the
        /// leading click-state-1 click is not reliably interpreted as a
        /// double-click by AppKit, so we post both cycles.
        static func doubleClick(at point: CGPoint, modifiers: [String] = []) throws {
            try multiClick(at: point, clicks: 2, modifiers: modifiers)
        }

        /// Triple-click (select a whole line/paragraph in most text views): the
        /// same escalating click-state sequence as doubleClick, taken to 3.
        static func tripleClick(at point: CGPoint, modifiers: [String] = []) throws {
            try multiClick(at: point, clicks: 3, modifiers: modifiers)
        }

        /// Shared body of double/triple click: N down/up cycles with click state
        /// 1...N so the window server reads them as one multi-click sequence.
        private static func multiClick(at point: CGPoint, clicks: Int, modifiers: [String]) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("multiClick x\(clicks) appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) mods=\(modifiers.joined(separator: "+")) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            for clickState in Int64(1)...Int64(clicks) {
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    guard let event = CGEvent(
                        mouseEventSource: nil,
                        mouseType: type,
                        mouseCursorPosition: quartz,
                        mouseButton: .left
                    ) else {
                        throw InputControllerError.eventCreationFailed("multi-click \(type.rawValue) at \(Int(quartz.x)),\(Int(quartz.y))")
                    }
                    event.setIntegerValueField(.mouseEventClickState, value: clickState)
                    if !flags.isEmpty { event.flags = flags }
                    event.post(tap: .cghidEventTap)
                    if type == .leftMouseDown { usleep(35_000) }
                }
            }
        }

        /// Right-click (secondary click) at a global AppKit point.
        static func rightClick(at point: CGPoint, modifiers: [String] = []) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("rightClick appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            try postMouseEvent(type: .rightMouseDown, at: quartz, button: .right, flags: flags)
            usleep(35_000)
            try postMouseEvent(type: .rightMouseUp, at: quartz, button: .right, flags: flags)
        }

        /// Middle-click (button 3, `.center`) at a global AppKit point — opens
        /// links in background tabs, closes browser tabs, pastes in terminals.
        static func middleClick(at point: CGPoint, modifiers: [String] = []) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("middleClick appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            try postMouseEvent(type: .otherMouseDown, at: quartz, button: .center, flags: flags)
            usleep(35_000)
            try postMouseEvent(type: .otherMouseUp, at: quartz, button: .center, flags: flags)
        }

        /// Press-and-HOLD the left button at a point (no release). Pairs with
        /// `leftMouseUp` so the model can compose manual press → move → release
        /// sequences (slow drags, press-and-hold UI) that `drag`'s fixed
        /// interpolation can't express.
        static func leftMouseDown(at point: CGPoint, modifiers: [String] = []) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("leftMouseDown appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            try postMouseEvent(type: .leftMouseDown, at: quartz, flags: flags)
        }

        /// Release a held left button at a point. Deliberately does NOT post a
        /// leading `.mouseMoved`: while the button is down, a plain move event
        /// can confuse drag tracking — the up event itself carries the position.
        static func leftMouseUp(at point: CGPoint, modifiers: [String] = []) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            let flags = Keyboard.modifierMask(for: modifiers)
            InputController.diag("leftMouseUp appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) → posting via cghidEventTap")
            try postMouseEvent(type: .leftMouseUp, at: quartz, flags: flags)
        }

        /// Move the cursor to a global AppKit point without pressing anything.
        static func moveCursor(to point: CGPoint) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            InputController.diag("moveCursor appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
        }

        /// Press at `start`, drag through interpolated steps, release at `end`
        /// (all global AppKit points). The intermediate `.leftMouseDragged`
        /// events matter: apps that implement drag-to-select or drag-and-drop
        /// track the continuous path, so a bare down-at-start / up-at-end pair
        /// with no motion between them is frequently treated as a plain click.
        static func drag(from start: CGPoint, to end: CGPoint) throws {
            let quartzStart = try quartzPoint(fromAppKitPoint: clampToNearestScreen(start))
            let quartzEnd = try quartzPoint(fromAppKitPoint: clampToNearestScreen(end))
            InputController.diag("drag quartzStart=(\(Int(quartzStart.x)),\(Int(quartzStart.y))) quartzEnd=(\(Int(quartzEnd.x)),\(Int(quartzEnd.y))) → posting via cghidEventTap")

            try postMouseEvent(type: .mouseMoved, at: quartzStart)
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: quartzStart,
                mouseButton: .left
            ) else {
                throw InputControllerError.eventCreationFailed("drag down at \(Int(quartzStart.x)),\(Int(quartzStart.y))")
            }
            down.post(tap: .cghidEventTap)
            usleep(35_000)

            let steps = 20
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: quartzStart.x + (quartzEnd.x - quartzStart.x) * t,
                    y: quartzStart.y + (quartzEnd.y - quartzStart.y) * t
                )
                guard let dragged = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDragged,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else {
                    throw InputControllerError.eventCreationFailed("drag move at \(Int(point.x)),\(Int(point.y))")
                }
                dragged.post(tap: .cghidEventTap)
                usleep(8_000)
            }

            guard let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: quartzEnd,
                mouseButton: .left
            ) else {
                throw InputControllerError.eventCreationFailed("drag up at \(Int(quartzEnd.x)),\(Int(quartzEnd.y))")
            }
            up.post(tap: .cghidEventTap)
        }

        /// Scroll at a global AppKit point by pixel deltas (`dx` horizontal,
        /// `dy` vertical). Scroll-wheel events are routed to the view under the
        /// cursor, so we position the cursor over the target first, then post a
        /// pixel-unit wheel event whose location is pinned to that point.
        static func scroll(at point: CGPoint, dx: Int, dy: Int) throws {
            let clampedPoint = clampToNearestScreen(point)
            let quartz = try quartzPoint(fromAppKitPoint: clampedPoint)
            InputController.diag("scroll appKit=(\(Int(point.x)),\(Int(point.y))) quartz=(\(Int(quartz.x)),\(Int(quartz.y))) dx=\(dx) dy=\(dy) → posting via cghidEventTap")
            try postMouseEvent(type: .mouseMoved, at: quartz)
            // wheelCount 2 carries both axes: wheel1 is vertical, wheel2 is
            // horizontal. Pixel units so model-supplied deltas map 1:1 to pixels.
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0
            ) else {
                throw InputControllerError.eventCreationFailed("scroll dx=\(dx) dy=\(dy) at \(Int(quartz.x)),\(Int(quartz.y))")
            }
            event.location = quartz
            event.post(tap: .cghidEventTap)
        }

        // MARK: Coordinate conversion (verbatim from OpenClicky)

        /// Clamp a point to the nearest screen's frame (used when a model-derived
        /// coordinate lands in a gap between displays or outside the desktop union).
        private static func clampToNearestScreen(_ point: CGPoint) -> CGPoint {
            if NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
                return point
            }
            let nearest = NSScreen.screens.min(by: { lhs, rhs in
                distance(from: point, to: lhs.frame) < distance(from: point, to: rhs.frame)
            })
            guard let frame = nearest?.frame else { return point }
            return CGPoint(
                x: min(max(point.x, frame.minX), frame.maxX),
                y: min(max(point.y, frame.minY), frame.maxY)
            )
        }

        /// Squared edge-distance from a point to a rect (0 when inside). Squared
        /// is sufficient for the nearest-screen comparison and avoids a sqrt.
        private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return (dx * dx) + (dy * dy)
        }

        /// Convert a global AppKit point (bottom-left origin) into the Quartz
        /// space CGEvent consumes (top-left origin), *per display*. Global-frame
        /// arithmetic is wrong on multi-monitor rigs because each display's
        /// AppKit frame and its `CGDisplayBounds` can have different origins;
        /// this resolves the containing screen, localizes into it, flips Y, then
        /// re-offsets by that display's Quartz origin.
        private static func quartzPoint(fromAppKitPoint point: CGPoint) throws -> CGPoint {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                // After clamping this should not happen unless there are no
                // screens at all (headless / display sleep). Throw rather than
                // hand an unconverted AppKit point (wrong Y axis) to CGEvent.
                throw InputControllerError.eventCreationFailed("click target is off-screen and no display is available")
            }

            let appKitFrame = screen.frame
            let quartzFrame = CGDisplayBounds(displayID)
            let localX = point.x - appKitFrame.origin.x
            let localYFromTop = appKitFrame.maxY - point.y
            return CGPoint(
                x: quartzFrame.origin.x + localX,
                y: quartzFrame.origin.y + localYFromTop
            )
        }

        /// Post a single mouse event at an already-converted Quartz point. Used
        /// for the move/down/up edges of every click verb. `button` selects
        /// left/right/center; `flags` (when non-empty) carries held modifiers on
        /// the event — only set when requested, so the system's implicit flags on
        /// a fresh event are left untouched for plain clicks.
        private static func postMouseEvent(type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) throws {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            ) else {
                throw InputControllerError.eventCreationFailed("mouse \(type.rawValue) at \(Int(point.x)),\(Int(point.y))")
            }
            if !flags.isEmpty { event.flags = flags }
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - InputControllerError

/// Errors thrown by the primitive input layer. Mirrors the two failure modes
/// OpenClicky's runtime surfaces: an unrecognized key name and a CGEvent that
/// the system refused to construct (carrying a short detail for logging).
enum InputControllerError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    case eventCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownKey(let key):
            return "Unknown key name: \(key)"
        case .eventCreationFailed(let detail):
            return "Failed to create input event: \(detail)"
        }
    }
}
