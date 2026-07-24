import AppKit
import ApplicationServices
import Carbon.HIToolbox

class HotkeyManager {
    static let shared = HotkeyManager()

    private var controlSpaceHandler: EventHotKeyRef?
    private var optionSpaceHandler: EventHotKeyRef?
    private var commandBackslashHandler: EventHotKeyRef?
    private var commandOptionEscapeHandler: EventHotKeyRef?

    private var controlSpaceID = EventHotKeyID(signature: OSType(0x484F4C4D), id: 1)
    private var optionSpaceID = EventHotKeyID(signature: OSType(0x484F4C4D), id: 2)
    private var commandBackslashID = EventHotKeyID(signature: OSType(0x484F4C4D), id: 3)
    // ⌘⌥Esc — the computer-control kill switch. A global hotkey so it works even
    // while another app is frontmost mid-run.
    private var commandOptionEscapeID = EventHotKeyID(signature: OSType(0x484F4C4D), id: 4)

    // Clicky push-to-talk — HOLD the Fn (globe) key. The Fn key is a modifier FLAG,
    // not a keycode, so Carbon's RegisterEventHotKey can't bind it. Instead we watch
    // NSEvent .flagsChanged for the .function flag and drive true hold-to-talk:
    // Fn-down begins listening, Fn-up ends it and delivers the transcript. Both a
    // global monitor (works while another app is frontmost — needs Accessibility
    // trust, which Holmes already has) and a local monitor (works when Holmes is
    // frontmost) are installed; their tokens are stored so teardown can remove them.
    private var fnMonitors: [Any] = []
    /// Tracks the .function flag across events so `begin` fires only on a genuine
    /// false→true edge and `end` only on a genuine true→false edge (guards against
    /// duplicate .flagsChanged events that keep the flag in the same state).
    private var fnKeyIsDown = false

    var onControlSpace: (() -> Void)?
    var onOptionSpace: (() -> Void)?
    var onCommandBackslash: (() -> Void)?
    var onCommandOptionEscape: (() -> Void)?
    /// Fn pressed (false→true edge) — begin push-to-talk.
    var onPushToTalkDown: (() -> Void)?
    /// Fn released (true→false edge) — end push-to-talk and route the transcript.
    var onPushToTalkUp: (() -> Void)?

    private init() {}

    func registerHotkeys() {
        registerControlSpace()
        registerOptionSpace()
        registerCommandBackslash()
        registerCommandOptionEscape()
        installFnPushToTalkMonitor()
        installEventHandler()
    }

    func unregisterHotkeys() {
        if let handler = controlSpaceHandler {
            UnregisterEventHotKey(handler)
        }
        if let handler = optionSpaceHandler {
            UnregisterEventHotKey(handler)
        }
        if let handler = commandBackslashHandler {
            UnregisterEventHotKey(handler)
        }
        if let handler = commandOptionEscapeHandler {
            UnregisterEventHotKey(handler)
        }
        fnMonitors.forEach { NSEvent.removeMonitor($0) }
        fnMonitors.removeAll()
        fnKeyIsDown = false
    }
    
    private func registerControlSpace() {
        let modifier = UInt32(Carbon.controlKey)
        let keyCode = UInt32(kVK_Space)
        
        RegisterEventHotKey(
            keyCode,
            modifier,
            controlSpaceID,
            GetApplicationEventTarget(),
            0,
            &controlSpaceHandler
        )
    }
    
    private func registerOptionSpace() {
        let modifier = UInt32(Carbon.optionKey)
        let keyCode = UInt32(kVK_Space)
        
        RegisterEventHotKey(
            keyCode,
            modifier,
            optionSpaceID,
            GetApplicationEventTarget(),
            0,
            &optionSpaceHandler
        )
    }
    
    private func registerCommandBackslash() {
        let modifier = UInt32(Carbon.cmdKey)
        let keyCode = UInt32(kVK_ANSI_Backslash)

        RegisterEventHotKey(
            keyCode,
            modifier,
            commandBackslashID,
            GetApplicationEventTarget(),
            0,
            &commandBackslashHandler
        )
    }

    private func registerCommandOptionEscape() {
        let modifier = UInt32(Carbon.cmdKey | Carbon.optionKey)
        let keyCode = UInt32(kVK_Escape)

        RegisterEventHotKey(
            keyCode,
            modifier,
            commandOptionEscapeID,
            GetApplicationEventTarget(),
            0,
            &commandOptionEscapeHandler
        )
    }

    /// Installs the Fn (globe) hold-to-talk detector. Unlike the Carbon hotkeys
    /// above, the Fn key isn't a keycode — it's the `.function` modifier flag — so
    /// we observe `.flagsChanged` via NSEvent monitors and track the flag's edges.
    ///
    /// Both monitors are installed on purpose:
    ///   • the GLOBAL monitor sees events while another app is frontmost (this is
    ///     the common case for push-to-talk), but requires Accessibility trust;
    ///   • the LOCAL monitor sees events when Holmes itself is frontmost.
    /// The same `handleFnFlagsChanged(_:)` de-dupes across both via `fnKeyIsDown`,
    /// so a single physical press never double-fires.
    ///
    /// macOS caveat: depending on System Settings ▸ Keyboard ▸ "Press 🌐 key to",
    /// the Fn/globe key may ALSO surface the emoji/dictation picker or change the
    /// input source. A monitor cannot suppress that (global monitors are passive —
    /// they observe but never consume events), and we intentionally don't try to.
    /// Starting/stopping listening on the flag edge still works alongside it.
    private func installFnPushToTalkMonitor() {
        // The global monitor only receives keyboard/flag events when the process is
        // Accessibility-trusted. Holmes already is (it posts CGEvents for computer
        // control), but log clearly if that ever isn't the case.
        if !AXIsProcessTrusted() {
            print("HotkeyManager: Accessibility is not trusted — the global Fn hold-to-talk monitor won't receive events while another app is frontmost. Grant access in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnFlagsChanged(event)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnFlagsChanged(event)
            return event
        }

        if let global { fnMonitors.append(global) }
        if let local { fnMonitors.append(local) }
    }

    /// Fires begin/end push-to-talk on genuine transitions of the Fn (`.function`)
    /// flag only. `.flagsChanged` can arrive repeatedly for one physical press (and
    /// once from each of the two monitors), so we ignore any event that doesn't flip
    /// `fnKeyIsDown`. Invoked on the main thread by NSEvent.
    private func handleFnFlagsChanged(_ event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function)
        guard fnDown != fnKeyIsDown else { return }
        fnKeyIsDown = fnDown
        if fnDown {
            onPushToTalkDown?()
        } else {
            onPushToTalkUp?()
        }
    }


    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        HotkeyManager.shared.onControlSpace?()
                    case 2:
                        HotkeyManager.shared.onOptionSpace?()
                    case 3:
                        HotkeyManager.shared.onCommandBackslash?()
                    case 4:
                        HotkeyManager.shared.onCommandOptionEscape?()
                    default:
                        break
                    }
                }
                
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )
    }
}

class LocalHotkeyManager {
    static let shared = LocalHotkeyManager()
    
    private var monitors: [Any] = []
    
    var onControlSpace: (() -> Void)?
    var onOptionSpace: (() -> Void)?
    var onCommandBackslash: (() -> Void)?
    
    private init() {}
    
    func start() {
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        if let global = globalMonitor {
            monitors.append(global)
        }
        if let local = localMonitor {
            monitors.append(local)
        }
    }
    
    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Space key = 49
        if event.keyCode == 49 {
            if flags == .control {
                onControlSpace?()
            } else if flags == .option {
                onOptionSpace?()
            }
        }
        
        // Backslash key = 42
        if event.keyCode == 42 && flags == .command {
            onCommandBackslash?()
        }
    }
}
