import SwiftUI
import AppKit

// MARK: - ReplyReadyCard
// "Someone asked you something, and the answer is already written."
//
// This is the surface for the subject-triggered path: an inbound message named
// a SUBJECT ("hey what is holmes?"), Holmes recalled the SQL rows about that
// subject and drafted a grounded reply — all before the user opened anything.
// The card is what they see when they do.
//
// Three things are non-negotiable in this view:
//
//   1. DRAFT-NEVER-SEND. There is no button here that sends, posts or submits.
//      "Insert" goes through ActionExecutor.stageTextInApp, which activates the
//      app and pastes at the cursor — it never presses Return. The user commits
//      in their own app, on their own tap. If you are adding a control here and
//      reach for "…and send it", that belongs nowhere in Holmes.
//
//   2. The draft is EDITABLE before it is used. Everything downstream (Insert,
//      Copy, and the `onEdit` callback that writes back into the model) uses the
//      user's edited text, never the model's original.
//
//   3. Every memory row shows WHY it matched (see RecallReason). An unsourced
//      draft is rendered in the warning colour and says so out loud, because a
//      confident-looking ungrounded reply is the worst thing this feature could
//      produce.

@MainActor
struct ReplyReadyCard: View {
    /// The draft plus its receipts, exactly as ReplyComposer produced it.
    let draft: ReplyComposer.DraftedReply

    /// The message being answered — supplies the quote and the "to Alex ·
    /// iMessage" line, and names the app that Insert stages into.
    let incoming: ReplyComposer.IncomingMessage

    /// Override for the subjects Holmes extracted from `incoming.text`
    /// ("holmes"). Left empty the card uses `draft.topics`, which is what the
    /// drafter actually searched for — pass something here only when the caller
    /// knows better. Drives the per-row match explanations and the empty-recall
    /// copy.
    var topics: [String] = []

    /// Fires on every keystroke with the user's edited body, so the owning model
    /// keeps the edits if this card is torn down or re-shown (same contract as
    /// ConfirmationBus.updatePendingDraftBody).
    var onEdit: (String) -> Void = { _ in }

    /// Dismiss is the caller's decision — this view never closes a window itself.
    var onDismiss: () -> Void = {}

    @State private var editedBody: String = ""
    @State private var result: String? = nil
    @State private var isStaging: Bool = false

    /// What was actually searched for. The drafter's own list wins unless the
    /// caller overrode it.
    private var subjects: [String] {
        topics.isEmpty ? draft.topics : topics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(NoirColors.glassDivider)
            VStack(alignment: .leading, spacing: 11) {
                quotedMessage
                draftEditor
                GroundedInStrip(hits: draft.recallHits,
                                events: draft.groundedIn,
                                background: draft.background,
                                topics: subjects)
                footer
            }
            .padding(14)
        }
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                NoirColors.glassSurface
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassBorder(cornerRadius: 12)
        .shadow(color: NoirColors.panelShadow, radius: 24, x: 0, y: 6)
        .onAppear { syncBody() }
        // A new draft (different body) resets the card — including any stale
        // "staged" result from the previous one.
        .onChange(of: draft.body) { syncBody() }
        .onChange(of: editedBody) { onEdit(editedBody) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NoirColors.accent.opacity(0.8))

            Text("REPLY READY")
                .font(NoirFonts.font(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.textTertiary)
                .tracking(2)

            Spacer(minLength: 8)

            Text(recipientLabel)
                .font(NoirFonts.font(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(NoirColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NoirColors.glassChrome)
    }

    /// "to Alex · iMessage". Falls back to the channel alone when the surface
    /// couldn't name the sender — never to an invented name.
    private var recipientLabel: String {
        let who = incoming.sender.trimmingCharacters(in: .whitespaces)
        return who.isEmpty ? surfaceLabel : "to \(who) · \(surfaceLabel)"
    }

    private var surfaceLabel: String {
        let app = incoming.app.trimmingCharacters(in: .whitespaces)
        switch incoming.surface.lowercased() {
        case ReplyComposer.surfaceIMessage: return "iMessage"
        case ReplyComposer.surfaceEmail:    return app.isEmpty ? "email" : app
        case ReplyComposer.surfaceWebChat:  return app.isEmpty ? "chat" : app
        default:                            return app.isEmpty ? incoming.surface : app
        }
    }

    // MARK: Their message

    /// Dim and italic: it is the thing being answered, not the thing being sent.
    private var quotedMessage: some View {
        Text("\u{201C}\(incoming.text)\u{201D}")
            .font(NoirFonts.font(size: 11, weight: .regular, design: .default))
            .italic()
            .foregroundColor(NoirColors.textTertiary)
            .lineSpacing(2)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The draft

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("DRAFT — EDITABLE")
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .tracking(1.5)
                Spacer(minLength: 6)
                confidencePill
            }

            // TextEditor, not Text: the user edits before anything leaves this
            // card, and `editedBody` is the only string the buttons ever use.
            TextEditor(text: $editedBody)
                .font(NoirFonts.font(size: 12, weight: .regular, design: .default))
                .foregroundColor(NoirColors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .lineSpacing(2)
                .frame(minHeight: 74, maxHeight: 150)
                .padding(8)
                .background(NoirColors.glassInput)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NoirColors.glassBorder, lineWidth: 0.75)
                )
        }
    }

    /// How the CONTEXT behind the draft was read — the same scale the memory
    /// card uses. It sits on the draft, not on the recall, because it describes
    /// the reading that produced these words.
    private var confidencePill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(draft.confidence.replyDotColor)
                .frame(width: 5, height: 5)
            Text(draft.confidence.replyLabel)
                .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.textTertiary)
                .tracking(1)
        }
        .help(draft.confidence.replyHelp)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if let result {
            HStack(spacing: 6) {
                Image(systemName: result.hasPrefix("\u{2713}") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(result.hasPrefix("\u{2713}") ? NoirColors.success : NoirColors.error)
                Text(result)
                    .font(NoirFonts.font(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(result.hasPrefix("\u{2713}") ? NoirColors.success : NoirColors.error)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else if isStaging {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.55).tint(NoirColors.accent)
                Text("Staging in \(targetApp)...")
                    .font(NoirFonts.font(size: 10, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if !targetApp.isEmpty {
                        primaryButton(title: "Insert", icon: "text.insert", action: insert)
                    }
                    secondaryButton(title: "Copy", action: copyBody)
                    secondaryButton(title: "Dismiss", action: onDismiss)
                    Spacer(minLength: 0)
                }
                neverSendsNote
            }
        }
    }

    /// The promise, stated on the card itself rather than only in the code.
    private var neverSendsNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(NoirColors.textPlaceholder)
            Text(targetApp.isEmpty
                 ? "Holmes never sends. Copy it and send it yourself."
                 : "Holmes never sends — Insert types it into \(targetApp) and stops. You press Send.")
                .font(NoirFonts.font(size: 8, weight: .regular, design: .monospaced))
                .foregroundColor(NoirColors.textPlaceholder)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        NoirButton(title, icon: icon, action: action)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        NoirButton(title, style: .secondary, action: action)
    }

    // MARK: Actions

    /// The app Insert stages into. iMessage drafts fall back to "Messages"
    /// (ActionExecutor resolves that through the AX path, no Automation
    /// permission needed); an unknown app hides Insert rather than guessing at
    /// a window to paste into.
    private var targetApp: String {
        let app = incoming.app.trimmingCharacters(in: .whitespaces)
        if !app.isEmpty { return app }
        return incoming.surface.lowercased() == ReplyComposer.surfaceIMessage ? "Messages" : ""
    }

    private func syncBody() {
        editedBody = draft.body
        result = nil
        isStaging = false
    }

    /// Stages the EDITED text at the cursor in the target app. Types and stops —
    /// no Cmd+A, no Return. See ActionExecutor.stageTextInApp.
    private func insert() {
        let app = targetApp
        let text = editedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, !text.isEmpty else { return }
        isStaging = true
        Task {
            let ok = await Self.stage(text: text, into: app)
            isStaging = false
            result = ok
                ? "\u{2713} Staged in \(app) — you press Send"
                : "Couldn't reach \(app) — use Copy instead"
        }
    }

    /// ActionExecutor sleeps and waits on another process, so it must never run
    /// on the main thread. Only strings cross the boundary.
    nonisolated private static func stage(text: String, into app: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ActionExecutor.shared.stageTextInApp(app, text: text))
            }
        }
    }

    private func copyBody() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editedBody, forType: .string)
        result = "\u{2713} Copied — paste it wherever you like"
    }
}

// MARK: - GroundedInStrip
// The receipts under the draft: the exact SQL rows the reply was built from,
// each labelled with WHY it came back and how old it is.
//
// Collapsed it shows the two strongest rows and the count; expanded it shows up
// to eight. The point of the row-level `matchedOn` label is that a bad recall is
// catchable — if the memories under a draft about "holmes" are all about
// something else, the user can see that before a single word is sent.
//
// THE HEADLINE MUST NOT OVERSTATE THE ROWS. A subject was named and recall came
// back empty? Then the draft is UNSOURCED, no matter how many current-context
// rows the drafter had lying around — those rows go under their own "BACKGROUND"
// heading, never under the grounded count. This is the one place a user can
// catch an ungrounded answer without reading every row, so the count line is
// only ever allowed to describe rows that actually came from searching for what
// they asked about.

@MainActor
struct GroundedInStrip: View {
    /// The subject-recall receipts, exactly as MemoryStore.recall produced them.
    /// `matchedOn` is rendered verbatim — it is the query's own account of why
    /// the row came back, and re-wording it here would break the audit trail.
    var hits: [MemoryStore.RecallHit] = []

    /// The rows that ANSWER the message — DraftedReply.groundedIn. Recalled rows
    /// when a subject was named; the current-context rows when none was. This is
    /// the authoritative order and the authoritative count, which is why the
    /// strip iterates it rather than the hits.
    let events: [MemoryEvent]

    /// Rows the drafter used as colour rather than as evidence —
    /// DraftedReply.background. Rendered under their own heading and never
    /// counted in the grounded total.
    var background: [MemoryEvent] = []

    /// The subjects that were searched for. Used to derive a reason for rows
    /// that arrived without a hit, and to name the subject in the empty state.
    var topics: [String] = []

    @State private var isExpanded = false

    private static let collapsedRowCount = 2
    private static let expandedRowCount = 8
    /// Background is context, not evidence: two rows collapsed, four expanded.
    private static let collapsedBackgroundCount = 1
    private static let expandedBackgroundCount = 4

    /// row id → verbatim reason from the recall query, resolved once.
    private var suppliedReasons: [Int64: String] {
        var map: [Int64: String] = [:]
        for hit in hits {
            let reason = hit.matchedOn.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { map[hit.event.id] = reason }
        }
        return map
    }

    /// IS THE DRAFT ACTUALLY SOURCED? Two ways for it not to be, and they are
    /// different failures:
    ///   • no rows at all — nothing was found anywhere, and
    ///   • a SUBJECT was named and the recall for it came back empty. The
    ///     drafter still had current-context rows to hand (findSimilar widens to
    ///     six precisely when recall finds nothing), and showing those under
    ///     "GROUNDED IN 6 MEMORIES" would dress an ungrounded answer in six
    ///     receipts about something else entirely.
    private var isGrounded: Bool {
        guard !events.isEmpty else { return false }
        return topics.isEmpty || !hits.isEmpty
    }

    /// Rows to draw with each explanation attached. The query's own reason wins;
    /// the spotlight's is next (same recall, different entry point); otherwise it
    /// is re-derived from the row's columns. Nothing is invented — a row nothing
    /// can explain is labelled `RecallReason.unverified`.
    private func explained(_ list: [MemoryEvent], limit: Int) -> [(event: MemoryEvent, matchedOn: String)] {
        let supplied = suppliedReasons
        let spotlit = RecallSpotlight.shared.reasons
        return list.prefix(limit).map { event in
            if let reason = supplied[event.id] { return (event, reason) }
            if let reason = spotlit[event.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                return (event, reason)
            }
            return (event, RecallReason.derive(event: event, topics: topics))
        }
    }

    private var visibleRows: [(event: MemoryEvent, matchedOn: String)] {
        explained(events, limit: isExpanded ? Self.expandedRowCount : Self.collapsedRowCount)
    }

    /// Everything that is NOT evidence about the subject. When the recall came
    /// back empty the grounding rows are background too — none of them came from
    /// searching for what was asked.
    private var backgroundEvents: [MemoryEvent] {
        isGrounded ? background : events + background
    }

    private var visibleBackgroundRows: [(event: MemoryEvent, matchedOn: String)] {
        explained(backgroundEvents,
                  limit: isExpanded ? Self.expandedBackgroundCount : Self.collapsedBackgroundCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isGrounded {
                headerRow
                rows(visibleRows)
                if isExpanded, events.count > Self.expandedRowCount {
                    Text("+ \(events.count - Self.expandedRowCount) more in memory")
                        .font(NoirFonts.font(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(NoirColors.textPlaceholder)
                        .padding(.leading, 12)
                }
            } else {
                unsourcedWarning
            }
            if !backgroundEvents.isEmpty {
                backgroundHeading
                rows(visibleBackgroundRows)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Text("\u{25C8}")
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.accent.opacity(0.7))
                Text(countLabel)
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textTertiary)
                    .tracking(1.5)
                Spacer(minLength: 6)
                Text(isExpanded ? "hide \u{25B4}" : "show \u{25BE}")
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("These are real rows from Holmes's memory database. The second line of each says why it matched.")
    }

    private var countLabel: String {
        let noun = events.count == 1 ? "MEMORY" : "MEMORIES"
        return "GROUNDED IN \(events.count) \(noun)"
    }

    /// The subject named in the copy. First is the extractor's strongest.
    private var primaryTopic: String { topics.first ?? "" }

    /// Names what these rows are NOT. The wording is the whole point: rows the
    /// drafter saw are worth showing, but the user has to be able to tell at a
    /// glance that they are not an answer to the question that was asked.
    /// Tappable for the same reason the grounded header is — when the recall
    /// came back empty this is the only expander on the strip.
    private var backgroundHeading: some View {
        Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Text(primaryTopic.isEmpty
                     ? "BACKGROUND \u{2014} NOT MATCHED TO THEIR MESSAGE"
                     : "BACKGROUND \u{2014} NOT ABOUT \u{201C}\(primaryTopic)\u{201D}")
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textPlaceholder)
                    .tracking(1.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(isExpanded ? "hide \u{25B4}" : "show \u{25BE}")
                    .font(NoirFonts.font(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(NoirColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Rows the drafter had on hand from what the user is working on now. They did NOT come from searching for what this message asked about, so they are not evidence for the answer.")
    }

    private func rows(_ list: [(event: MemoryEvent, matchedOn: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(list, id: \.event.id) { row in
                GroundedMemoryRow(event: row.event, matchedOn: row.matchedOn, topic: primaryTopic)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoirColors.accentDim)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(NoirColors.glassDivider, lineWidth: 0.75)
        )
    }

    /// The honest failure state. A draft with nothing under it is not the same
    /// object as a grounded one, and it must not look like one.
    private var unsourcedWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(replyWarning)
                .padding(.top, 1)
            Text(primaryTopic.isEmpty
                 ? "No memories matched — this draft is unsourced."
                 : "No memories about \u{201C}\(primaryTopic)\u{201D} — this draft is unsourced.")
                .font(NoirFonts.font(size: 10, weight: .semibold, design: .default))
                .foregroundColor(replyWarning)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(replyWarning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(replyWarning.opacity(0.35), lineWidth: 0.75)
        )
        .help("Holmes found nothing in memory about this subject, so the draft is written from the message alone. Read it twice.")
    }
}

// MARK: - GroundedMemoryRow
// One receipt: the stored summary, then why it matched and when it happened.

@MainActor
private struct GroundedMemoryRow: View {
    let event: MemoryEvent

    /// Why this row came back, already resolved by the strip.
    let matchedOn: String

    /// Only for the tooltip's wording when the match couldn't be verified.
    let topic: String

    @State private var isHovered = false

    /// "repo entity · 2h ago". Falls back to plain provenance when there is no
    /// subject to explain (the activity-keyed recall path).
    private var subline: String {
        let when = RecallTime.ago(event.date)
        let reason = matchedOn
        if reason.isEmpty {
            let place = event.site.isEmpty ? event.app : event.site
            return place.isEmpty ? when : "\(place) · \(when)"
        }
        return "\(reason) · \(when)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{00B7}")
                .font(NoirFonts.font(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(NoirColors.textPlaceholder)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(NoirFonts.font(size: 10, weight: .semibold, design: .default))
                    .foregroundColor(isHovered ? NoirColors.textPrimary : NoirColors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subline)
                    .font(NoirFonts.font(size: 8, weight: .regular, design: .monospaced))
                    .foregroundColor(RecallReason.isWeak(matchedOn) ? replyWarning.opacity(0.85)
                                                                    : NoirColors.textPlaceholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(rowTooltip)
    }

    private var rowTooltip: String {
        let detail = event.detail.isEmpty ? event.summary : event.detail
        let subject = topic.isEmpty ? "the subject" : "\u{201C}\(topic)\u{201D}"
        let why = RecallReason.isWeak(matchedOn)
            ? "This row came back from the full-text search, but \(subject) does not appear in it literally. Check it."
            : "Matched on: \(matchedOn.isEmpty ? "related work" : matchedOn)"
        return "\(why)\n\n\(String(detail.prefix(400)))"
    }
}

// MARK: - Warning colour

// File-local for the same reason AgentMemoryCard keeps its own: the Apple-glass
// palette in NoirColors is white/green/red/blue with no amber, and "this draft
// is unsourced" is not an error — it is a caution, and must not read as the same
// severity as a failure.
private let replyWarning = Color(hex: "E0A33C")

private extension ContextConfidence {
    var replyDotColor: Color {
        switch self {
        case .exact:      return NoirColors.success
        case .structural: return replyWarning
        case .inferred:   return NoirColors.textTertiary
        }
    }

    /// Blunt, and never flattering to a weak reading.
    var replyLabel: String {
        switch self {
        case .exact:      return "EXACT"
        case .structural: return "STRUCTURAL"
        case .inferred:   return "GUESSED"
        }
    }

    var replyHelp: String {
        switch self {
        case .exact:
            return "The context behind this draft was read from the browser DOM or a structured field — Holmes can quote it."
        case .structural:
            return "The context behind this draft came from the Accessibility tree: reliable, but coarse. Specifics may be off."
        case .inferred:
            return "Holmes could not read the context exactly. Treat every specific in this draft as unverified."
        }
    }
}

// MARK: - Preview

#Preview {
    // The exact scenario: the user has been in tryholmes/holmes all afternoon,
    // someone texts "hey what is holmes?", and the answer is already written.
    let now = Date()
    let grounded: [MemoryEvent] = [
        MemoryEvent(id: 8801, date: now.addingTimeInterval(-7_200), kind: "context",
                    app: "Comet", windowTitle: "Reviewing PR #482 · tryholmes/holmes",
                    activity: "reviewing",
                    summary: "Reviewing PR #482 in tryholmes/holmes",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    url: "https://github.com/tryholmes/holmes/pull/482",
                    site: "github.com",
                    entitiesJSON: "{\"pr\":\"482\",\"repo\":\"tryholmes/holmes\"}"),
        MemoryEvent(id: 8802, date: now.addingTimeInterval(-93_600), kind: "context",
                    app: "Comet", windowTitle: "HolmesAgent.swift · tryholmes/holmes",
                    activity: "reading",
                    summary: "Reading HolmesAgent.swift in tryholmes/holmes",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    url: "https://github.com/tryholmes/holmes/blob/main/HolmesAgent.swift",
                    site: "github.com",
                    entitiesJSON: "{\"file\":\"HolmesAgent.swift\"}"),
        MemoryEvent(id: 8803, date: now.addingTimeInterval(-10_800), kind: "context",
                    app: "Comet", windowTitle: "Issues · tryholmes/holmes",
                    activity: "triaging",
                    summary: "Triaging open issues in tryholmes/holmes",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    site: "github.com",
                    entitiesJSON: "{\"repo\":\"tryholmes/holmes\"}"),
        MemoryEvent(id: 8804, date: now.addingTimeInterval(-18_000), kind: "context",
                    app: "Xcode", windowTitle: "MemoryStore.swift",
                    activity: "coding",
                    summary: "Writing the SQLite memory store for Holmes",
                    detail: "source: accessibility\nconfidence: structural",
                    source: "accessibility", confidence: "structural"),
        MemoryEvent(id: 8805, date: now.addingTimeInterval(-260_000), kind: "context",
                    app: "Comet", windowTitle: "Actions · tryholmes/holmes",
                    activity: "reading",
                    summary: "Watching the release build for tryholmes/holmes",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    site: "github.com"),
        // A row FTS returned that never literally names the subject — rendered
        // in the warning colour so the user can catch the bad recall.
        MemoryEvent(id: 8806, date: now.addingTimeInterval(-32_400), kind: "context",
                    app: "Comet", windowTitle: "SwiftUI Observation",
                    activity: "reading",
                    summary: "Reading the Observation framework docs",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    site: "developer.apple.com")
    ]

    // The reasons MemoryStore.recall reported for each row, verbatim — the
    // last one is the honest failure case the UI has to make visible.
    let hits: [MemoryStore.RecallHit] = [
        MemoryStore.RecallHit(event: grounded[0], score: 0.94, matchedOn: "repo entity (+3 similar)"),
        MemoryStore.RecallHit(event: grounded[1], score: 0.81, matchedOn: "site github.com"),
        MemoryStore.RecallHit(event: grounded[2], score: 0.77, matchedOn: "repo entity"),
        MemoryStore.RecallHit(event: grounded[3], score: 0.62, matchedOn: "summary text"),
        MemoryStore.RecallHit(event: grounded[4], score: 0.44, matchedOn: "repo entity"),
        MemoryStore.RecallHit(event: grounded[5], score: 0.19, matchedOn: RecallReason.unverified)
    ]

    // One row that never came from searching for "holmes" — it matched the
    // CURRENT screen, not the subject — so it renders under BACKGROUND rather
    // than inflating the grounded count.
    let background: [MemoryEvent] = [
        MemoryEvent(id: 8807, date: now.addingTimeInterval(-1_800), kind: "context",
                    app: "Comet", windowTitle: "SwiftUI Observation",
                    activity: "reading",
                    summary: "Reading the Observation framework docs",
                    detail: "source: browserExtension\nconfidence: exact",
                    source: "browserExtension", confidence: "exact",
                    site: "developer.apple.com")
    ]

    let draft = ReplyComposer.DraftedReply(
        body: "it's a macOS AI agent i've been building — it watches your screen and prepares the next thing before you ask.",
        groundedIn: grounded,
        background: background,
        confidence: .exact,
        recallHits: hits,
        topics: ["holmes"])

    let incoming = ReplyComposer.IncomingMessage(
        surface: ReplyComposer.surfaceIMessage,
        sender: "Alex",
        text: "hey what is holmes?",
        threadID: "iMessage;-;+15551234567",
        app: "Messages")

    // Nothing on file about the subject: the strip has to say so in the warning
    // colour instead of quietly showing a bare draft.
    let unsourced = ReplyComposer.DraftedReply(
        body: "let me check and get back to you",
        groundedIn: [],
        background: [],
        confidence: .inferred,
        recallHits: [],
        topics: ["holmes"])

    // The DANGEROUS case, and the one this strip exists for: the sender named a
    // subject, recall found nothing, and the drafter still had current-task rows
    // to hand. The card must say UNSOURCED and file those rows under BACKGROUND
    // — never count them as "grounded in 3 memories".
    let misleading = ReplyComposer.DraftedReply(
        body: "not sure — i'd have to dig it up and get back to you",
        groundedIn: [],
        background: Array(grounded.suffix(3)),
        confidence: .structural,
        recallHits: [],
        topics: ["holmes"])

    ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()
        ScrollView {
            VStack(spacing: 14) {
                ReplyReadyCard(draft: draft, incoming: incoming)
                ReplyReadyCard(draft: unsourced, incoming: incoming)
                ReplyReadyCard(draft: misleading, incoming: incoming)
            }
            .padding(14)
        }
    }
    .frame(width: 400, height: 980)
}
