import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import EventKit

struct PermissionManager {
    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }
    
    static func checkScreenRecordingPermission() -> Bool {
        var hasPermission = false
        let semaphore = DispatchSemaphore(value: 0)
        
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            hasPermission = (error == nil && content != nil)
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 1.0)
        return hasPermission
    }
    
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility stale-grant detection + relaunch
    //
    // macOS evaluates a process's Accessibility trust when the process starts. A
    // grant flipped on in System Settings WHILE Holmes is running is written to
    // TCC but this process keeps seeing AXIsProcessTrusted() == false until it is
    // relaunched — the classic "I granted it but nothing happens" trap, and the
    // reason clicks/keystrokes silently land nowhere right after granting.

    /// True when the user has computer control switched ON but this process does
    /// not see Accessibility trust. In a running session that combination almost
    /// always means "granted, but the grant is stale for this process" — the fix
    /// is a relaunch, not another trip to System Settings. Reads the persisted
    /// default directly (a plain `static let` key) so this stays callable from
    /// nonisolated contexts without touching the @MainActor engine.
    static func needsRelaunchForAccessibility() -> Bool {
        UserDefaults.standard.bool(forKey: ComputerUseEngine.enabledDefaultsKey)
            && !AXIsProcessTrusted()
    }

    /// The standard relaunch dance: after a brief delay, ask LaunchServices to
    /// start a NEW instance of this same bundle, then terminate the current one.
    /// The fresh process re-evaluates AXIsProcessTrusted() at launch and picks up
    /// any grant made while this instance was running.
    static func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let configuration = NSWorkspace.OpenConfiguration()
            // Without this, openApplication would merely ACTIVATE the running
            // instance (us) and no fresh process — with fresh trust — would start.
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
    
    static func checkMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    static func checkCalendarPermission() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .authorized || status == .fullAccess
    }

    static func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    static var allRequiredPermissionsGranted: Bool {
        checkAccessibilityPermission() && checkScreenRecordingPermission()
    }
}
