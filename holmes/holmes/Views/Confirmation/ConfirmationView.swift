import SwiftUI
import Observation

// MARK: - Pending Action
// Represents something Holmes wants to do — shown for user approval before executing.

struct PendingAction: Identifiable {
    let id = UUID()
    let title: String           // e.g. "Reply to Imda on Discord"
    let preview: String         // The text/action Holmes will perform
    let appName: String         // Target app
    let actionType: ActionType
    var isExecuting: Bool = false
    var result: String? = nil

    // Meeting-specific (only set for .openMeeting)
    var meetingURL: URL? = nil
    var meeting: UpcomingMeeting? = nil

    enum ActionType {
        case typeMessage    // Type text into a message field
        case openURL        // Open a URL
        case runScript      // Shell script
        case openMeeting    // Join a video call
    }
}

// MARK: - ConfirmationBus
// HolmesAgent posts here when it detects something actionable.
// ConfirmationWindow observes and shows the overlay.

@Observable
final class ConfirmationBus {
    static let shared = ConfirmationBus()
    private init() {}

    var pendingAction: PendingAction? = nil
    var isShowing: Bool = false

    func propose(_ action: PendingAction) {
        pendingAction = action
        isShowing = true
        ConfirmationWindowController.shared.show()
    }

    func dismiss() {
        isShowing = false
        pendingAction = nil
        ConfirmationWindowController.shared.hide()
    }

    func execute() {
        guard var action = pendingAction else { return }
        action.isExecuting = true
        pendingAction = action

        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            switch action.actionType {
            case .typeMessage:
                success = ActionExecutor.shared.sendMessageInApp(action.appName, message: action.preview)
            case .openURL:
                if let url = URL(string: action.preview) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    success = true
                }
            case .runScript:
                success = false
            case .openMeeting:
                DispatchQueue.main.async {
                    if let meeting = action.meeting {
                        MeetingJoinEngine.shared.joinMeeting(meeting)
                    } else if let url = action.meetingURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                success = true
            }

            DispatchQueue.main.async {
                ConfirmationBus.shared.pendingAction?.result = success ? "✓ Joining \(action.appName)" : "Failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    ConfirmationBus.shared.dismiss()
                }
            }
        }
    }
}

// MARK: - ConfirmationView

struct ConfirmationView: View {
    @State private var bus = ConfirmationBus.shared
    @State private var editedText: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        if let action = bus.pendingAction {
            content(action: action)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private func content(action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: action.actionType == .openMeeting ? "video.fill" : "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(action.actionType == .openMeeting ? Color(hex: "5DBB7A") : Color(hex: "B8881C"))
                Text(action.actionType == .openMeeting ? "MEETING STARTING SOON" : "HOLMES WANTS TO ACT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
                    .tracking(2)
                Spacer()
                Button(action: { bus.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "3D5A6A"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(hex: "0D1318"))

            Divider().background(Color(hex: "1E2D38"))

            VStack(alignment: .leading, spacing: 12) {
                // What Holmes wants to do
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "E8D5A3"))

                    HStack(spacing: 6) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "5A7A8A"))
                        Text(action.appName)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(hex: "5A7A8A"))
                    }
                }

                // Editable preview of what will be typed/done
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PREVIEW")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "3D5A6A"))
                            .tracking(2)
                        Spacer()
                        Button(action: { isEditing.toggle() }) {
                            Text(isEditing ? "DONE" : "EDIT")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "B8881C"))
                        }
                        .buttonStyle(.plain)
                    }

                    if isEditing {
                        TextEditor(text: $editedText)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(hex: "BDD0D8"))
                            .scrollContentBackground(.hidden)
                            .background(Color(hex: "0A0F14"))
                            .frame(minHeight: 60, maxHeight: 120)
                            .padding(8)
                            .background(Color(hex: "0A0F14"))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "B8881C").opacity(0.5), lineWidth: 1))
                    } else {
                        Text(editedText.isEmpty ? action.preview : editedText)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(hex: "BDD0D8"))
                            .lineSpacing(3)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "0A0F14"))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "1E2D38"), lineWidth: 1))
                    }
                }

                // Result / executing / buttons
                if let result = action.result {
                    HStack(spacing: 6) {
                        Image(systemName: result.hasPrefix("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.hasPrefix("✓") ? Color(hex: "5DBB7A") : Color(hex: "E05252"))
                        Text(result)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(result.hasPrefix("✓") ? Color(hex: "5DBB7A") : Color(hex: "E05252"))
                    }
                } else if action.isExecuting {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6).tint(Color(hex: "B8881C"))
                        Text("Sending...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "5A7A8A"))
                    }
                } else {
                    HStack(spacing: 8) {
                        Button(action: {
                            if action.actionType != .openMeeting,
                               !editedText.isEmpty, editedText != action.preview {
                                bus.pendingAction = PendingAction(
                                    title: action.title,
                                    preview: editedText,
                                    appName: action.appName,
                                    actionType: action.actionType
                                )
                            }
                            bus.execute()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: action.actionType == .openMeeting ? "video.fill" : "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text(action.actionType == .openMeeting ? "Join Now" : "Send it")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(Color(hex: "0A0F14"))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(action.actionType == .openMeeting ? Color(hex: "4A9EDB") : Color(hex: "5DBB7A"))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Button(action: { bus.dismiss() }) {
                            Text(action.actionType == .openMeeting ? "Skip" : "Dismiss")
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(hex: "5A7A8A"))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(hex: "0D1318"))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "1E2D38"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(hex: "111820"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "B8881C").opacity(0.3), lineWidth: 1))
        .shadow(color: Color(hex: "B8881C").opacity(0.15), radius: 20, x: 0, y: 4)
        .onAppear {
            editedText = action.preview
        }
    }
}
