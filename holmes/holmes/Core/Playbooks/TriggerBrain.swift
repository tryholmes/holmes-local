import Foundation

// MARK: - TriggerBrain
// Opportunity detection — the second detector behind the heuristic playbook
// matchers. PlaybookEngine.evaluate() calls consider() only on ticks where NO
// heuristic playbook matched; TriggerBrain then decides whether the screen shows
// an actionable opportunity and, if so, fires the mapped playbook through
// PlaybookEngine.fireFromTrigger — which holds the heuristic path's attempt
// floor, single-flight, and cooldowns, plus a key-independent per-window
// re-fire guard so entity drift between the two detectors can't double-draft
// one unchanged screen.
//
// THE DETECTION IS DETERMINISTIC. It reads LiveContext — the structured record
// of what the user is actually doing, built from the browser DOM or the macOS
// Accessibility tree — and maps surface + entities onto a playbook. No model
// looks at the screen and guesses. That is the whole point: a model asked "is
// this an email?" about a terminal transcript will eventually say yes, and the
// cost of that mistake is a fabricated draft addressed to a person who doesn't
// exist (exactly how a Ghostty window once produced a "Reply to Ada").
//
// The local model is consulted for ONE thing: an AMBIGUOUS screen — a candidate surface
// whose keying entity is missing, or a context Holmes could only read coarsely.
// Even then the model can only choose among the four fireable opportunities or
// answer "none"; it never invents entities and never widens the candidate set.
//
// Discipline:
//   • deterministic fires: only when the context signature changed
//   • model confirmations: at most one every 20 seconds, single-flight, only
//     when the local model is ready, only when there is real text to reason about
//   • never on an .inferred (OCR) context — a guess must not stage a draft
//   • fires only at confidence >= 0.7, only for enabled playbooks

@MainActor
final class TriggerBrain {
    static let shared = TriggerBrain()
    private init() {}

    // ── State ───────────────────────────────────────
    private var isClassifying = false
    private var lastClassificationAt: Date = .distantPast
    private var lastSignature: Int? = nil
    /// The most recent exact/structural reading of the screen, published by the
    /// perception loop. Deterministic detection runs off THIS, not off OCR text.
    private var latestContext: LiveContext?

    private static let minInterval: Double = 20
    private static let minScreenTextChars = 80
    private static let confidenceThreshold = 0.7
    /// email_reply is the highest-risk false fire — a terminal transcript or code
    /// diff can read like an email, which is exactly how a Ghostty terminal
    /// produced a bogus "Reply to Ada" draft. Hold it to a stronger bar than the
    /// shared threshold unless the context is a real email surface
    /// (see contextLooksLikeEmail).
    private static let emailConfidenceThreshold = 0.8
    /// A LiveContext older than this no longer describes the screen the playbook
    /// engine is asking about, so it must not key a draft.
    private static let contextFreshness: TimeInterval = 12

    /// Opportunity -> playbook id. Only these are trigger-fireable; anything
    /// else is treated as "none". (email_reply / linkedin_post were removed in
    /// the 154→5 playbook purge — a decide() that still names them dead-ends
    /// safely at the map lookup.)
    private static let playbookIds: [String: String] = [
        "github_brief": "github-brief",
        "chat_reply": "chat-reply"
    ]

    // MARK: - Live context feed (called by HolmesAgent's tier-0 path)

    /// Hands TriggerBrain the exact/structural reading of the current screen.
    /// Inferred (OCR) contexts are dropped on the floor: they are the one input
    /// that could turn a misread pixel into a staged draft.
    func noteLiveContext(_ context: LiveContext) {
        guard context.confidence != .inferred else { return }
        latestContext = context
    }

    // MARK: - Entry point (PlaybookEngine.evaluate, heuristic-miss ticks only)

    func consider(_ ctx: PlaybookContext) {
        guard !isClassifying, !PlaybookEngine.shared.isExecuting else { return }
        // No enabled trigger-fireable playbook -> a detection could never fire
        // anything; don't spend a single cycle on it.
        guard Self.playbookIds.values.contains(where: { PlaybookEngine.isEnabled($0) }) else { return }

        // Only look when the scene actually changed. The signature is recorded on
        // the deterministic path too, so a static screen is examined once.
        let signature = Self.signature(of: ctx)
        guard signature != lastSignature else { return }

        // ── Tier 1: deterministic detection off LiveContext ──────────────────
        if let live = freshLiveContext(), let decision = Self.decide(live) {
            switch decision {
            case .fire(let opportunity, let entities):
                lastSignature = signature
                fire(opportunity: opportunity, extraEntities: entities, ctx: ctx,
                     because: "live context (\(live.confidence.rawValue))")
                return
            case .ambiguous(let candidate, let entities):
                // Fall through to the model, but with the candidate named — the
                // model is confirming a specific hypothesis, not free-associating.
                confirm(candidate: candidate, extraEntities: entities, live: live,
                        ctx: ctx, signature: signature)
                return
            }
        }

        // ── Tier 2: no usable structured reading of this screen ──────────────
        // Everything Holmes has here is coarse text. Ask the model ONLY whether one
        // of the four opportunities applies, and hold it to the confidence bars.
        confirm(candidate: nil, extraEntities: [:], live: nil, ctx: ctx, signature: signature)
    }

    /// The published LiveContext, but only while it still describes this screen.
    private func freshLiveContext() -> LiveContext? {
        guard let context = latestContext,
              context.age < Self.contextFreshness,
              context.confidence != .inferred
        else { return nil }
        return context
    }

    // MARK: - Deterministic decision

    enum Decision {
        /// The surface and its keying entity are both known — fire now, no model.
        case fire(opportunity: String, entities: [String: String])
        /// The surface is recognizable but the entity that keys the draft is
        /// missing, so a draft would be addressed to nobody. Ask before firing.
        case ambiguous(candidate: String, entities: [String: String])
    }

    /// Maps a LiveContext onto a fireable opportunity. Pure, synchronous, and
    /// total: every branch is a literal read of structured data.
    static func decide(_ live: LiveContext) -> Decision? {
        let entities = playbookEntities(from: live)
        let surface = ContextSurface(rawValue: live.entities["surface"] ?? "") ?? .unknown

        switch surface {
        case .emailRead, .emailCompose:
            // email_reply has no playbook since the 154→5 purge. Returning it
            // here dead-ended at the map lookup AND, when ambiguous, spent a
            // rate-limited local-model confirm on a hypothesis that could never
            // fire. Email screens fall through to Tier 2 instead.
            return nil

        case .emailInbox:
            // An inbox listing is not a message. Nothing to reply to yet.
            return nil

        case .githubPR, .githubIssue, .githubRepo, .githubFile:
            let hasRepo = !(entities["repoOwner"] ?? "").isEmpty
                && !(entities["repoName"] ?? "").isEmpty
            return hasRepo
                ? .fire(opportunity: "github_brief", entities: entities)
                : .ambiguous(candidate: "github_brief", entities: entities)

        case .directMessage, .teamChannel:
            return (entities["contact"]?.isEmpty == false)
                ? .fire(opportunity: "chat_reply", entities: entities)
                : .ambiguous(candidate: "chat_reply", entities: entities)

        case .socialPost, .socialFeed:
            // LinkedIn only — the post playbook writes LinkedIn prose, and a
            // draft aimed at the wrong network is worse than none.
            guard (live.site ?? "").contains("linkedin") else { return nil }
            return .fire(opportunity: "linkedin_post", entities: entities)

        case .video, .aiChat, .document, .article, .search, .shopping,
             .code, .terminal, .unknown:
            // Deliberately silent. These are real, recognized surfaces with no
            // fireable playbook — "unknown" included, because a screen Holmes
            // could not classify is precisely where a guess does the most damage.
            return nil
        }
    }

    /// Translates LiveContext's entity vocabulary into the canonical keys the
    /// playbook matchers read (see PlaybookModels).
    static func playbookEntities(from live: LiveContext) -> [String: String] {
        var out: [String: String] = [:]
        func copy(_ source: String, to destination: String) {
            if let value = live.entities[source]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                out[destination] = value
            }
        }
        copy("sender", to: "sender")
        copy("subject", to: "subject")
        copy("recipient", to: "recipient")
        copy("contact", to: "contact")
        copy("prompt", to: "promptText")
        copy("assistant", to: "platform")
        // A team channel keys the chat playbook by its channel name.
        if out["contact"] == nil { copy("channel", to: "contact") }
        // "owner/name" is one entity on LiveContext, two on PlaybookContext.
        if let repo = live.entities["repo"], repo.contains("/") {
            let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                out["repoOwner"] = parts[0]
                out["repoName"] = parts[1]
            }
        }
        return out
    }

    // MARK: - Fire

    /// Merges the detected entities UNDER the heuristics' (a heuristic value came
    /// from the same structured extraction and wins on collision) and hands the
    /// enriched context to the engine.
    private func fire(opportunity: String,
                      extraEntities: [String: String],
                      ctx: PlaybookContext,
                      because reason: String) {
        guard let playbookId = Self.playbookIds[opportunity] else { return }
        guard PlaybookEngine.isEnabled(playbookId) else { return }

        var entities = extraEntities
        for (key, value) in ctx.entities where !value.isEmpty { entities[key] = value }
        let enriched = PlaybookContext(
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            contextType: ctx.contextType,
            screenText: ctx.screenText,
            entities: entities
        )

        print("[Holmes] TriggerBrain: '\(opportunity)' from \(reason) -> playbook '\(playbookId)'")
        PlaybookEngine.shared.fireFromTrigger(playbookId: playbookId, context: enriched)
    }

    // MARK: - Model confirmation (ambiguous screens only)

    /// One short local-model call that may only answer with one of the four
    /// opportunities or "none". Structured output, so the reply is a valid JSON
    /// object by construction rather than by pleading.
    private func confirm(candidate: String?,
                         extraEntities: [String: String],
                         live: LiveContext?,
                         ctx: PlaybookContext,
                         signature: Int) {
        guard OllamaConfig.isConfigured, OllamaConfig.backgroundModelEnabled else { return }
        let screenText = ctx.screenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard screenText.count >= Self.minScreenTextChars else { return }
        // Rate limit. The signature is NOT recorded on a rate-limited skip, so a
        // new scene seen mid-cooldown still gets one look once the window opens.
        guard Date().timeIntervalSince(lastClassificationAt) >= Self.minInterval else { return }

        lastSignature = signature
        lastClassificationAt = Date()
        isClassifying = true

        Task { @MainActor in
            defer { isClassifying = false }

            let raw: String
            do {
                raw = try await OllamaClient.shared.complete(
                    system: Self.systemPrompt,
                    user: Self.prompt(for: ctx, candidate: candidate, live: live),
                    maxTokens: 200,
                    asJSON: true,
                    schema: Self.verdictSchema)
            } catch OllamaClient.AgentError.busy {
                // The GPU is busy with an agent session (the common case for
                // the whole length of a /run or playbook draft). Forget the
                // signature so THIS screen gets another look once the rate
                // window opens, not only the next different one.
                lastSignature = nil
                return
            } catch {
                print("[Holmes] TriggerBrain: confirmation failed — \(error.localizedDescription)")
                return
            }

            guard let verdict = Self.parse(raw) else {
                print("[Holmes] TriggerBrain: unparseable confirmation — treating as none")
                return
            }
            guard verdict.opportunity != "none" else { return }
            // The model may only CONFIRM the candidate, never substitute another
            // one — swapping opportunities is how a misread screen becomes a
            // draft for the wrong app entirely.
            if let candidate, verdict.opportunity != candidate {
                print("[Holmes] TriggerBrain: model answered '\(verdict.opportunity)' for a '\(candidate)' screen — ignored")
                return
            }
            guard verdict.confidence >= Self.confidenceThreshold else {
                print("[Holmes] TriggerBrain: '\(verdict.opportunity)' below threshold (\(verdict.confidence))")
                return
            }
            // Extra bar for email_reply: unless the context is a genuine email
            // surface, require high confidence so a terminal/editor transcript
            // that merely *reads* like a message can't stage an email draft.
            if verdict.opportunity == "email_reply",
               !Self.contextLooksLikeEmail(ctx),
               verdict.confidence < Self.emailConfidenceThreshold {
                print("[Holmes] TriggerBrain: email_reply below email bar (\(verdict.confidence)) with no email surface — skipped")
                return
            }

            fire(opportunity: verdict.opportunity, extraEntities: extraEntities, ctx: ctx,
                 because: "local model confirmation (\(verdict.confidence))")
        }
    }

    // MARK: - Email-surface gate

    /// True when the context is genuinely an email client / webmail — an email
    /// client app, an "email…" contextType from the heuristic classifier, or a
    /// Gmail/Outlook webmail URL in the title/OCR. Used to relax the extra
    /// email_reply confidence bar only when we're actually looking at email.
    private static func contextLooksLikeEmail(_ ctx: PlaybookContext) -> Bool {
        if ctx.contextType.lowercased().contains("email") { return true }
        let app = ctx.appName.lowercased()
        let emailApps = ["mail", "outlook", "spark", "airmail", "thunderbird",
                         "mimestream", "canary", "superhuman", "postbox", "mailmate"]
        if emailApps.contains(where: { app.contains($0) }) { return true }
        let hay = (ctx.windowTitle + " " + ctx.screenText).lowercased()
        return hay.contains("mail.google.com") || hay.contains("gmail") ||
               hay.contains("outlook.office") || hay.contains("outlook.live")
    }

    // MARK: - Scene signature

    /// Robust to text jitter: extracted screen text for a visually static screen
    /// churns between ticks (recognition ordering, "2m ago" timestamps, unread
    /// counts), so hashing a raw text prefix would degrade this gate to a flat
    /// poll. Hash the app + window title + a COARSE bucket of the alphanumeric
    /// text volume instead — the signature only changes when the scene does.
    private static func signature(of ctx: PlaybookContext) -> Int {
        var hasher = Hasher()
        hasher.combine(ctx.appName)
        hasher.combine(ctx.windowTitle)
        let alphanumericCount = ctx.screenText.unicodeScalars
            .lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        hasher.combine(alphanumericCount / 200)
        return hasher.finalize()
    }

    // MARK: - Confirmation prompt

    private static let systemPrompt = """
    You are a conservative classifier inside a desktop assistant. You decide ONLY \
    whether the described screen is one of four specific, actionable situations. \
    You never describe the screen, never invent names or subjects, and never \
    answer with anything outside the allowed set. When the evidence is thin, \
    answer "none" — a wrong yes causes the assistant to draft a message to \
    somebody who does not exist, which is far worse than a missed suggestion.
    """

    /// Strict output shape. `entities` is deliberately absent: entities come from
    /// structured extraction only, never from a model's reading of screen text.
    private static let verdictSchema: [String: Any] = OllamaClient.objectSchema([
        "opportunity": [
            "type": "string",
            "enum": ["email_reply", "github_brief", "linkedin_post", "chat_reply", "none"],
            "description": "Which actionable situation the screen shows, or none."
        ],
        "confidence": [
            "type": "number",
            "description": "0.0-1.0 certainty that the opportunity label is correct."
        ]
    ])

    private static func prompt(for ctx: PlaybookContext,
                               candidate: String?,
                               live: LiveContext?) -> String {
        let excerpt = String(ctx.screenText.prefix(1200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Active app: \(ctx.appName)",
            "Window title: \(ctx.windowTitle)"
        ]
        if let live {
            // What Holmes already knows for certain, so the model corroborates a
            // reading rather than producing one.
            lines.append("Holmes read this screen as: \(live.headline)")
            lines.append("Reading quality: \(live.confidence.rawValue) (\(live.source.label))")
        }
        if let candidate {
            lines.append("Hypothesis to confirm or reject: \"\(candidate)\". Answer with that value or \"none\" — nothing else.")
        }

        return """
        \(lines.joined(separator: "\n"))

        Screen text (may be noisy or partial):
        \"\"\"
        \(excerpt)
        \"\"\"

        Opportunity types:
        - "email_reply": an ACTUAL email (Gmail, Outlook, Apple Mail, webmail — From/To/Subject headers or a message body) the user is reading or writing that deserves a reply. A terminal, code editor, chat app, PR page, or web article is NOT email.
        - "github_brief": a GitHub repository, pull request, or issue worth a briefing.
        - "linkedin_post": LinkedIn content the user could turn into a post.
        - "chat_reply": a chat message (iMessage/Slack/Discord/WhatsApp) awaiting a reply.
        - "none": nothing actionable, or you are not sure.
        """
    }

    // MARK: - Defensive parsing

    struct Verdict {
        let opportunity: String
        let confidence: Double
        let entities: [String: String]
    }

    /// Parses the model's reply. Structured outputs make the body a valid JSON
    /// object, but this stays tolerant of code fences, prefix/suffix prose —
    /// including prose that itself contains braces ("I think {this} is it:
    /// {...}") by retrying from the next `{` when a candidate fails to parse —
    /// and raw newlines inside string values. Any failure returns nil (= none):
    /// malformed input can only cost a missed detection, never a false fire.
    static func parse(_ raw: String) -> Verdict? {
        var found: Verdict?
        _ = ModelJSON.firstObject(in: raw, where: { object in
            found = verdict(from: object)
            return found != nil
        })
        return found
    }

    private static func verdict(from object: [String: Any]) -> Verdict? {
        guard let rawOpportunity = object["opportunity"] as? String else { return nil }

        let opportunity = rawOpportunity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !opportunity.isEmpty else { return nil }

        var confidence = 0.0
        // NSNumber check with an explicit boolean rejection: `as? Double` would
        // bridge `"confidence": true` to 1.0 and fire on a non-numeric value.
        if let number = object["confidence"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            confidence = number.doubleValue
        } else if let string = object["confidence"] as? String,
                  let number = Double(string.trimmingCharacters(in: .whitespaces)) {
            confidence = number
        }
        confidence = min(max(confidence, 0), 1)

        var entities: [String: String] = [:]
        if let rawEntities = object["entities"] as? [String: Any] {
            for (key, value) in rawEntities {
                guard entities.count < 8 else { break }
                guard let string = value as? String else { continue }
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedValue = String(string.prefix(200))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else { continue }
                entities[trimmedKey] = trimmedValue
            }
        }

        return Verdict(opportunity: opportunity, confidence: confidence, entities: entities)
    }

    /// Returns the first balanced `{...}` in the text — string- and escape-aware,
    /// so braces inside JSON string values can't unbalance the scan.
    static func extractFirstJSONObject(from raw: String) -> String? {
        ModelJSON.objectCandidates(in: raw).first
    }
}
