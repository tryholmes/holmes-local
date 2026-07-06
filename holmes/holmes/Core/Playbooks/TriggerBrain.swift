import Foundation

// MARK: - TriggerBrain
// Ollama-based opportunity detection — the second detector behind the heuristic
// playbook matchers. PlaybookEngine.evaluate() calls consider() only on ticks
// where NO heuristic playbook matched; TriggerBrain then asks the local model
// (LocalModelEngine — plain generation, no tools, fully offline) whether the
// screen shows an actionable opportunity, and if so fires the mapped playbook
// through PlaybookEngine.fireFromTrigger — which holds the heuristic path's
// attempt floor, single-flight, and cooldowns, plus a key-independent
// per-window re-fire guard so entity drift between the two detectors can't
// double-draft one unchanged screen.
//
// Discipline:
//   • at most one classification every 20 seconds
//   • only when the context signature changed (appName + windowTitle + a
//     coarse bucket of the screen text volume — robust to OCR jitter)
//   • never while a classification or a playbook run is in flight
//   • never when LocalModelEngine is unavailable or screenText is under 80 chars
//   • fires only at confidence >= 0.7, only for enabled playbooks

@MainActor
final class TriggerBrain {
    static let shared = TriggerBrain()
    private init() {}

    // ── State ───────────────────────────────────────
    private var isClassifying = false
    private var lastClassificationAt: Date = .distantPast
    private var lastSignature: Int? = nil

    private static let minInterval: Double = 20
    private static let minScreenTextChars = 80
    private static let confidenceThreshold = 0.7
    /// email_reply is the highest-risk false fire — a terminal transcript or code
    /// diff can read like an email to a small local model, which is exactly how a
    /// Ghostty terminal produced a bogus "Reply to Ada" draft. Hold it to a
    /// stronger bar than the shared threshold unless the context is a real email
    /// surface (see contextLooksLikeEmail).
    private static let emailConfidenceThreshold = 0.8

    /// Ollama opportunity -> playbook id. Only these four are trigger-fireable;
    /// everything else the model returns is treated as "none".
    private static let playbookIds: [String: String] = [
        "email_reply": "email-reply",
        "github_brief": "github-brief",
        "linkedin_post": "linkedin-post",
        "chat_reply": "chat-reply"
    ]

    // MARK: - Entry point (PlaybookEngine.evaluate, heuristic-miss ticks only)

    func consider(_ ctx: PlaybookContext) {
        guard !isClassifying, !PlaybookEngine.shared.isExecuting else { return }
        // No enabled trigger-fireable playbook -> a classification could never
        // fire anything; don't burn Ollama cycles on it.
        guard Self.playbookIds.values.contains(where: { PlaybookEngine.isEnabled($0) }) else { return }
        guard LocalModelEngine.shared.isAvailable else { return }
        let screenText = ctx.screenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard screenText.count >= Self.minScreenTextChars else { return }

        // Only classify when the scene actually changed…
        let signature = Self.signature(of: ctx)
        guard signature != lastSignature else { return }
        // …and at most once per interval. The signature is NOT recorded on a
        // rate-limited skip, so a new scene seen mid-cooldown still gets
        // classified once the window opens.
        guard Date().timeIntervalSince(lastClassificationAt) >= Self.minInterval else { return }

        lastSignature = signature
        lastClassificationAt = Date()
        isClassifying = true

        Task { @MainActor in
            defer { isClassifying = false }

            let raw = await LocalModelEngine.shared.generate(prompt: Self.prompt(for: ctx))
            guard let verdict = Self.parse(raw) else {
                print("[Holmes] TriggerBrain: unparseable classification — treating as none")
                return
            }
            guard verdict.opportunity != "none" else { return }
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
            guard let playbookId = Self.playbookIds[verdict.opportunity] else {
                print("[Holmes] TriggerBrain: unknown opportunity '\(verdict.opportunity)' — ignored")
                return
            }
            guard PlaybookEngine.isEnabled(playbookId) else { return }

            // Merge model entities UNDER the heuristics' — heuristic values win
            // on key collision (they came from structured extraction, not OCR
            // guesswork by a 3B model).
            var entities = verdict.entities
            for (key, value) in ctx.entities { entities[key] = value }
            let enriched = PlaybookContext(
                appName: ctx.appName,
                windowTitle: ctx.windowTitle,
                contextType: ctx.contextType,
                screenText: ctx.screenText,
                entities: entities
            )

            print("[Holmes] TriggerBrain: '\(verdict.opportunity)' (confidence \(verdict.confidence)) -> playbook '\(playbookId)'")
            PlaybookEngine.shared.fireFromTrigger(playbookId: playbookId, context: enriched)
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

    /// Robust to OCR jitter: Vision output for a visually static screen churns
    /// between ticks (recognition ordering, "2m ago" timestamps, unread counts),
    /// so hashing a raw text prefix degraded this gate to a flat 20s poll. Hash
    /// the app + window title + a COARSE bucket of the alphanumeric text volume
    /// instead — the signature only changes when the scene meaningfully does.
    private static func signature(of ctx: PlaybookContext) -> Int {
        var hasher = Hasher()
        hasher.combine(ctx.appName)
        hasher.combine(ctx.windowTitle)
        let alphanumericCount = ctx.screenText.unicodeScalars
            .lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        hasher.combine(alphanumericCount / 200)
        return hasher.finalize()
    }

    // MARK: - Classification prompt

    private static func prompt(for ctx: PlaybookContext) -> String {
        let excerpt = String(ctx.screenText.prefix(1200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You detect actionable opportunities on a user's screen for a desktop assistant.

        Active app: \(ctx.appName)
        Window title: \(ctx.windowTitle)
        Screen text (OCR, may be noisy):
        \"\"\"
        \(excerpt)
        \"\"\"

        Opportunity types:
        - "email_reply": an ACTUAL email (in Gmail, Outlook, Apple Mail, or webmail — with From/To/Subject headers or an Inbox) the user is reading or writing that deserves a reply. A terminal, code editor, chat app, PR page, or web article is NOT email — answer "none" for those.
        - "github_brief": a GitHub repository, pull request, or issue worth a briefing
        - "linkedin_post": LinkedIn content the user could turn into a post
        - "chat_reply": a chat message (iMessage/Slack/Discord) awaiting a reply
        - "none": nothing actionable

        Entity keys you may fill when confident: sender, subject, contact, repoOwner, repoName, platform.

        Respond with STRICT JSON only — no prose, no code fences:
        {"opportunity": "email_reply", "confidence": 0.85, "entities": {"sender": "Ada"}}
        """
    }

    // MARK: - Defensive parsing

    struct Verdict {
        let opportunity: String
        let confidence: Double
        let entities: [String: String]
    }

    /// Parses the model's reply. Tolerates code fences, prefix/suffix prose —
    /// including prose that itself contains braces ("I think {this} is it:
    /// {...}") by retrying from the next `{` when a candidate fails to parse —
    /// and raw newlines inside string values (spec-invalid but common 3B-model
    /// output). Any failure returns nil (= none): malformed input can only cost
    /// a missed detection, never a false fire.
    static func parse(_ raw: String) -> Verdict? {
        var searchFrom = raw.startIndex
        while let candidateRange = nextJSONObjectRange(in: raw, from: searchFrom) {
            let candidate = normalizeNewlinesInsideStrings(String(raw[candidateRange]))
            if let data = candidate.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let verdict = verdict(from: object) {
                return verdict
            }
            searchFrom = raw.index(after: candidateRange.lowerBound)
        }
        return nil
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
        guard let range = nextJSONObjectRange(in: raw, from: raw.startIndex) else { return nil }
        return String(raw[range])
    }

    /// The first balanced `{...}` at or after `from` — the scanner behind
    /// extractFirstJSONObject, generalized so parse() can retry past a
    /// non-JSON `{...}` embedded in prose.
    private static func nextJSONObjectRange(in raw: String, from: String.Index) -> Range<String.Index>? {
        guard let start = raw[from...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                escaped = false
            } else if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return start..<raw.index(after: index) }
                default: break
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }

    /// Escapes literal newlines/carriage returns/tabs that appear INSIDE string
    /// regions of a JSON candidate — spec-invalid, but small models emit them in
    /// entity values, and JSONSerialization rejects the whole object otherwise.
    private static func normalizeNewlinesInsideStrings(_ candidate: String) -> String {
        var out = String()
        out.reserveCapacity(candidate.count + 8)
        var inString = false
        var escaped = false
        for character in candidate {
            if escaped {
                escaped = false
                out.append(character)
                continue
            }
            if inString {
                switch character {
                case "\\": escaped = true; out.append(character)
                case "\"": inString = false; out.append(character)
                case "\n": out.append("\\n")
                case "\r": out.append("\\r")
                case "\t": out.append("\\t")
                default: out.append(character)
                }
            } else {
                if character == "\"" { inString = true }
                out.append(character)
            }
        }
        return out
    }
}
