import SwiftUI
import Combine
import AppKit
import ScreenCaptureKit

enum OnboardingStep: Int, CaseIterable {
    /// Required account step, skipped when a session already exists.
    case signIn = 0
    case welcome = 1
    case howItWorks = 2
    case permissions = 3
    /// "Your local model": get Ollama running and the default model pulled,
    /// so a first-run user leaves onboarding with a working local brain.
    case localModel = 4
    /// Install + pair the bundled browser extension (exact page reads).
    case browser = 5
    /// Optional Composio connection for the read-only playbook tools.
    case integrations = 6
    case ready = 7

    /// Sign in and Welcome are entry screens without progress dots.
    var showsStepIndicator: Bool { self != .signIn && self != .welcome }

    /// The steps the progress dots count. Sign in is not one of them.
    static var indicatorSteps: [OnboardingStep] { allCases.filter { $0 != .signIn } }

    var indicatorIndex: Int { Self.indicatorSteps.firstIndex(of: self) ?? 0 }
}

class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep

    init(startStep: OnboardingStep = .welcome) {
        currentStep = startStep
    }
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var hasAutomationPermission = false
    @Published var isCheckingPermissions = false
    
    var allPermissionsGranted: Bool {
        hasScreenRecordingPermission && hasAccessibilityPermission
    }
    
    var canProceedFromPermissions: Bool {
        allPermissionsGranted
    }
    
    func nextStep() {
        guard let nextIndex = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        withAnimation(NoirAnimations.smooth) {
            currentStep = nextIndex
        }
    }
    
    func previousStep() {
        guard let prevIndex = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        withAnimation(NoirAnimations.smooth) {
            currentStep = prevIndex
        }
    }
    
    func goToStep(_ step: OnboardingStep) {
        withAnimation(NoirAnimations.smooth) {
            currentStep = step
        }
    }
    
    func checkPermissions() {
        isCheckingPermissions = true
        
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = checkScreenRecordingPermission()
        hasAutomationPermission = true
        
        isCheckingPermissions = false
    }
    
    private func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkPermissions()
        }
    }
    
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPermissions()
        }
    }
    
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPermissions()
        }
    }
    
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
}
