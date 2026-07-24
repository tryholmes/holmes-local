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

/// The transient one-line reveal on the CLOSED notch (boring.notch's
/// "sneak peek" / battery-notification pattern): text on the left wing,
/// symbol on the right wing, auto-hides.
struct NotchSneakPeek: Equatable {
    var show = false
    var title = ""
    var subtitle = ""
    var symbol = "sparkles"
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var notchState: NotchState = .closed
    @Published var notchSize: CGSize = NotchGeometry.closedNotchSize(on: NSScreen.main)
    @Published var closedNotchSize: CGSize = NotchGeometry.closedNotchSize(on: NSScreen.main)

    // MARK: Holmes content (replaces boring.notch's music/battery/shelf state)

    /// The live-context one-liner ("Editing ScreenEngine.swift in holmes").
    @Published var contextLine: String = ""
    @Published var contextSymbol: String = "eye"

    /// The in-flight autonomous task, shown as closed-notch "wings" (bolt +
    /// progress) and in the open panel.
    @Published var taskActive = false
    @Published var taskName: String = ""
    @Published var taskStep: String = ""
    @Published var taskProgress: Double = 0

    /// Last finished run's one-liner, shown in the open panel.
    @Published var lastResult: String = ""

    @Published var sneakPeek = NotchSneakPeek()

    private var sneakPeekTask: Task<Void, Never>?

    var effectiveClosedNotchHeight: CGFloat { closedNotchSize.height }

    func open() {
        notchSize = NotchGeometry.openSize
        notchState = .open
    }

    func close() {
        notchSize = NotchGeometry.closedNotchSize(on: NSScreen.main)
        closedNotchSize = notchSize
        notchState = .closed
    }

    func refreshNotchSize(for screen: NSScreen?) {
        let size = NotchGeometry.closedNotchSize(on: screen)
        closedNotchSize = size
        if notchState == .closed { notchSize = size }
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
