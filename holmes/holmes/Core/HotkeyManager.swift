import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A hold starts only on the physical Fn key's own flagsChanged event. Other
/// keys may carry .function (including navigation/function keys); that flag alone
/// is never permission to open the microphone.
struct FnHoldState {
    enum Transition: Equatable {
        case began(UUID)
        case ended(UUID)
        case cancelled(UUID)
    }

    private(set) var activeID: UUID?

    mutating func handle(keyCode: UInt16, functionFlag: Bool, physicalFnDown: Bool) -> Transition? {
        if !physicalFnDown { return release() }
        guard keyCode == UInt16(kVK_Function) else { return nil }
        guard functionFlag else { return release() }
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return .began(id)
    }

    /// Polling only ends a hold; it must never start one on launch or wake.
    mutating func reconcile(physicalFnDown: Bool) -> Transition? {
        physicalFnDown ? nil : release()
    }

    mutating func cancel() -> Transition? {
        guard let id = activeID else { return nil }
        activeID = nil
        return .cancelled(id)
    }

    private mutating func release() -> Transition? {
        guard let id = activeID else { return nil }
        activeID = nil
        return .ended(id)
    }
}

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

    private var fnMonitors: [Any] = []
    private var fnHold = FnHoldState()
    private var fnReleaseWatchdog: Timer?
    private var fnLifecycleObservers: [NSObjectProtocol] = []

    /// Hardware state, rather than the flags on an unrelated/synthetic event.
    static var isPhysicalFnDown: Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))
    }

    func isPushToTalkHeld(_ id: UUID) -> Bool {
        fnHold.activeID == id && Self.isPhysicalFnDown
    }

    var onControlSpace: (() -> Void)?
    var onOptionSpace: (() -> Void)?
    var onCommandBackslash: (() -> Void)?
    var onCommandOptionEscape: (() -> Void)?
    /// Fn pressed (false→true edge) — begin push-to-talk.
    var onPushToTalkDown: ((UUID) -> Void)?
    /// Fn released (true→false edge) — end push-to-talk and route the transcript.
    var onPushToTalkUp: ((UUID) -> Void)?
    /// A nil ID also cancels speech still finalizing after the key was released.
    /// Invoked on the main thread; lifecycle cancellation must be synchronous.
    var onPushToTalkCancel: ((UUID?) -> Void)?

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
        cancelPushToTalk()
        fnReleaseWatchdog?.invalidate()
        fnReleaseWatchdog = nil
        fnMonitors.forEach { NSEvent.removeMonitor($0) }
        fnMonitors.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        fnLifecycleObservers.forEach { center.removeObserver($0) }
        fnLifecycleObservers.removeAll()
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

    /// Both monitors are passive: macOS still handles the user's Globe-key
    /// preference. The keycode and hardware state distinguish a real hold from
    /// unrelated .function flags. No recording or permission prompt starts here.
    private func installFnPushToTalkMonitor() {
        guard fnMonitors.isEmpty else { return }
        if !AXIsProcessTrusted() {
            print("HotkeyManager: Accessibility is not trusted — grant it to use Fn hold-to-talk while another app is frontmost.")
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

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            fnLifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.cancelPushToTalk()
            })
        }
    }

    /// A released key no longer has a hotkey ID, but its recognizer can still
    /// be flushing speech. Always notify the voice owner on sleep/lock/teardown.
    /// Active holds retain their ID so their cancellation cannot affect a newer
    /// hold. A nil cancellation is delivered synchronously by AppDelegate.
    func cancelPushToTalk() {
        if let transition = fnHold.cancel() {
            publishFnTransition(transition)
        } else {
            fnReleaseWatchdog?.invalidate()
            fnReleaseWatchdog = nil
            onPushToTalkCancel?(nil)
        }
    }

    private func handleFnFlagsChanged(_ event: NSEvent) {
        let transition = fnHold.handle(keyCode: event.keyCode,
                                       functionFlag: event.modifierFlags.contains(.function),
                                       physicalFnDown: Self.isPhysicalFnDown)
        publishFnTransition(transition)
    }

    private func publishFnTransition(_ transition: FnHoldState.Transition?) {
        guard let transition else { return }
        switch transition {
        case .began(let id):
            // Common modes also run while a menu or permission sheet is open.
            // Only an active hold pays for polling; a missed key-up cannot leave
            // capture running until some unrelated keyboard event arrives.
            fnReleaseWatchdog?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.publishFnTransition(self.fnHold.reconcile(physicalFnDown: Self.isPhysicalFnDown))
            }
            fnReleaseWatchdog = timer
            RunLoop.main.add(timer, forMode: .common)
            onPushToTalkDown?(id)
        case .ended(let id):
            fnReleaseWatchdog?.invalidate()
            fnReleaseWatchdog = nil
            onPushToTalkUp?(id)
        case .cancelled(let id):
            fnReleaseWatchdog?.invalidate()
            fnReleaseWatchdog = nil
            onPushToTalkCancel?(id)
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
