import SwiftUI
import Combine

enum NotchState: Equatable {
    case idle
    case active(taskName: String, context: String, progress: Double)
    case notification(title: String, subtitle: String, symbol: String)
    case expanded
}

class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .idle
    @Published var breathingPhase: CGFloat = 0
    @Published var isHovered: Bool = false
    /// The live-context one-liner ("Coding in Ghostty", "Reading a PR on GitHub").
    /// Drives the idle bar's hover subtitle so the notch always states the CURRENT
    /// context, never a stale one. Set from HolmesAgent on every new screen.
    @Published var contextLine: String = ""

    /// The REAL closed-notch size for the active screen — the collapsed bar hugs
    /// exactly this so it blends into the physical notch. Refreshed on screen change.
    @Published var notchSize: CGSize = NotchDetector.closedNotchSize(on: NSScreen.main)

    func refreshNotchSize(for screen: NSScreen?) {
        let newSize = NotchDetector.closedNotchSize(on: screen)
        if newSize != notchSize { notchSize = newSize }
    }
    
    private var breathingTimer: Timer?
    private var notificationResetTask: DispatchWorkItem?
    
    var hasNotch: Bool {
        NotchDetector.hasNotch
    }
    
    func startIdleAnimation() {
        guard hasNotch else { return }
        
        breathingTimer?.invalidate()
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.breathingPhase += 0.02
                if self.breathingPhase > 2 * .pi {
                    self.breathingPhase = 0
                }
            }
        }
    }
    
    func stopIdleAnimation() {
        breathingTimer?.invalidate()
        breathingTimer = nil
    }

    func showNotification(
        title: String,
        subtitle: String,
        symbol: String = "bell.badge.fill",
        duration: TimeInterval = 3
    ) {
        notificationResetTask?.cancel()

        withAnimation(NoirAnimations.spring) {
            state = .notification(title: title, subtitle: subtitle, symbol: symbol)
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            withAnimation(NoirAnimations.smooth) {
                if case .notification = self.state {
                    self.state = .idle
                }
            }
        }

        notificationResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
    
    func startTask(name: String, context: String = "") {
        notificationResetTask?.cancel()
        withAnimation(NoirAnimations.smooth) {
            state = .active(taskName: name, context: context, progress: 0)
        }
    }

    /// Advance the active task. `step`, when given, replaces the top line with the
    /// CURRENT action ("Opening Finder", "Clicking Send") while the context line
    /// under it stays put — so the notch shows both "what Holmes is doing" and
    /// "what context it's doing it in" at once.
    func updateProgress(_ progress: Double, step: String? = nil) {
        if case .active(let name, let context, _) = state {
            state = .active(taskName: step ?? name, context: context, progress: progress)
        }
    }

    func setContextLine(_ line: String) {
        contextLine = line
        // Keep an in-flight task's context line current too.
        if case .active(let name, _, let progress) = state {
            state = .active(taskName: name, context: line, progress: progress)
        }
    }

    func completeTask() {
        if case .active = state {
            withAnimation(NoirAnimations.smooth) {
                state = .idle
            }
        }
    }
    
    func expand() {
        withAnimation(NoirAnimations.spring) {
            state = .expanded
        }
    }
    
    func collapse() {
        withAnimation(NoirAnimations.smooth) {
            state = .idle
        }
    }
}
