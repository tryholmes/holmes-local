import AppKit
import Foundation

/// Connects exact compose context, the shared writing session and the existing
/// editable review card. It never inserts merely because generation finished.
@MainActor
final class EmailDraftCoordinator {
    static let shared = EmailDraftCoordinator()
    private var trigger = EmailComposeTrigger()
    private var debounce: Task<Void, Never>?
    private var debounceID: UUID?
    private var debounceKey: String?
    private var automaticTask: Task<Void, Never>?
    private var observed: EmailComposeSnapshot?
    private var isStopped = false
    private var explicitTask: Task<EmailDraftOutcome, Never>?
    private var explicitID: UUID?
    private var ownedExplicitActivity: UUID?

    private lazy var session = EmailDraftSession(dependencies: .init(
        isReady: { OllamaConfig.isConfigured },
        notReadyMessage: { OllamaConfig.notReadyMessage },
        generate: { input, origin in try await Self.generate(input, origin: origin) },
        refresh: { expected in await Self.refresh(expected: expected)?.emailCompose },
        publish: { prepared in Self.publish(prepared) }
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
        observed = snapshot
        session.noteContext(snapshot)
        guard explicitID == nil, session.origin != .user else { return }
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
                let input = EmailDraftInput(instruction: "Draft this email using its subject. Keep it concise and natural.", compose: fresh)
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
        trigger.reset()
        if session.origin == .background { session.cancel() }
    }

    func stop() {
        isStopped = true
        cancelExplicitRequest()
        cancelDebounce()
        automaticTask?.cancel()
        automaticTask = nil
        observed = nil
        trigger.reset()
        session.cancel()
    }

    /// Called only after the person reviews the actual text and presses Insert.
    func insert(_ body: String, expected: EmailComposeSnapshot) async throws -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmailDraftTextError.unusable
        }
        switch expected.source {
        case .browser: return try await BrowserBridge.shared.stageEmailDraft(body, expected: expected)
        case .accessibility: return try await MailComposeReader.stageEmailDraft(body, expected: expected)
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

    private static func refresh(expected: EmailComposeSnapshot?) async -> LiveContext? {
        if expected?.source == .accessibility || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" {
            return MailComposeReader.refreshEmailComposeContext()
        }
        return await BrowserBridge.shared.refreshEmailComposeContext()
    }

    private static func generate(_ input: EmailDraftInput, origin: WorkActivityCenter.Origin) async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        return try await EmailDraftText.generate(input: input) { system, user in
            while true {
                try Task.checkCancellation()
                do {
                    return try await OllamaClient.shared.complete(
                        system: system, user: user, maxTokens: 768, asJSON: true,
                        schema: OllamaClient.objectSchema(["body": ["type": "string", "description": "The finished email body only"]]),
                        priority: origin == .user ? .agent : .background)
                } catch OllamaClient.AgentError.busy where origin == .background && Date() < deadline {
                    if let id = WorkActivityScope.id {
                        WorkActivityCenter.shared.update(id, phase: .queued, detail: "Waiting for the local model to draft your email")
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private static func publish(_ prepared: PreparedEmailDraft) {
        let input = prepared.input
        let subject = input.compose?.subject ?? input.subject
        let recipient = input.compose?.recipients.joined(separator: ", ") ?? input.recipient
        var details = [String]()
        if !recipient.isEmpty { details.append("To: \(recipient)") }
        if let snapshot = input.compose {
            if !snapshot.cc.isEmpty { details.append("Cc: \(snapshot.cc.joined(separator: ", "))") }
            if !snapshot.bcc.isEmpty { details.append("Bcc: \(snapshot.bcc.joined(separator: ", "))") }
        }
        if !subject.isEmpty { details.append("Subject: \(subject)") }
        details.append("Prepared from your email and request. Review before inserting.")
        let draft = ProactiveDraft(
            id: prepared.id, playbookId: "email-compose", kind: .emailCompose,
            title: subject.isEmpty ? "Your email draft" : "Draft: \(subject)",
            body: prepared.body, contextSummary: details.joined(separator: "\n"),
            target: input.compose.map(DraftTarget.emailCompose) ?? .clipboard)
        PlaybookEngine.shared.offerDraft(draft, prioritize: prepared.isUserInitiated)
        HolmesAgent.shared.logActivity(note: "Prepared an email draft for review")
    }

    private static func context(for snapshot: EmailComposeSnapshot) -> LiveContext {
        LiveContext(source: snapshot.source == .browser ? .browserExtension : .accessibility,
                    confidence: .exact, app: snapshot.app, activity: "composing",
                    headline: "Writing an email", entities: ["surface": ContextSurface.emailCompose.rawValue],
                    bodyText: snapshot.body, capturedAt: snapshot.capturedAt, emailCompose: snapshot)
    }
}
