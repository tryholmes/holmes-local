import AppKit
import Foundation

/// Predicts the email for the open composer and writes it directly when the
/// body holds nothing of the person's own (signature and quote are kept), with
/// one click undo. When the person has typed, it offers the review card once.
/// It never sends, and every follow up action asks first.
@MainActor
final class EmailDraftCoordinator {
    static let shared = EmailDraftCoordinator()

    struct WrittenEmail: Equatable {
        let token: String
        let expected: EmailComposeSnapshot
        let subjectFilled: Bool
        let at: Date
    }

    private var trigger = EmailComposeTrigger()
    private var debounce: Task<Void, Never>?
    private var debounceID: UUID?
    private var debounceKey: String?
    private var automaticTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var observed: EmailComposeSnapshot?
    private var lastComposeBlocker: String?
    private var isStopped = false
    private var explicitTask: Task<EmailDraftOutcome, Never>?
    private var explicitID: UUID?
    private var ownedExplicitActivity: UUID?
    private var deferred: PreparedEmailDraft?
    private(set) var lastWrite: WrittenEmail?

    private lazy var session = EmailDraftSession(dependencies: .init(
        isReady: { OllamaConfig.isConfigured },
        notReadyMessage: { OllamaConfig.notReadyMessage },
        generate: { input, origin in try await Self.generate(input, origin: origin) },
        refresh: { expected in await Self.refresh(expected: expected)?.emailCompose },
        publish: { [weak self] prepared in self?.handle(prepared) },
        canDefer: { snapshot in !Self.isComposerFrontmost(snapshot) }
    ))

    private init() {}

    func start() { isStopped = false }

    func canHandle(_ query: String) -> Bool {
        let context = HolmesAgent.shared.live
        let surface = context.entities["surface"] ?? ""
        let isEmail = context.source != .none && context.confidence != .inferred
            && ([ContextSurface.emailCompose.rawValue, ContextSurface.emailRead.rawValue].contains(surface)
                || context.emailCompose != nil)
        return EmailDraftIntent.matches(query, isEmailContext: isEmail)
    }

    func request(instruction: String, context: LiveContext? = nil) async -> EmailDraftOutcome {
        guard !Task.isCancelled else { return .cancelled }
        cancelAutomaticDraft()
        cancelExplicitRequest()
        session.cancel()
        let id = UUID()
        explicitID = id
        let inherited = WorkActivityScope.id
        let activity = inherited ?? WorkActivityCenter.shared.begin(title: "Drafting email", detail: "Reading the current email")
        ownedExplicitActivity = inherited == nil ? activity : nil
        let work = Task { @MainActor in
            await WorkActivityScope.$id.withValue(activity) {
                await self.prepare(instruction: instruction, context: context, id: id)
            }
        }
        explicitTask = work
        if inherited == nil { WorkActivityCenter.shared.setCancellationHandler(activity) { work.cancel() } }
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        if explicitID == id {
            explicitID = nil
            explicitTask = nil
            ownedExplicitActivity = nil
        }
        if inherited == nil {
            switch result {
            case .ready(let text): WorkActivityCenter.shared.finish(activity, outcome: .success, summary: text)
            case .failed(let text), .needsContext(let text): WorkActivityCenter.shared.finish(activity, outcome: .failure, summary: text)
            case .cancelled: WorkActivityCenter.shared.cancel(activity)
            }
        }
        return result
    }

    private func prepare(instruction: String, context: LiveContext?, id: UUID) async -> EmailDraftOutcome {
        guard !Task.isCancelled, explicitID == id else { return .cancelled }
        var current = context ?? HolmesAgent.shared.live
        let refreshed = await Self.refresh(expected: current.emailCompose)
        if let refreshed { current = refreshed }
        guard !Task.isCancelled, explicitID == id else { return .cancelled }
        let input = Self.input(instruction: instruction, context: current)
        if refreshed == nil, current.emailCompose != nil || !input.hasContent,
           let reason = BrowserBridge.shared.emailComposeUnavailableReason {
            return .needsContext(reason)
        }
        let outcome = await session.request(input, origin: .user)
        if case .ready = outcome, let snapshot = input.compose { trigger.succeeded(snapshot) }
        return outcome
    }

    /// Runs before the general context fingerprint gate: every header/body edit
    /// must invalidate old work, even when the page URL and title are unchanged.
    func observe(_ context: LiveContext) {
        guard !isStopped else { return }
        let snapshot = context.emailCompose
        // Holmes's own floating review/search windows do not replace the user's
        // email context. The insertion adapter still revalidates the exact target.
        if context.app.lowercased().contains("holmes") { return }
        resumeDeferred(with: snapshot)
        // Switching to another app is not a change to the email. Only a reading
        // of the same app (or any composer) can invalidate running work.
        if snapshot != nil || Self.sameSurface(context, as: session.contextSnapshot) {
            session.noteContext(snapshot)
        }
        observed = snapshot
        guard explicitID == nil, session.origin != .user else { return }
        if snapshot != nil { lastComposeBlocker = nil }
        if snapshot == nil, context.entities["surface"] == ContextSurface.emailCompose.rawValue,
           !MenuBarManager.shared.isPaused, AutonomyPolicy.shared.isEnabled("email-compose"),
           let reason = BrowserBridge.shared.emailComposeUnavailableReason, reason != lastComposeBlocker {
            lastComposeBlocker = reason
            let activity = WorkActivityCenter.shared.begin(title: "Email drafting needs attention", origin: .background)
            WorkActivityCenter.shared.finish(activity, outcome: .failure, summary: reason)
        }
        guard !MenuBarManager.shared.isPaused,
              AutonomyPolicy.shared.isEnabled("email-compose"),
              let delay = trigger.observe(snapshot), let snapshot else {
            cancelDebounce()
            return
        }
        // Unchanged observations must not continually push the timer back.
        let expectedKey = snapshot.revisionKey
        if debounce != nil, debounceKey == expectedKey { return }
        cancelDebounce()
        let id = UUID()
        debounceID = id
        debounceKey = expectedKey
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            // Keep this handle through the bridge await. Pause, new input, or
            // a changed header can then cancel the actual suspended refresh.
            defer {
                if self.debounceID == id {
                    self.debounce = nil
                    self.debounceID = nil
                    self.debounceKey = nil
                }
            }
            guard !Task.isCancelled, !self.isStopped, self.debounceID == id,
                  !MenuBarManager.shared.isPaused, AutonomyPolicy.shared.isEnabled("email-compose"),
                  self.explicitID == nil, self.observed?.revisionKey == expectedKey else { return }
            let refreshed = await Self.refresh(expected: snapshot)
            guard !Task.isCancelled, !self.isStopped, self.debounceID == id,
                  !MenuBarManager.shared.isPaused, AutonomyPolicy.shared.isEnabled("email-compose"),
                  self.explicitID == nil, self.observed?.revisionKey == expectedKey,
                  let fresh = refreshed?.emailCompose,
                  fresh.revisionKey == expectedKey,
                  self.trigger.claim(fresh), self.session.origin != .user else { return }
            self.automaticTask?.cancel()
            self.automaticTask = Task { [weak self] in
                guard let self, !Task.isCancelled, !self.isStopped,
                      !MenuBarManager.shared.isPaused, AutonomyPolicy.shared.isEnabled("email-compose"),
                      self.explicitID == nil, self.observed?.revisionKey == expectedKey else { return }
                let input = EmailDraftInput(instruction: "", compose: fresh)
                let result = await self.session.request(input, origin: .background)
                guard !Task.isCancelled else { return }
                if case .ready = result { self.trigger.succeeded(fresh) }
                self.automaticTask = nil
            }
        }
    }

    private func cancelDebounce() {
        debounceID = nil
        debounceKey = nil
        debounce?.cancel()
        debounce = nil
    }

    private func cancelExplicitRequest() {
        explicitID = nil
        explicitTask?.cancel()
        explicitTask = nil
        let activity = ownedExplicitActivity
        ownedExplicitActivity = nil
        if let activity { WorkActivityCenter.shared.cancel(activity) }
    }

    func cancelAutomaticDraft() {
        cancelDebounce()
        automaticTask?.cancel()
        automaticTask = nil
        deferred = nil
        trigger.reset()
        if session.origin == .background { session.cancel() }
    }

    func stop() {
        isStopped = true
        cancelExplicitRequest()
        cancelDebounce()
        automaticTask?.cancel()
        automaticTask = nil
        writeTask?.cancel()
        writeTask = nil
        deferred = nil
        observed = nil
        trigger.reset()
        session.cancel()
        EmailUndoPresenter.hide()
    }

    // MARK: Writing

    private func handle(_ prepared: PreparedEmailDraft) {
        guard let compose = prepared.input.compose else {
            Self.offerCard(prepared, target: nil)
            return
        }
        if prepared.deferred {
            deferred = prepared
            return
        }
        // An explicit request is reviewed before anything is written; only
        // automatic prediction writes directly.
        if !prepared.isUserInitiated, !prepared.reviewOnly, compose.canAutoWrite, prepared.prediction != nil {
            writeTask?.cancel()
            writeTask = Task { [weak self] in await self?.autoWrite(prepared) }
        } else {
            offerCardOnce(prepared, target: compose)
        }
    }

    /// A result finished while the person was elsewhere is written only into the
    /// same composer, exactly as it was when the prediction started.
    private func resumeDeferred(with snapshot: EmailComposeSnapshot?) {
        guard let pending = deferred, let expected = pending.input.compose,
              let snapshot, snapshot.identity == expected.identity else { return }
        deferred = nil
        guard snapshot.revisionKey == expected.revisionKey, !isStopped,
              !MenuBarManager.shared.isPaused, AutonomyPolicy.shared.isEnabled("email-compose") else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in await self?.autoWrite(pending) }
    }

    private func autoWrite(_ prepared: PreparedEmailDraft) async {
        guard let expected = prepared.input.compose, let prediction = prepared.prediction,
              !Task.isCancelled, !isStopped else { return }
        let subject = expected.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && expected.subjectEditable
            ? prediction.subject : nil
        let activity = WorkActivityCenter.shared.begin(title: "Writing your email", detail: expected.provider, origin: .background)
        do {
            let receipt = try await Self.write(prediction.body, subject: subject, mode: .auto, expected: expected)
            try Task.checkCancellation()
            trigger.didInsert(into: expected)
            cancelDebounce()
            remember(receipt, expected: expected)
            WorkActivityCenter.shared.finish(activity, outcome: .success, summary: "Holmes wrote your email. Undo is available.")
            HolmesAgent.shared.logActivity(note: "Wrote a predicted email into \(expected.provider)")
            await EmailActionOffers.offer(prediction.actions, compose: expected, body: prediction.body,
                                          subject: subject ?? expected.subject)
        } catch is CancellationError {
            WorkActivityCenter.shared.cancel(activity)
        } catch {
            WorkActivityCenter.shared.cancel(activity)
            // Never overwrite and never end silently: whatever refused the write,
            // the prediction is offered once on the review card instead.
            guard !Task.isCancelled, !isStopped else { return }
            let fresh = await Self.refresh(expected: expected)?.emailCompose
            guard !Task.isCancelled, !isStopped else { return }
            offerCardOnce(prepared, target: fresh.flatMap { $0.identity == expected.identity ? $0 : nil } ?? expected)
        }
    }

    private func offerCardOnce(_ prepared: PreparedEmailDraft, target: EmailComposeSnapshot) {
        if !prepared.isUserInitiated {
            guard !trigger.hasOffered(target) else { return }
            trigger.didOffer(for: target)
        }
        Self.offerCard(prepared, target: target)
    }

    private func remember(_ receipt: EmailWriteReceipt, expected: EmailComposeSnapshot) {
        guard let token = receipt.undoToken else { return }
        let written = WrittenEmail(token: token, expected: expected, subjectFilled: receipt.subjectFilled, at: Date())
        lastWrite = written
        EmailUndoPresenter.show(title: "Holmes wrote this email",
                                detail: receipt.subjectFilled ? "Body and subject. Nothing was sent." : "Nothing was sent.") { [weak self] in
            await self?.undo(written) ?? "Undo is no longer available."
        }
    }

    /// Called only after the person reviews the actual text and presses Replace or Insert.
    func insert(_ body: String, expected: EmailComposeSnapshot, mode: EmailWriteMode = .replace) async throws -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmailDraftTextError.unusable
        }
        let receipt = try await Self.write(body, subject: nil, mode: mode, expected: expected)
        cancelDebounce()
        trigger.didInsert(into: expected)
        remember(receipt, expected: expected)
        return true
    }

    /// Restores exactly what the composer held before the write. Returns a
    /// sentence for the undo toast.
    func undo(_ written: WrittenEmail) async -> String {
        do {
            switch written.expected.source {
            case .browser: try await BrowserBridge.shared.undoEmailDraft(token: written.token, expected: written.expected)
            case .accessibility: try await MailComposeReader.undoEmailDraft(token: written.token, expected: written.expected)
            }
            if lastWrite == written { lastWrite = nil }
            HolmesAgent.shared.logActivity(note: "Undid a predicted email")
            return "Undone. The email is back to how you left it."
        } catch {
            return error.localizedDescription
        }
    }

    private static func write(_ body: String, subject: String?, mode: EmailWriteMode,
                              expected: EmailComposeSnapshot) async throws -> EmailWriteReceipt {
        switch expected.source {
        case .browser: return try await BrowserBridge.shared.writeEmailDraft(body, subject: subject, mode: mode, expected: expected)
        case .accessibility: return try await MailComposeReader.writeEmailDraft(body, subject: subject, mode: mode, expected: expected)
        }
    }

    private static func input(instruction: String, context: LiveContext) -> EmailDraftInput {
        guard context.confidence != .inferred, context.source != .none, context.age < 20 else {
            return EmailDraftInput(instruction: instruction, compose: nil)
        }
        let surface = context.entities["surface"] ?? ""
        guard context.emailCompose != nil || [ContextSurface.emailCompose.rawValue, ContextSurface.emailRead.rawValue].contains(surface) else {
            return EmailDraftInput(instruction: instruction, compose: nil)
        }
        return EmailDraftInput(
            instruction: instruction, compose: context.emailCompose,
            subject: context.entities["subject"] ?? "",
            recipient: context.entities["recipient"] ?? context.entities["senderEmail"] ?? "",
            sourceBody: context.bodyText,
            isReply: surface == ContextSurface.emailRead.rawValue || context.entities["isReply"] == "true"
        )
    }

    private static func sameSurface(_ context: LiveContext, as snapshot: EmailComposeSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return context.app == snapshot.app
    }

    private static func isComposerFrontmost(_ snapshot: EmailComposeSnapshot) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if snapshot.source == .accessibility { return front == "com.apple.mail" }
        return snapshot.appBundleIdentifier == nil || front == snapshot.appBundleIdentifier
    }

    private static func refresh(expected: EmailComposeSnapshot?) async -> LiveContext? {
        if expected?.source == .accessibility || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" {
            return MailComposeReader.refreshEmailComposeContext()
        }
        return await BrowserBridge.shared.refreshEmailComposeContext()
    }

    private static func generate(_ input: EmailDraftInput, origin: WorkActivityCenter.Origin) async throws -> EmailPrediction {
        let deadline = Date().addingTimeInterval(180)
        func complete(_ system: String, _ user: String, schema: [String: Any]) async throws -> String {
            while true {
                try Task.checkCancellation()
                do {
                    return try await OllamaClient.shared.complete(
                        system: system, user: user, maxTokens: 768, asJSON: true, schema: schema,
                        priority: origin == .user ? .agent : .background)
                } catch OllamaClient.AgentError.busy where origin == .background && Date() < deadline {
                    if let id = WorkActivityScope.id {
                        WorkActivityCenter.shared.update(id, phase: .queued, detail: "Waiting for the local model to draft your email")
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        guard let compose = input.compose else {
            let schema = OllamaClient.objectSchema(["body": ["type": "string", "description": "The finished email body only"]])
            let body = try await EmailDraftText.generate(input: input) { system, user in
                try await complete(system, user, schema: schema)
            }
            return EmailPrediction(subject: nil, body: body, actions: [])
        }
        if let id = WorkActivityScope.id {
            WorkActivityCenter.shared.update(id, phase: .working, detail: "Reading the thread, calendar and memory")
        }
        let context = await EmailContextGatherer.gather(for: compose, instruction: input.instruction)
        try Task.checkCancellation()
        if let id = WorkActivityScope.id {
            WorkActivityCenter.shared.update(id, phase: .working, detail: "Predicting your email")
        }
        return try await EmailPredictionGenerator.generate(context: context) { system, user in
            try await complete(system, user, schema: EmailPredictionPrompt.schema)
        }
    }

    private static func offerCard(_ prepared: PreparedEmailDraft, target: EmailComposeSnapshot?) {
        let input = prepared.input
        let subject = target?.subject ?? input.subject
        let recipient = target?.recipients.joined(separator: ", ") ?? input.recipient
        var details = [String]()
        if !recipient.isEmpty { details.append("To: \(recipient)") }
        if let snapshot = target {
            if !snapshot.cc.isEmpty { details.append("Cc: \(snapshot.cc.joined(separator: ", "))") }
            if !snapshot.bcc.isEmpty { details.append("Bcc: \(snapshot.bcc.joined(separator: ", "))") }
        }
        if !subject.isEmpty { details.append("Subject: \(subject)") }
        details.append(target.map { $0.isOwnTextEmpty ? "Prepared from your email. Review before inserting." : "You already started writing, so Holmes did not change it. Replace your text or insert this below it." }
                       ?? "Prepared from your request. Review before using it.")
        let draft = ProactiveDraft(
            id: prepared.id, playbookId: "email-compose", kind: .emailCompose,
            title: subject.isEmpty ? "Your email draft" : "Draft: \(subject)",
            body: prepared.body, contextSummary: details.joined(separator: "\n"),
            target: target.map(DraftTarget.emailCompose) ?? .clipboard)
        PlaybookEngine.shared.offerDraft(draft, prioritize: prepared.isUserInitiated)
        HolmesAgent.shared.logActivity(note: "Prepared an email draft for review")
    }
}
