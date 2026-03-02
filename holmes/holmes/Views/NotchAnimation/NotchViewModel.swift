import SwiftUI
import Combine

enum NotchState: Equatable {
    case idle
    case active(taskName: String, progress: Double)
    case notification(title: String, subtitle: String, symbol: String)
    case expanded
}

class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .idle
    @Published var breathingPhase: CGFloat = 0
    @Published var isHovered: Bool = false
    
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
    
    func startTask(name: String) {
        notificationResetTask?.cancel()
        withAnimation(NoirAnimations.smooth) {
            state = .active(taskName: name, progress: 0)
        }
    }
    
    func updateProgress(_ progress: Double) {
        if case .active(let name, _) = state {
            state = .active(taskName: name, progress: progress)
        }
    }
    
    func completeTask() {
        if case .active(_, _) = state {
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
