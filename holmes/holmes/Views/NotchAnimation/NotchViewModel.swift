// Ported from boring.notch (GPL-3.0, © TheBoredTeam and contributors):
// https://github.com/TheBoredTeam/boring.notch — models/BoringViewModel.swift
// (the open/close notch state machine, notchSize/closedNotchSize handling, and
// effectiveClosedNotchHeight). Content fields adapted for Holmes: instead of
// music/battery, the notch carries WHAT Holmes is doing (task + step + progress)
// and the live context it sees. See THIRD_PARTY_NOTICES.md.

import AppKit
import Combine
import SwiftUI

enum NotchState {
    case closed
    case open
}

/// The transient reveal below the camera housing; auto-hides.
struct NotchSneakPeek: Equatable {
    var show = false
    var title = ""
    var subtitle = ""
    var symbol = "sparkles"
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var notchState: NotchState = .closed
    @Published private(set) var geometry: NotchGeometry.Layout

    init(geometry: NotchGeometry.Layout? = nil) {
        self.geometry = geometry ?? NotchGeometry.layout(on: NotchDetector.preferredScreen)
    }

    var closedNotchSize: CGSize { geometry.closedSize }
    var notchSize: CGSize {
        if notchState == .open { return geometry.openSize }
        if sneakPeek.show || taskActive { return geometry.compactSize }
        return geometry.closedSize
    }

    // MARK: Holmes content (replaces boring.notch's music/battery/shelf state)

    /// The live-context one-liner ("Editing ScreenEngine.swift in holmes").
    @Published var contextLine: String = ""
    @Published var contextSymbol: String = "eye"

    /// The in-flight autonomous task, shown below the notch in compact and
    /// expanded states.
    @Published var taskActive = false
    @Published var taskName: String = ""
    @Published var taskStep: String = ""
    @Published var taskProgress: Double = 0
    @Published var taskIsIndeterminate = true
    @Published var taskPhase: WorkActivityCenter.Phase = .preparing
    @Published var additionalTaskCount = 0

    /// Last finished run's one-liner, shown in the open panel.
    @Published var lastResult: String = ""
    @Published var lastResultSymbol = "checkmark.circle.fill"
    @Published var lastResultFailed = false

    @Published var sneakPeek = NotchSneakPeek()

    private var sneakPeekTask: Task<Void, Never>?
    private var completionRevision: UInt64?

    func synchronize(with center: WorkActivityCenter) {
        let activity = center.selectedActivity
        taskActive = activity != nil
        taskName = activity?.title ?? ""
        taskStep = activity?.detail ?? ""
        taskPhase = activity?.phase ?? .preparing
        taskProgress = activity?.progress ?? 0
        taskIsIndeterminate = activity?.progress == nil
        additionalTaskCount = max(0, center.activeCount - 1)

        guard let completion = center.completion else {
            if completionRevision != nil {
                completionRevision = nil
                lastResult = ""
                hideSneakPeek()
            }
            return
        }
        guard completion.revision != completionRevision else { return }
        completionRevision = completion.revision
        let title: String
        switch completion.outcome {
        case .success:
            title = "Holmes finished"
            lastResultSymbol = "checkmark.circle.fill"
        case .failure:
            title = "Holmes couldn't finish"
            lastResultSymbol = "exclamationmark.triangle.fill"
        case .cancelled:
            title = "Holmes stopped"
            lastResultSymbol = "stop.circle"
        }
        lastResultFailed = completion.outcome == .failure
        lastResult = completion.summary
        // Background work and other live requests retain their continuous
        // indicator. The outcome is still available in the expanded panel.
        if !taskActive {
            showSneakPeek(title: title, subtitle: completion.summary,
                          symbol: lastResultSymbol, duration: completion.outcome == .failure ? 6 : 3.5)
        }
    }

    func hideSneakPeek() {
        sneakPeekTask?.cancel()
        sneakPeekTask = nil
        sneakPeek.show = false
    }

    var effectiveClosedNotchHeight: CGFloat { closedNotchSize.height }

    func open() {
        notchState = .open
    }

    func close() {
        notchState = .closed
    }

    func refreshNotchSize(for screen: NSScreen?) {
        geometry = NotchGeometry.layout(on: screen)
    }

    /// Show a transient closed-notch reveal; replaces any current one and
    /// auto-hides after `duration`.
    func showSneakPeek(title: String, subtitle: String, symbol: String, duration: TimeInterval) {
        sneakPeekTask?.cancel()
        withAnimation(.smooth) {
            sneakPeek = NotchSneakPeek(show: true, title: title, subtitle: subtitle, symbol: symbol)
        }
        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                self?.sneakPeek.show = false
            }
        }
    }
}
