import SwiftUI
import Observation

// MARK: - Pending Action
// Represents something Holmes wants to do — shown for user approval before executing.

struct PendingAction: Identifiable {
    let id = UUID()
    let title: String           // e.g. "Reply to Imda on Discord"
    var preview: String         // The text/action Holmes will perform
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
        case agentToolCall  // A tool the local model's action loop wants to run (approval-gated)

        var primaryButtonTitle: String {
            switch self {
            case .openMeeting:   return "Join Now"
            case .agentToolCall: return "Approve"
            case .typeMessage:   return "Insert"
            case .openURL:       return "Open Link"
            case .runScript:     return "Approve"
            }
        }
    }
}

// AgentDecision and the approval FIFO live in Core/ApprovalQueue.swift.

// MARK: - ConfirmationBus
// HolmesAgent posts here when it detects something actionable.
// ConfirmationWindow observes and shows the overlay.

@MainActor
@Observable
final class ConfirmationBus {
    static let shared = ConfirmationBus()
    private init() {
        approvals.onPresent = { [weak self] action in
            guard let self else { return }
            if let action {
                self.propose(action)
            } else {
                self.closeApprovalCard()
            }
        }
        approvals.onTimeout = { action in
            print("[Holmes] Approval timed out: \(action.title)")
        }
    }

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

    // Agent tool calls awaiting the user's decision, one card at a time (see `decide`).
    @ObservationIgnored private let approvals = ApprovalQueue<PendingAction>()

    /// True when the showing card is the approval at the head of the queue.
    private var showingQueuedApproval: Bool {
        guard let current = approvals.currentID else { return false }
        return pendingAction?.id == current
    }

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
    func proposeDraft(_ draft: ProactiveDraft, prioritize: Bool = false) {
        if pendingDraft?.id == draft.id {
            ConfirmationWindowController.shared.show()
            return
        }
        draftQueue.removeAll { $0.id == draft.id }
        if prioritize, pendingAction == nil {
            if let previous = pendingDraft { draftQueue.insert(previous, at: 0) }
            pendingDraft = nil
            isShowingReply = false
        }
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
    ///
    /// Overlapping requests QUEUE (FIFO): a second card waits until the first is
    /// answered, so one run can never read another run's arrival as "declined".
    /// Cancelling the awaiting task removes its card whether it is showing or
    /// still queued. `timeout` (or the task's ApprovalScope.unattendedTimeout,
    /// set by autonomous playbook runs) resolves `.timedOut` when nobody answers.
    func decide(_ action: PendingAction, timeout: TimeInterval? = nil) async -> AgentDecision {
        await approvals.decide(id: action.id, item: action,
                               timeout: timeout ?? ApprovalScope.unattendedTimeout)
    }

    /// Hides the approval card once the queue is empty, then lets a queued
    /// playbook draft take the panel.
    private func closeApprovalCard() {
        isShowingReply = false
        pendingAction = nil
        if pendingDraft == nil {
            isShowing = false
            ConfirmationWindowController.shared.hide()
        }
        showNextDraftSoon()
    }

    /// Closes the showing card. For drafts this only CLOSES the popup by
    /// default — the draft stays in PlaybookEngine.drafts (and the MainPanel
    /// Drafts section) for later review, which is that list's whole purpose.
    /// Pass `removeDraft: true` only where removal is what the user expects:
    /// the post-action completion (Copy/Insert/Open succeeded).
    func dismiss(removeDraft: Bool = false) {
        if showingQueuedApproval {
            // The queue presents the next waiting approval, or closes the card.
            approvals.resolveCurrent(.dismissed)
            return
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
        if showingQueuedApproval {
            let text = pendingAction?.preview ?? ""
            approvals.resolveCurrent(.approved(text: text))
            return
        }

        guard var action = pendingAction else { return }
        action.isExecuting = true
        pendingAction = action

        // On the main actor: the text entry itself is nonisolated async (off
        // main), and any AppleScript it needs runs back on the main actor.
        Task { @MainActor in
            var success = false
            var verified = true
            switch action.actionType {
            case .typeMessage:
                let entry = await ActionExecutor.shared.sendMessageInApp(action.appName, message: action.preview)
                success = entry.succeeded
                verified = entry.isVerified
            case .openURL:
                if let url = URL(string: action.preview) {
                    NSWorkspace.shared.open(url)
                    success = true
                }
            case .runScript:
                success = false
            case .agentToolCall:
                // Handled via decisionHandler above; unreachable here.
                success = false
            case .openMeeting:
                if let meeting = action.meeting {
                    MeetingJoinEngine.shared.joinMeeting(meeting)
                } else if let url = action.meetingURL {
                    NSWorkspace.shared.open(url)
                }
                success = true
            }

            do {
                guard ConfirmationBus.shared.pendingAction?.id == action.id else { return }
                let completed: String
                switch action.actionType {
                case .typeMessage:
                    completed = verified ? "✓ Inserted in \(action.appName)"
                                         : "Sent to \(action.appName), but couldn't confirm it landed. Check the field."
                case .openMeeting: completed = "✓ Opening meeting"
                case .openURL: completed = "✓ Opened link"
                default: completed = "✓ Completed"
                }
                ConfirmationBus.shared.pendingAction?.result = success ? completed : "Couldn’t complete this action"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard ConfirmationBus.shared.pendingAction?.id == action.id else { return }
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
    @State private var draftDidSucceed = false
    @State private var draftInsertionTask: Task<Void, Never>?

    var body: some View {
        Group {
            if bus.isShowingReply,
               let reply = agent.pendingReplyDraft,
               let incoming = agent.pendingReplyTo {
                ReplyReadyCard(
                    draft: reply, incoming: incoming,
                    onEdit: { agent.notePendingReplyEdit($0) },
                    onDismiss: { bus.hideReplyCard() })
            } else if let draft = bus.pendingDraft {
                draftContent(draft: draft)
            } else if let action = bus.pendingAction {
                content(action: action)
            } else {
                Color.clear
            }
        }
        .font(NoirFonts.body())
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func reviewHeader(_ title: String, icon: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NoirColors.iconPrimary)
                .frame(width: 28, height: 28)
                .background(NoirColors.glassElevated, in: Circle())
            Text(title)
                .font(NoirFonts.font(size: 11, weight: .semibold))
                .foregroundStyle(NoirColors.textSecondary)
                .tracking(1.2)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoirColors.iconSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss review")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(NoirColors.glassChrome)
    }

    private func content(action: PendingAction) -> some View {
        GlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 0) {
                reviewHeader(action.actionType == .openMeeting ? "MEETING READY" : "REVIEW ACTION",
                             icon: action.actionType == .openMeeting ? "video" : "checkmark.shield") {
                    bus.dismiss()
                }
                Divider().overlay(NoirColors.glassDivider)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(action.title)
                            .font(NoirFonts.brand(size: 24))
                            .foregroundStyle(NoirColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(action.appName, systemImage: "app")
                            .font(NoirFonts.caption())
                            .foregroundStyle(NoirColors.textSecondary)
                    }
                    previewSection(action: action)
                    footer(action: action)
                }
                .padding(16)
            }
        }
        .onAppear { syncAction(action) }
        .onChange(of: action.id) { _, _ in syncAction(action) }
        .onChange(of: action.preview) { _, newValue in editedText = newValue }
    }

    private func syncAction(_ action: PendingAction) {
        editedText = action.preview
        isEditing = false
    }

    private func previewSection(action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("PREVIEW")
                Spacer()
                if action.actionType != .openMeeting && !action.isExecuting && action.result == nil {
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                        .font(NoirFonts.caption())
                        .buttonStyle(.plain)
                        .foregroundStyle(NoirColors.accent)
                }
            }
            Group {
                if isEditing {
                    TextEditor(text: $editedText)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Action preview")
                } else {
                    ScrollView {
                        Text(editedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(NoirFonts.body())
            .foregroundStyle(NoirColors.textPrimary)
            .lineSpacing(4)
            .frame(height: 140)
            .padding(12)
            .background(NoirColors.glassInput, in: RoundedRectangle(cornerRadius: 10))
            .glassBorder(cornerRadius: 10)
        }
    }

    @ViewBuilder private func footer(action: PendingAction) -> some View {
        if let result = action.result {
            resultLabel(result)
        } else if action.isExecuting {
            progressLabel(action.actionType == .typeMessage ? "Inserting…" : "Working…")
        } else {
            HStack(spacing: 8) {
                NoirButton(action.actionType.primaryButtonTitle,
                           icon: action.actionType == .openMeeting ? "video" : "checkmark") {
                    guard bus.pendingAction?.id == action.id else { return }
                    if action.actionType != .openMeeting {
                        bus.pendingAction?.preview = editedText
                    }
                    bus.execute()
                }
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                NoirButton(action.actionType == .openMeeting ? "Skip" : "Dismiss", style: .secondary) {
                    bus.dismiss()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(NoirFonts.font(size: 10, weight: .semibold))
            .foregroundStyle(NoirColors.textSecondary)
            .tracking(1.2)
    }

    private func resultLabel(_ result: String) -> some View {
        Label(result, systemImage: result.hasPrefix("✓") ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(NoirFonts.caption())
            .foregroundStyle(result.hasPrefix("✓") ? NoirColors.success : NoirColors.error)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressLabel(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).font(NoirFonts.caption()).foregroundStyle(NoirColors.textSecondary)
        }
        .frame(height: 36)
    }

    // MARK: - Draft review

    private func draftContent(draft: ProactiveDraft) -> some View {
        GlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 0) {
                reviewHeader("REVIEW DRAFT", icon: "square.and.pencil") { bus.dismiss() }
                Divider().overlay(NoirColors.glassDivider)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel(kindLabel(draft.kind))
                        Text(draft.title)
                            .font(NoirFonts.brand(size: 24))
                            .foregroundStyle(NoirColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(draft.contextSummary)
                            .font(NoirFonts.caption())
                            .foregroundStyle(NoirColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let stagedNote = draft.stagedNote {
                            Label(stagedNote, systemImage: "envelope.badge.person.crop")
                                .font(NoirFonts.caption())
                                .foregroundStyle(NoirColors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("DRAFT · EDITABLE")
                        TextEditor(text: $draftBody)
                            .font(NoirFonts.body())
                            .foregroundStyle(NoirColors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .lineSpacing(4)
                            .frame(height: 170)
                            .padding(10)
                            .background(NoirColors.glassInput, in: RoundedRectangle(cornerRadius: 10))
                            .glassBorder(cornerRadius: 10)
                            .accessibilityLabel("Draft text")
                    }
                    draftFooter(draft: draft)
                }
                .padding(16)
            }
        }
        .onAppear { syncDraftState(draft) }
        .onChange(of: draft.id) { _, _ in syncDraftState(draft) }
        .onChange(of: draftBody) { _, body in bus.updatePendingDraftBody(body) }
        .onDisappear { draftInsertionTask?.cancel() }
    }

    private func syncDraftState(_ draft: ProactiveDraft) {
        draftInsertionTask?.cancel()
        draftInsertionTask = nil
        draftBody = draft.body
        draftResult = nil
        draftIsExecuting = false
        draftDidSucceed = false
    }

    @ViewBuilder private func draftFooter(draft: ProactiveDraft) -> some View {
        if let result = draftResult { resultLabel(result) }
        if draftIsExecuting {
            progressLabel("Inserting…")
        } else if !draftDidSucceed {
            HStack(spacing: 8) {
                draftPrimaryControl(draft: draft)
                if case .clipboard = draft.target { } else {
                    NoirButton("Copy", style: .secondary) { copyDraft(draft) }
                }
                NoirButton("Dismiss", style: .ghost) { bus.dismiss() }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func draftPrimaryControl(draft: ProactiveDraft) -> some View {
        switch draft.target {
        case .emailCompose(let expected):
            NoirButton(expected.bodyIsEmpty ? "Insert draft" : "Replace body", icon: "text.insert") {
                insertEmailDraft(draft, expected: expected)
            }
            .disabled(draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .typeIntoApp(let appName):
            NoirButton("Insert", icon: "text.insert") { insertDraft(draft, appName: appName) }
                .disabled(draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .remoteDraft(let urlString):
            if let urlString, let url = URL(string: urlString) {
                NoirButton("Open Draft", icon: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(url)
                    finishDraft(draft, result: "✓ Opened draft")
                }
            } else {
                Label("Saved in Gmail Drafts", systemImage: "checkmark.circle.fill")
                    .font(NoirFonts.caption())
                    .foregroundStyle(NoirColors.success)
            }
        case .clipboard:
            NoirButton("Copy", icon: "doc.on.doc") {
                copyDraft(draft)
            }
        }
    }

    // MARK: Draft actions

    /// Stages the EDITED draft body into the target app at the current cursor —
    /// no select-all (a draft can be inserted long after its context, and Cmd+A
    /// could wipe whatever now has focus, e.g. a document in the same browser).
    /// Never presses Send/Return.
    private func insertDraft(_ draft: ProactiveDraft, appName: String) {
        draftIsExecuting = true
        let text = draftBody
        Task { @MainActor in
            let entry = await ActionExecutor.shared.stageTextInApp(appName, text: text)
            // The card may have moved on (dismissed, next draft shown) while
            // staging ran — never write result state onto a different card.
            guard bus.pendingDraft?.id == draft.id else { return }
            draftIsExecuting = false
            switch entry {
            case .verified:
                finishDraft(draft, result: "✓ Staged in \(appName) — you press Send")
            case .unverified:
                finishDraft(draft, result: "Staged in \(appName), but couldn't confirm it landed. Check before you send.")
            case .failed:
                draftResult = "Failed to insert into \(appName)"
            }
        }
    }

    private func insertEmailDraft(_ draft: ProactiveDraft, expected: EmailComposeSnapshot) {
        guard !draftIsExecuting else { return }
        draftIsExecuting = true
        draftResult = nil
        let text = draftBody
        let activity = WorkActivityCenter.shared.begin(title: "Inserting email draft", detail: "Checking the original email")
        let work = Task { @MainActor in
            await WorkActivityScope.$id.withValue(activity) {
                do {
                    try Task.checkCancellation()
                    WorkActivityCenter.shared.update(activity, phase: .working)
                    let inserted = try await EmailDraftCoordinator.shared.insert(text, expected: expected)
                    try Task.checkCancellation()
                    guard WorkActivityCenter.shared.isActive(activity) else { throw CancellationError() }
                    guard inserted else { throw EmailComposeError.unavailable("Couldn't verify the inserted email. Check Gmail before retrying.") }
                    WorkActivityCenter.shared.finish(activity, outcome: .success, summary: "Email body inserted for your review")
                    guard bus.pendingDraft?.id == draft.id else { return }
                    draftIsExecuting = false
                    finishDraft(draft, result: "✓ Inserted in your email — ready for your review")
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    let message = cancelled ? "Insertion stopped. Check the email body before retrying." : error.localizedDescription
                    if cancelled { WorkActivityCenter.shared.cancel(activity, summary: message) }
                    else { WorkActivityCenter.shared.finish(activity, outcome: .failure, summary: message) }
                    guard bus.pendingDraft?.id == draft.id else { return }
                    draftIsExecuting = false
                    draftResult = message
                }
            }
        }
        draftInsertionTask = work
        WorkActivityCenter.shared.setCancellationHandler(activity) { work.cancel() }
    }

    private func copyDraft(_ draft: ProactiveDraft) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(draftBody, forType: .string) {
            finishDraft(draft, result: "✓ Copied to clipboard")
        } else {
            draftResult = "Couldn't copy the draft. Try again."
        }
    }

    /// Shows a brief result line, then closes the card. The draft was acted on
    /// (copied/inserted/opened), so this is the one path that also removes it
    /// from PlaybookEngine's list — a plain X/Dismiss keeps it for later.
    private func finishDraft(_ draft: ProactiveDraft, result: String) {
        draftResult = result
        draftDidSucceed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            // Only auto-dismiss if this draft is still the one on screen.
            if bus.pendingDraft?.id == draft.id { bus.dismiss(removeDraft: true) }
        }
    }

    private func kindLabel(_ kind: DraftKind) -> String {
        switch kind {
        case .emailCompose:     return "EMAIL DRAFT"
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
