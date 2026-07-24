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
        case agentToolCall  // A tool the Claude action loop wants to run (approval-gated)

        var primaryButtonTitle: String {
            switch self {
            case .openMeeting:   return "Join Now"
            case .agentToolCall: return "Approve"
            default:             return "Send it"
            }
        }
    }
}

// Result of a user approving/dismissing an agent tool call.
enum AgentDecision {
    case approved(text: String)   // `text` carries any edits the user made in the preview
    case dismissed
}

// MARK: - ConfirmationBus
// HolmesAgent posts here when it detects something actionable.
// ConfirmationWindow observes and shows the overlay.

@MainActor
@Observable
final class ConfirmationBus {
    static let shared = ConfirmationBus()
    private init() {}

    var pendingAction: PendingAction? = nil
    var isShowing: Bool = false

    // Proactive playbook drafts (draft-never-send). A draft never preempts a live
    // approval card — it queues behind whatever is currently showing.
    var pendingDraft: ProactiveDraft? = nil
    @ObservationIgnored private var draftQueue: [ProactiveDraft] = []

    /// True while the floating card is showing the reply Holmes drafted by
    /// itself (see HolmesAgent's "Pending reply" section).
    ///
    /// A FLAG, not a copy. The draft, the message it answers and the user's
    /// edits all live on HolmesAgent, which is the only writer — two copies of a
    /// draft are two things that can disagree about what the user typed, and the
    /// panel card and this card must always show the same words.
    var isShowingReply: Bool = false

    // Set while an agent tool call awaits the user's decision (see `decide`).
    @ObservationIgnored private var decisionHandler: ((AgentDecision) -> Void)?

    func propose(_ action: PendingAction) {
        // A live approval outranks a proactive draft — push the draft back in line.
        if let draft = pendingDraft {
            draftQueue.insert(draft, at: 0)
            pendingDraft = nil
        }
        // …and it outranks the auto-drafted reply, which needs no queue: the
        // reply itself is untouched on HolmesAgent and still sits at the top of
        // the MainPanel stack. Only this popup gives way.
        isShowingReply = false
        pendingAction = action
        isShowing = true
        ConfirmationWindowController.shared.show()
    }

    /// Surfaces a playbook draft for review. Queues if something is already showing.
    /// De-duped by id: re-proposing the draft that's already on screen just brings
    /// the window forward, and a draft can sit in the queue at most once — so
    /// clicking a DraftRow repeatedly can't enqueue ghost copies.
    func proposeDraft(_ draft: ProactiveDraft) {
        if pendingDraft?.id == draft.id {
            ConfirmationWindowController.shared.show()
            return
        }
        draftQueue.removeAll { $0.id == draft.id }
        // A speculative playbook draft never displaces an answer to a person who
        // is actually waiting on the user — it queues behind the reply card too.
        guard pendingAction == nil, pendingDraft == nil, !isShowingReply else {
            draftQueue.append(draft)
            return
        }
        pendingDraft = draft
        isShowing = true
        ConfirmationWindowController.shared.show()
    }

    // MARK: - Auto-drafted reply

    /// Surfaces the reply Holmes wrote unprompted, in the same floating card the
    /// playbook drafts use.
    ///
    /// Precedence, and the reasoning for it:
    ///   • It OUTRANKS a proactive playbook draft — a real person asked the user
    ///     a real question, so a showing draft is pushed back into its queue
    ///     (never dropped) and returns afterwards.
    ///   • It never preempts a live approval card, which is a decision the user
    ///     is in the middle of making.
    ///   • It is not queued behind one either. A queue marker here could outlive
    ///     the draft it refers to (HolmesAgent owns that, and can replace or
    ///     clear it at any moment), and the MainPanel card is already the
    ///     always-there surface — so a deferred reply loses nothing but a popup.
    ///
    /// - Returns: false when a live approval kept the card off screen.
    @discardableResult
    func showReplyCard() -> Bool {
        guard pendingAction == nil else { return false }
        if let draft = pendingDraft {
            draftQueue.insert(draft, at: 0)
            pendingDraft = nil
        }
        isShowingReply = true
        isShowing = true
        ConfirmationWindowController.shared.show()
        return true
    }

    /// Closes the reply card WITHOUT discarding the reply — it stays on
    /// HolmesAgent and on the MainPanel card, exactly like a dismissed playbook
    /// draft stays in PlaybookEngine.drafts. Discarding it outright is
    /// HolmesAgent.clearPendingReply(), which calls this on its way through.
    func hideReplyCard() {
        guard isShowingReply else { return }
        isShowingReply = false
        guard pendingAction == nil, pendingDraft == nil else { return }
        isShowing = false
        ConfirmationWindowController.shared.hide()
        showNextDraftSoon()
    }

    /// Writes the review card's live edits back into the pending draft, so a
    /// preempting approval card (which re-queues the draft) can't discard them.
    func updatePendingDraftBody(_ body: String) {
        guard var draft = pendingDraft, draft.body != body else { return }
        draft.body = body
        pendingDraft = draft
    }

    /// Removes a draft from the queue only (leaves a showing card alone). Called
    /// when PlaybookEngine's 20-draft cap evicts a draft.
    func removeQueuedDraft(id: UUID) {
        draftQueue.removeAll { $0.id == id }
    }

    /// Drops every queued draft and closes a showing draft card. Called by
    /// PlaybookEngine.clearDrafts() so "Clear all drafts" can't leave ghost cards.
    /// Leaves approval cards untouched.
    func clearAllDrafts() {
        draftQueue.removeAll()
        if pendingDraft != nil {
            pendingDraft = nil
            if pendingAction == nil {
                isShowing = false
                ConfirmationWindowController.shared.hide()
            }
        }
    }

    /// Proposes an action and suspends until the user approves or dismisses it.
    /// Used by the agentic loop to gate side-effecting tool calls.
    func decide(_ action: PendingAction) async -> AgentDecision {
        // If a decision is already pending (two confirmations overlapped — e.g. a
        // calendar task raising a card while another autonomous step is still
        // awaiting one), resolve the OLD handler as .dismissed FIRST. Otherwise the
        // earlier continuation is orphaned and its await never resumes — the run
        // that was waiting on it hangs forever and looks like "approve failed".
        if let stale = decisionHandler {
            decisionHandler = nil
            stale(.dismissed)
        }
        return await withCheckedContinuation { cont in
            decisionHandler = { cont.resume(returning: $0) }
            propose(action)
        }
    }

    /// Closes the showing card. For drafts this only CLOSES the popup by
    /// default — the draft stays in PlaybookEngine.drafts (and the MainPanel
    /// Drafts section) for later review, which is that list's whole purpose.
    /// Pass `removeDraft: true` only where removal is what the user expects:
    /// the post-action completion (Copy/Insert/Open succeeded).
    func dismiss(removeDraft: Bool = false) {
        if let handler = decisionHandler {
            decisionHandler = nil
            handler(.dismissed)
        }
        if let draft = pendingDraft {
            if removeDraft {
                let draftId = draft.id
                Task { @MainActor in PlaybookEngine.shared.dismiss(draftId) }
            }
            pendingDraft = nil
        }
        // The reply survives its card being closed (see hideReplyCard) — only
        // the popup state is cleared here.
        isShowingReply = false
        isShowing = false
        pendingAction = nil
        ConfirmationWindowController.shared.hide()
        showNextDraftSoon()
    }

    /// Surfaces the next queued draft once the panel is idle again (after the
    /// hide animation has had time to finish).
    private func showNextDraftSoon() {
        guard !draftQueue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.pendingAction == nil, self.pendingDraft == nil,
                  !self.isShowingReply,
                  !self.draftQueue.isEmpty
            else { return }
            self.pendingDraft = self.draftQueue.removeFirst()
            self.isShowing = true
            ConfirmationWindowController.shared.show()
        }
    }

    func execute() {
        // Agent-loop path: hand the (possibly edited) text back to the awaiting loop
        // and let it perform the real call. Do NOT run ActionExecutor here.
        if let handler = decisionHandler {
            decisionHandler = nil
            let text = pendingAction?.preview ?? ""
            isShowing = false
            pendingAction = nil
            ConfirmationWindowController.shared.hide()
            handler(.approved(text: text))
            showNextDraftSoon()
            return
        }

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
            case .agentToolCall:
                // Handled via decisionHandler above; unreachable here.
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
    /// The reply card reads its draft straight off the agent — the bus only
    /// says WHETHER to show it (see ConfirmationBus.isShowingReply).
    @State private var agent = HolmesAgent.shared
    @State private var editedText: String = ""
    @State private var isEditing: Bool = false

    // Draft review card state.
    @State private var draftBody: String = ""
    @State private var draftResult: String? = nil
    @State private var draftIsExecuting: Bool = false

    var body: some View {
        // The auto-drafted reply first: propose() clears the flag, so this can
        // only win when nothing more urgent is on screen — and when it does win,
        // an answer to a waiting person outranks a speculative draft.
        if bus.isShowingReply,
           let reply = agent.pendingReplyDraft,
           let incoming = agent.pendingReplyTo {
            replyContent(draft: reply, incoming: incoming)
        } else if let draft = bus.pendingDraft {
            draftContent(draft: draft)
        } else if let action = bus.pendingAction {
            content(action: action)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    // MARK: - Auto-drafted reply card
    //
    // ReplyReadyCard brings its own glass background, border and shadow, so it
    // is hosted bare. Its Insert button goes through ActionExecutor.stageTextInApp
    // — types at the cursor and stops. Nothing here sends.

    @ViewBuilder private func replyContent(draft: ReplyComposer.DraftedReply,
                                           incoming: ReplyComposer.IncomingMessage) -> some View {
        ReplyReadyCard(
            draft: draft,
            incoming: incoming,
            // Edits go back to the one owner, so the MainPanel card shows the
            // user's wording rather than the model's.
            onEdit: { agent.notePendingReplyEdit($0) },
            // Closes the popup only — the reply stays in the panel, the same way
            // a dismissed playbook draft stays in the Drafts list.
            onDismiss: { bus.hideReplyCard() })
    }

    // Decomposed into sub-builders so the SwiftUI type-checker doesn't time out.
    @ViewBuilder private func content(action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(action: action)
            Divider().background(Color(hex: "1E2D38"))
            VStack(alignment: .leading, spacing: 12) {
                titleSection(action: action)
                previewSection(action: action)
                footer(action: action)
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

    @ViewBuilder private func header(action: PendingAction) -> some View {
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
    }

    @ViewBuilder private func titleSection(action: PendingAction) -> some View {
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
    }

    @ViewBuilder private func previewSection(action: PendingAction) -> some View {
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
    }

    @ViewBuilder private func footer(action: PendingAction) -> some View {
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
                        Text(action.actionType.primaryButtonTitle)
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

    // MARK: - Draft review card (proactive playbooks — draft-never-send)

    @ViewBuilder private func draftContent(draft: ProactiveDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            draftHeader(draft: draft)
            Divider().background(Color(hex: "1E2D38"))
            VStack(alignment: .leading, spacing: 12) {
                draftTitleSection(draft: draft)
                draftBodySection(draft: draft)
                draftFooter(draft: draft)
            }
            .padding(16)
        }
        // Apple-glass backdrop matching the Holmes panel / login windows, instead
        // of a flat opaque fill.
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: "111820").opacity(0.55)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "B8881C").opacity(0.3), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 6)
        .onAppear { syncDraftState(draft) }
        .onChange(of: draft.id) { syncDraftState(draft) }
        // Persist edits into the bus's copy so a preempting approval card
        // (propose() re-queues pendingDraft) carries them when the draft returns.
        .onChange(of: draftBody) { bus.updatePendingDraftBody(draftBody) }
    }

    private func syncDraftState(_ draft: ProactiveDraft) {
        draftBody = draft.body
        draftResult = nil
        draftIsExecuting = false
    }

    @ViewBuilder private func draftHeader(draft: ProactiveDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "B8881C"))
            Text("HOLMES DRAFTED — REVIEW")
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
        .background(Color(hex: "0D1318").opacity(0.4))
    }

    @ViewBuilder private func draftTitleSection(draft: ProactiveDraft) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(kindLabel(draft.kind))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(Color(hex: "0A0F14"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(hex: "B8881C"))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(draft.title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "E8D5A3"))
                    .lineLimit(1)
            }
            Text(draft.contextSummary)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "5A7A8A"))
                .lineLimit(2)
            // Ground truth about the staged Gmail draft (recipient/subject from
            // the actual tool call, never model prose) — the user must see where
            // an unattended draft is addressed before opening Gmail.
            if let stagedNote = draft.stagedNote {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "envelope.badge.person.crop")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "B8881C"))
                    Text(stagedNote)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "E8D5A3"))
                        .lineLimit(3)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func draftBodySection(draft: ProactiveDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DRAFT — EDITABLE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "3D5A6A"))
                .tracking(2)

            // Taller editable body so long drafts are readable without clipping;
            // TextEditor scrolls internally past the max height, and the draft
            // window (see ConfirmationWindowController) is sized to keep the
            // Copy/Insert/Dismiss row visible below it.
            TextEditor(text: $draftBody)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "BDD0D8"))
                .scrollContentBackground(.hidden)
                .background(Color(hex: "0A0F14"))
                .frame(minHeight: 120, maxHeight: 200)
                .padding(8)
                .background(Color(hex: "0A0F14"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "B8881C").opacity(0.5), lineWidth: 1))
        }
    }

    @ViewBuilder private func draftFooter(draft: ProactiveDraft) -> some View {
        if let result = draftResult {
            HStack(spacing: 6) {
                Image(systemName: result.hasPrefix("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result.hasPrefix("✓") ? Color(hex: "5DBB7A") : Color(hex: "E05252"))
                Text(result)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(result.hasPrefix("✓") ? Color(hex: "5DBB7A") : Color(hex: "E05252"))
            }
        } else if draftIsExecuting {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).tint(Color(hex: "B8881C"))
                Text("Staging...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "5A7A8A"))
            }
        } else {
            HStack(spacing: 8) {
                draftPrimaryControl(draft: draft)
                draftSecondaryCopyButton(draft: draft)
                Button(action: { bus.dismiss() }) {
                    Text("Dismiss")
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

    @ViewBuilder private func draftPrimaryControl(draft: ProactiveDraft) -> some View {
        switch draft.target {
        case .typeIntoApp(let appName):
            draftPrimaryButton(title: "Insert", icon: "text.insert") {
                insertDraft(draft, appName: appName)
            }
        case .remoteDraft(let urlString):
            if let urlString, let url = URL(string: urlString) {
                draftPrimaryButton(title: "Open Draft", icon: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(url)
                    finishDraft(draft, result: "✓ Opened draft")
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "5DBB7A"))
                    Text("Saved in Gmail Drafts")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "5DBB7A"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        case .clipboard:
            draftPrimaryButton(title: "Copy", icon: "doc.on.doc") {
                copyDraftBody()
                finishDraft(draft, result: "✓ Copied to clipboard")
            }
        }
    }

    /// Secondary Copy — always offered unless the primary action is already Copy.
    @ViewBuilder private func draftSecondaryCopyButton(draft: ProactiveDraft) -> some View {
        switch draft.target {
        case .clipboard:
            EmptyView()
        default:
            Button(action: {
                copyDraftBody()
                finishDraft(draft, result: "✓ Copied to clipboard")
            }) {
                Text("Copy")
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

    @ViewBuilder private func draftPrimaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundColor(Color(hex: "0A0F14"))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(hex: "5DBB7A"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Draft actions

    /// Stages the EDITED draft body into the target app at the current cursor —
    /// no select-all (a draft can be inserted long after its context, and Cmd+A
    /// could wipe whatever now has focus, e.g. a document in the same browser).
    /// Never presses Send/Return.
    private func insertDraft(_ draft: ProactiveDraft, appName: String) {
        draftIsExecuting = true
        let text = draftBody
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = ActionExecutor.shared.stageTextInApp(appName, text: text)
            DispatchQueue.main.async {
                // The card may have moved on (dismissed, next draft shown) while
                // staging ran — never write result state onto a different card.
                guard bus.pendingDraft?.id == draft.id else { return }
                draftIsExecuting = false
                if ok {
                    finishDraft(draft, result: "✓ Staged in \(appName) — you press Send")
                } else {
                    draftResult = "Failed to insert into \(appName)"
                }
            }
        }
    }

    private func copyDraftBody() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(draftBody, forType: .string)
    }

    /// Shows a brief result line, then closes the card. The draft was acted on
    /// (copied/inserted/opened), so this is the one path that also removes it
    /// from PlaybookEngine's list — a plain X/Dismiss keeps it for later.
    private func finishDraft(_ draft: ProactiveDraft, result: String) {
        draftResult = result
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            // Only auto-dismiss if this draft is still the one on screen.
            if bus.pendingDraft?.id == draft.id { bus.dismiss(removeDraft: true) }
        }
    }

    private func kindLabel(_ kind: DraftKind) -> String {
        switch kind {
        case .emailReply:       return "EMAIL REPLY"
        case .promptSuggestion: return "PROMPT"
        case .repoBrief:        return "REPO BRIEF"
        case .linkedInPost:     return "LINKEDIN POST"
        case .meetingPrep:      return "MEETING PREP"
        case .chatReply:        return "CHAT REPLY"
        case .aiAnswer:         return "AI ANSWER"
        case .briefing:         return "YOUR DAY"
        case .triage:           return "INBOX TRIAGE"
        case .followUp:         return "FOLLOW-UPS"
        case .prRadar:          return "PR RADAR"
        case .scheduleAlert:    return "SCHEDULE ALERT"
        case .wrapup:           return "DAY WRAP-UP"
        }
    }
}
