import AppKit
import Observation
import SwiftUI

/// The small corner notice shown after Holmes writes into an email, with one
/// click Undo. It is a non activating panel, so the email keeps keyboard focus
/// and Command Z in the email keeps working.
@MainActor
enum EmailUndoPresenter {
    static func show(title: String, detail: String, undo: @escaping @MainActor () async -> String) {
        EmailUndoToastController.shared.show(title: title, detail: detail, undo: undo)
    }

    static func hide() { EmailUndoToastController.shared.hide() }
}

@MainActor
@Observable
final class EmailUndoToastModel {
    var title = ""
    var detail = ""
    var result: String?
    var isWorking = false
    @ObservationIgnored var undo: (@MainActor () async -> String)?
    var canUndo = false
    /// Increments for every new toast, so a late undo result for an older write
    /// never changes a newer toast.
    @ObservationIgnored var generation = 0
}

@MainActor
final class EmailUndoToastController {
    static let shared = EmailUndoToastController()
    private let model = EmailUndoToastModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(title: String, detail: String, undo: @escaping @MainActor () async -> String) {
        model.generation += 1
        model.title = title
        model.detail = detail
        model.result = nil
        model.isWorking = false
        model.undo = undo
        model.canUndo = true
        if panel == nil { panel = makePanel() }
        guard let panel, let screen = NSScreen.main else { return }
        let size = CGSize(width: 340, height: 74)
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        scheduleHide(after: 20)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        model.undo = nil
        model.canUndo = false
        panel?.orderOut(nil)
    }

    private func performUndo() {
        guard let undo = model.undo, !model.isWorking else { return }
        hideTask?.cancel()
        model.isWorking = true
        let generation = model.generation
        Task { @MainActor in
            let message = await undo()
            guard model.generation == generation else { return }
            model.isWorking = false
            model.result = message
            model.undo = nil
            model.canUndo = false
            scheduleHide(after: 5)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: EmailUndoToastView(
            model: model, onUndo: { [weak self] in self?.performUndo() }, onClose: { [weak self] in self?.hide() }))
        return panel
    }
}

struct EmailUndoToastView: View {
    let model: EmailUndoToastModel
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NoirColors.iconPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(NoirFonts.font(size: 12, weight: .semibold))
                    .foregroundStyle(NoirColors.textPrimary)
                Text(model.result ?? model.detail)
                    .font(NoirFonts.caption())
                    .foregroundStyle(NoirColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if model.isWorking {
                ProgressView().controlSize(.small)
            } else if model.canUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .font(NoirFonts.font(size: 12, weight: .semibold))
                    .foregroundStyle(NoirColors.accent)
                    .accessibilityLabel("Undo what Holmes wrote")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NoirColors.iconSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NoirColors.glassElevated, in: RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(.dark)
    }
}
