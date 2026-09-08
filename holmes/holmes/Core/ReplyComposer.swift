import Foundation

// MARK: - ReplyComposer
// "Someone just messaged you — here's a reply grounded in what you were
// actually doing." This is the whole feature: the draft is written from the
// user's REAL context (the live screen + what Holmes has watched them work on
// for the last half-day), not from the model's imagination of a plausible
// human reply.
//
// Three surfaces, one path:
//   • "imessage"  — native Messages, transcript read via MessagesReader (AX)
//   • "web-chat"  — Slack/Discord/WhatsApp Web etc., transcript from LiveContext
//   • "email"     — Gmail/Mail, thread body from LiveContext
//
// Grounding sources, in order of authority:
//   1. MemoryStore.recall(topics:) — everything memory holds about the SUBJECT
//      the sender named. This is the primary path whenever their message names
//      one, and it is the only path that answers "what is holmes?" — the answer
//      lives in rows about a repo the user was reading two days ago, which the
//      user's current screen knows nothing about.
//   2. the LiveContext the caller hands in (what is on screen RIGHT NOW),
//   3. MemoryStore.findSimilar — past work that matches this specific thread,
//   4. MemoryStore.digest(hours: 12) — what the user has been doing today.
// Every row used comes back on DraftedReply so the UI can show WHY the draft
// says what it says and the dashboard can light those rows up — but the rows
// that ANSWER the message (`groundedIn`) and the rows that merely surround it
// (`background`) are returned separately, because a receipt that doesn't
// mention the subject is not a receipt for the answer.
//
// TWO QUERY PATHS, ON PURPOSE. findSimilar(activity:terms:) keys off what the
// user is DOING; recall(topics:) keys off what the other person ASKED ABOUT.
// They answer different questions and both stay wired up: a message that names
// a subject gets recall as primary evidence and the current context as colour;
// a message that names nothing ("you around?") falls back to the original path
// unchanged.
//
// MARK: - Safety boundary (enforced in code, not just in the prompt)
// ReplyComposer NEVER sends. There is deliberately no code path in this file
// that presses a Send button, posts an HTTP request to a messaging service,
// synthesizes a Return keystroke, or calls ActionExecutor. It produces text and
// hands it back. Putting that text into an input field is a separate, explicit,
// user-approved step that goes through ActionExecutor.stageTextInApp — which
// only types/pastes and likewise never presses Send. If you are adding
// functionality here and reach for "…and then send it", stop: that belongs
// behind a user action elsewhere, not inside the drafter.

@MainActor
final class ReplyComposer {
    static let shared = ReplyComposer()
    private init() {}

    // MARK: - Model

    /// The message being replied to, normalized across surfaces.
    /// `threadID` is whatever stable id the surface can offer (chat guid, Gmail
    /// thread id, channel id) — used only for logging/dedupe, never invented.
    struct IncomingMessage {
        let surface: String
        let sender: String
        let text: String
        let threadID: String?
        let app: String
    }

    /// A draft, plus the receipts. `confidence` describes how the incoming
    /// message and its context were READ (see ContextConfidence) — the UI gates
    /// factual phrasing on it, exactly like it does for LiveContext.
    ///
    /// `recallHits` and `topics` are the receipts for the topic path: what
    /// Holmes decided the sender was asking about, and which stored rows came
    /// back for it WITH the reason each one matched. The review card renders
    /// them next to the draft so the user can catch a bad recall before they
    /// send a word of it.
    ///
    /// `groundedIn` and `background` are two different claims and are kept as
    /// two different lists, because collapsing them into one produced a lie the
    /// UI could not see through: when a sender named a subject Holmes has
    /// nothing on file about, the current-context rows would slide in under
    /// "GROUNDED IN 6 MEMORIES" and an ungrounded draft would wear six receipts
    /// that had nothing to do with the question.
    ///   • `groundedIn` — rows that answer THIS message. The recalled rows when
    ///     a subject was named; the current-context rows when none was, because
    ///     then there is no subject to be off-topic about and those rows are the
    ///     grounding (that is the original findSimilar path, unchanged).
    ///   • `background` — rows that came from the current-task query while a
    ///     subject was named. Colour, never evidence, and labelled as such.
    struct DraftedReply {
        let body: String
        let groundedIn: [MemoryEvent]
        let background: [MemoryEvent]
        let confidence: ContextConfidence
        let recallHits: [MemoryStore.RecallHit]
        let topics: [String]
    }

    /// What memory holds on a subject overall — the "14 rows, Jul 12 → today"
    /// line. Mirrors MemoryStore.topicSummary's return shape.
    typealias TopicFacts = (rowCount: Int, firstSeen: Date?, lastSeen: Date?, apps: [String])

    // MARK: - Surfaces

    static let surfaceIMessage = "imessage"
    static let surfaceWebChat  = "web-chat"
    static let surfaceEmail    = "email"

    /// Output cap. A reply is short; email gets the headroom of a few
    /// paragraphs and nothing more.
    private static let maxTokens = 1200

    /// Hard cap on the drafted body, so a runaway generation can't be pasted
    /// wholesale into someone's chat box.
    private static let maxBodyCharacters = 2000

    // MARK: - Public API

    /// Contract entry point. Prefer `draftReply(to:context:)` — without a
    /// LiveContext the draft is grounded in memory alone, which is weaker.
    func draftReply(to msg: IncomingMessage) async -> DraftedReply? {
        await draftReply(to: msg, context: nil)
    }

    /// Drafts a reply grounded in the CURRENT screen context plus memory.
    /// - Parameters:
    ///   - context: what the user is doing right now. Passed in by the caller —
    ///     this class deliberately reaches for no global state other than the
    ///     memory stack (MemoryStore, and RecallSpotlight/MemoryFeed to publish
    ///     the receipts) and MessagesReader, which reads the very thread being
    ///     replied to.
    ///   - styleExemplars: things the user has actually written, used as voice
    ///     samples. Auto-filled from the iMessage thread when left empty.
    ///   - priority: `.background` for autopilot drafts (dropped with `.busy`
    ///     while an agent session owns the GPU); `.agent` when the user asked.
    /// - Returns: nil when there is nothing to reply to, the local model is not ready, or the
    ///   model's answer can't be trusted — never a placeholder draft.
    func draftReply(to msg: IncomingMessage,
                    context: LiveContext?,
                    styleExemplars: [String] = [],
                    priority: OllamaClient.Priority = .background) async -> DraftedReply? {
        let incoming = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return nil }

        // 1. TOPIC RECALL — runs FIRST, ahead of even the local-model readiness check.
        //    Extracting the subject and pulling the rows about it is entirely
        //    local (deterministic rules + SQLite), so the dashboard's REFERENCED
        //    NOW section lights up the moment the message lands, whether or not
        //    a draft can be produced afterwards.
        let recall = await recallForIncoming(incoming)
        let hits = recall.hits
        let topics = recall.topics

        guard OllamaConfig.isConfigured else {
            print("[Holmes] ReplyComposer: local model not ready — cannot draft a reply (\(OllamaConfig.lastProblem ?? "Ollama isn't ready"))")
            return nil
        }

        let surface = msg.surface.lowercased()

        // 2. The thread itself. Only iMessage needs a live read here: the web
        //    and email surfaces arrive with their transcript already captured
        //    in LiveContext.bodyText by the browser extension / AX pass.
        // The frontmost chat window is not necessarily the thread the message
        // came from (the user may have clicked elsewhere; the Holmes panel may
        // be frontmost). Only use it when its contact matches the sender.
        let thread: MessagesReader.Thread? = {
            guard surface == Self.surfaceIMessage,
                  let t = MessagesReader.shared.readFrontmostThread() else { return nil }
            let sender = msg.sender.lowercased().trimmingCharacters(in: .whitespaces)
            let contact = t.contact.lowercased().trimmingCharacters(in: .whitespaces)
            guard !sender.isEmpty, !contact.isEmpty else { return nil }
            let senderFirst = sender.split(separator: " ").first.map(String.init) ?? sender
            let contactFirst = contact.split(separator: " ").first.map(String.init) ?? contact
            return (contact.contains(sender) || sender.contains(contact) || senderFirst == contactFirst) ? t : nil
        }()

        // 3. Voice. The single most effective anti-"AI voice" measure is
        //    showing the model what this person's own sent messages look like.
        var exemplars = styleExemplars.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if exemplars.isEmpty, let thread {
            exemplars = Array(thread.messages.filter { $0.isFromMe }.map(\.text).suffix(6))
        }

        // 4. Secondary grounding: the ORIGINAL current-context path. It keeps
        //    running because "what are you working on?" is answered by the
        //    screen, not by a named subject — but when the topic path produced
        //    hits, this narrows to a couple of rows of colour so it cannot
        //    outweigh the evidence that actually answers the question.
        let terms = groundingTerms(msg: msg, incoming: incoming, context: context, thread: thread)
        let activity = (context?.activity).flatMap { $0.isEmpty ? nil : $0 } ?? "chatting"

        var related = await MemoryStore.shared.findSimilar(activity: activity, terms: terms,
                                                           limit: hits.isEmpty ? 4 : 2)
        if hits.isEmpty, related.count < 3 {
            // findSimilar pins the activity column, which is precise but can
            // come back empty when the user was coding and is now chatting —
            // the common case for "answer this question about my work".
            let searched = await MemoryStore.shared.search(terms, limit: 6)
            for event in searched where !related.contains(where: { $0.id == event.id }) {
                related.append(event)
            }
            related = Array(related.prefix(6))
        }
        // A row that is already primary evidence must never be repeated as
        // secondary — the model would read the duplicate as corroboration.
        let recalledIDs = Set(hits.map(\.event.id))
        related.removeAll { recalledIDs.contains($0.id) }

        let digest = await MemoryStore.shared.digest(hours: 12)

        // How much memory holds on the subject overall, so the draft can be
        // honest about depth ("been on it all week" vs "one row from Tuesday").
        var coverage: TopicFacts?
        if let primary = topics.first {
            coverage = await MemoryStore.shared.topicSummary(primary)
        }

        // THE SPLIT. When the sender named a subject, only the recalled rows
        // answer it — the current-context rows are background and are carried
        // separately so nothing downstream can count them as evidence about
        // that subject. When they named nothing, there is no subject to be off
        // topic about and the current-context rows ARE the grounding.
        let grounding = topics.isEmpty ? related : hits.map(\.event)
        let background = topics.isEmpty ? [] : related

        // 5. Draft.
        let system = systemPrompt(surface: surface, topics: topics, hasRecall: !hits.isEmpty)
        let user = userPrompt(msg: msg, incoming: incoming, surface: surface,
                              context: context, thread: thread, exemplars: exemplars,
                              topics: topics, hits: hits, coverage: coverage,
                              related: related, digest: digest)

        let raw: String
        do {
            raw = try await OllamaClient.shared.complete(
                system: system, user: user, maxTokens: Self.maxTokens,
                asJSON: true, schema: Self.draftSchema, priority: priority)
        } catch OllamaClient.AgentError.busy {
            print("[Holmes] ReplyComposer: the local model is busy with an agent session — draft skipped")
            return nil
        } catch {
            print("[Holmes] ReplyComposer: draft failed — \(error.localizedDescription)")
            return nil
        }

        guard let parsed = parseDraft(raw) else {
            print("[Holmes] ReplyComposer: unparseable draft response")
            return nil
        }

        let body = String(parsed.reply.prefix(Self.maxBodyCharacters))
        let confidence = draftConfidence(context: context, thread: thread, uncertain: parsed.uncertain)

        // 6. Receipts. The rows the draft leaned on light up on the dashboard
        //    while the user is reading it — recalled rows first, so the strip
        //    leads with the memories that actually answer their question. The
        //    subject and the per-row reasons are re-published with the FULL row
        //    list (recall + current context) so the label and the rows underneath
        //    it can never describe two different recalls; the background rows have
        //    no `matchedOn` and are shown with a derived reason instead — which,
        //    for a row that never mentions the subject, is RecallReason.unverified.
        //    REFERENCED NOW is "what Holmes is using right now", so background
        //    rows belong there; what they must never do is pass for evidence
        //    about the subject, which is the strip's job and is why the two lists
        //    stay separate on DraftedReply.
        var reasons: [Int64: String] = [:]
        for hit in hits { reasons[hit.event.id] = hit.matchedOn }
        RecallSpotlight.shared.spotlight(topics: topics, events: grounding + background, reasons: reasons)

        // 7. Memory: a draft Holmes wrote is itself a durable, recallable fact.
        let usedNote = parsed.usedContext.isEmpty
            ? ""
            : "\nGrounded in: " + parsed.usedContext.joined(separator: " · ")
        // What Holmes searched for and what came back, recorded verbatim: a
        // later "why did it say that?" is answerable from the row itself.
        let topicNote = topics.isEmpty
            ? ""
            : "\nAsked about: \(topics.joined(separator: ", "))"
                + "\nRecalled: " + (hits.isEmpty
                    ? "nothing on file"
                    : hits.prefix(4).map { "\($0.event.summary) [\($0.matchedOn)]" }.joined(separator: " · "))
        // Thread id is recorded verbatim when the surface supplied one, so a
        // later draft for the same conversation is recognizable in memory.
        let threadNote = msg.threadID.map { "\nThread: \($0)" } ?? ""
        let who = msg.sender.trimmingCharacters(in: .whitespaces)
        await MemoryStore.shared.record(
            kind: "draft",
            app: msg.app,
            windowTitle: context?.title ?? thread?.contact ?? who,
            activity: "reply",
            summary: "Reply drafted for \(who.isEmpty ? surface : who)"
                + (parsed.uncertain ? " (context didn't fully answer it)" : ""),
            detail: "They said: \(String(incoming.prefix(300)))\nDraft: \(String(body.prefix(600)))\(usedNote)\(topicNote)\(threadNote)")

        print("[Holmes] ReplyComposer: drafted \(body.count) chars for \(who.isEmpty ? surface : who) — \(confidence.rawValue), \(hits.count) recalled + \(related.count) context row(s)")
        return DraftedReply(body: body, groundedIn: grounding, background: background,
                            confidence: confidence, recallHits: hits, topics: topics)
    }

    // MARK: - Topic recall

    /// The inbound half of the feature: read the SUBJECT out of a message and
    /// pull everything memory holds about it, lighting up the dashboard as a
    /// side effect.
    ///
    /// Public and separate from drafting on purpose. The message watcher calls
    /// this the instant a message arrives — recall is local and costs
    /// milliseconds, so REFERENCED NOW fills in immediately, and it stays filled
    /// in even if drafting is impossible (local model not ready) or never asked for. That
    /// is the user-visible "see when your memory is re-accessed" requirement:
    /// re-access is the recall itself, not the draft that may follow it.
    ///
    /// Extraction is deterministic first — quoted terms, repo slugs, @handles,
    /// domains, "what is X" shapes, proper nouns. The model is only asked when
    /// the rules find nothing AND the message is actually a question, because a
    /// model that has to guess at a subject will happily invent one.
    @discardableResult
    func recallForIncoming(_ text: String) async -> (topics: [String], hits: [MemoryStore.RecallHit]) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return ([], []) }

        var extracted = TopicExtractor.extract(from: message)
        if extracted.isEmpty, TopicExtractor.isQuestion(message) {
            extracted = await TopicExtractor.extractWithModel(from: message)
        }
        let topics = extracted.map(\.term)
        guard !topics.isEmpty else {
            // Nothing was named, so nothing was recalled. Leave the dashboard
            // exactly as it was rather than clearing a strip the user may still
            // be reading from the previous task.
            return ([], [])
        }

        let hits = await MemoryStore.shared.recall(topics: topics)

        // EVERY recall — drafted or not, hit or miss — lights up the dashboard.
        // RecallSpotlight routes straight through MemoryFeed.noteReferenced and
        // additionally keeps the SUBJECT and each row's `matchedOn` alongside the
        // rows, so REFERENCED NOW can say what Holmes went looking for and why
        // each row answered. An empty array is the honest state when a named
        // subject turned up nothing on file.
        RecallSpotlight.shared.spotlight(topics: topics, hits: hits)

        print("[Holmes] ReplyComposer: recalled \(hits.count) row(s) for [\(topics.joined(separator: ", "))]"
              + (hits.isEmpty ? " — nothing on file" : " — top match: \(hits[0].matchedOn)"))
        return (topics, hits)
    }

    // MARK: - Confidence

    /// How trustworthy the GROUNDING was — not how good the prose is.
    ///   • an exact LiveContext (browser DOM / structured AX field) → .exact
    ///   • an AX-read Messages transcript → .structural (reliable, coarse)
    ///   • anything else → whatever the context claimed, defaulting to .inferred
    /// A model that reports `uncertain` can never come back as .exact: it just
    /// told us the context didn't answer the question, so the UI must not let
    /// the draft be presented as fact.
    private func draftConfidence(context: LiveContext?,
                                 thread: MessagesReader.Thread?,
                                 uncertain: Bool) -> ContextConfidence {
        var confidence: ContextConfidence
        if let context, context.confidence == .exact {
            confidence = .exact
        } else if thread != nil {
            confidence = .structural
        } else {
            confidence = context?.confidence ?? .inferred
        }
        if uncertain, confidence == .exact { confidence = .structural }
        return confidence
    }

    // MARK: - Grounding terms

    /// The search key for memory: the words in the message plus the identifying
    /// words of the current screen. Deliberately term-based — MemoryStore's
    /// similarity filter drops generic words itself.
    private func groundingTerms(msg: IncomingMessage,
                                incoming: String,
                                context: LiveContext?,
                                thread: MessagesReader.Thread?) -> String {
        var parts: [String] = [incoming, msg.sender]
        if let context {
            parts.append(context.title)
            parts.append(context.headline)
            parts.append(contentsOf: context.entities.values)
            if let site = context.site { parts.append(site) }
        }
        if let thread {
            parts.append(thread.contact)
            // Only the other side's recent lines: the user's own sent text is a
            // voice sample, not a description of the work.
            parts.append(contentsOf: thread.messages.filter { !$0.isFromMe }.map(\.text).suffix(4))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Prompts

    private func systemPrompt(surface: String, topics: [String], hasRecall: Bool) -> String {
        let surfaceRule: String
        switch surface {
        case Self.surfaceEmail:
            surfaceRule = "This is an EMAIL. Write a normal email body — greeting only if the thread uses one, no subject line, no signature block (the user's client adds theirs)."
        case Self.surfaceWebChat:
            surfaceRule = "This is a CHAT message (Slack/Discord/web chat). One to four sentences. No greeting, no sign-off — it's a chat."
        default:
            surfaceRule = "This is an iMessage. Write it the way people text: short, lowercase if that matches their samples, no greeting, no sign-off, no emoji unless their samples use emoji."
        }

        // The topic block is only added when the sender actually named a
        // subject, so a plain "you around?" gets the original prompt verbatim.
        var topicRule = ""
        if let subject = topics.first {
            let named = topics.count > 1
                ? "\(subject) (also: \(topics.dropFirst().joined(separator: ", ")))"
                : subject
            topicRule = hasRecall
                ? """

                THEY ASKED ABOUT: \(named)
                • The RECALLED MEMORY section is what Holmes actually has on file about that subject. It is your PRIMARY source — answer from it and from nothing else.
                • Each recalled row says what it matched on. A row matched on an entity or a site was read from a structured field and is literal; a row matched on body text is weaker, so do not build a specific claim on it alone.
                • Answer only what the recalled rows support. If they describe the subject but not the specific thing that was asked, answer the part you have and say plainly you'd have to check the rest.
                • Do not describe the subject from your own general knowledge, even if you recognize the name. The user's memory is the only thing you know about it.
                """
                : """

                THEY ASKED ABOUT: \(named)
                • Holmes searched its memory for that subject and found NOTHING on file. Say so plainly, in the user's voice — "haven't got anything on that", "let me dig it up and get back to you". Set "uncertain": true.
                • Do not answer from your own general knowledge, and do not describe the subject from its name. You do not know what it is; saying so is the correct reply.
                """
        }

        return """
        You are Holmes, drafting a reply that the user will read, edit, and send THEMSELVES.

        \(surfaceRule)
        \(topicRule)
        GROUNDING — this is the entire point of the feature:
        • You may only use facts that appear in the RECALLED MEMORY, CONTEXT and MEMORY sections of the user's message. Those sections are the sum of what is actually known.
        • Never invent a commitment, a time, a date, a number, a name, a status, a link, or a promise on the user's behalf. If it is not in the context, it does not exist.
        • Never state that something is done, sent, fixed, shipped, booked, or scheduled unless the context says so in those terms.
        • If the context does NOT answer what the other person asked, say so plainly in the draft — a short honest line like "let me check and get back to you" is a correct answer. Set "uncertain": true when you do this. Fabricating a confident answer is the single worst outcome.
        • Do not answer with details from the model's general knowledge dressed up as the user's situation.

        VOICE:
        • Match the user's own writing in the STYLE SAMPLES — their length, punctuation, capitalization, and formality. Copy the register, never the content.
        • Length is a fact about people, not a budget: write what a real person would actually type back to this message. If two lines answer it, write two lines. Never pad a reply with everything you were told.
        • No assistant throat-clearing ("Sure!", "Happy to help!", "I hope this finds you well"). No em-dashes as a tic. Write like the user, not like a chatbot.
        • Never mention Holmes, AI, memory, drafting, or that the reply was generated — say the thing, not where it came from.

        DELIVERY:
        • You are drafting only. Holmes NEVER sends, posts, or submits anything — the user reviews every word and sends it themselves. Do not write as if the message has already gone out, and do not add anything like "sent via".

        Reply with ONLY this JSON object and nothing else:
        {"reply": "the message text, ready to paste", "usedContext": ["short phrase naming each context or memory item you actually relied on"], "uncertain": true or false}
        """
    }

    private func userPrompt(msg: IncomingMessage,
                            incoming: String,
                            surface: String,
                            context: LiveContext?,
                            thread: MessagesReader.Thread?,
                            exemplars: [String],
                            topics: [String],
                            hits: [MemoryStore.RecallHit],
                            coverage: TopicFacts?,
                            related: [MemoryEvent],
                            digest: String) -> String {
        var sections: [String] = []

        let who = msg.sender.isEmpty ? "someone" : msg.sender
        sections.append("""
        MESSAGE TO REPLY TO
        Surface: \(surface)\(msg.app.isEmpty ? "" : " (in \(msg.app))")
        From: \(who)
        Text: \(incoming)
        """)

        // The recalled rows go FIRST — ahead of the thread, ahead of the screen.
        // Ordering is not cosmetic in a prompt: the evidence that answers the
        // question has to be read before the colour that surrounds it.
        if let subject = topics.first {
            if hits.isEmpty {
                sections.append("""
                RECALLED MEMORY — SEARCHED FOR "\(subject)"
                (no rows. Holmes has nothing on file about this subject. Say so — do not describe it from the name.)
                """)
            } else {
                var lines = [MemoryStore.formatRecall(hits)]
                if let coverage, coverage.rowCount > 0 {
                    lines.append(Self.coverageLine(subject: subject, coverage: coverage))
                }
                sections.append("""
                RECALLED MEMORY — WHAT HOLMES HAS ON FILE ABOUT "\(subject)" (PRIMARY SOURCE)
                Each line ends with what it matched on: an entity or site match was read from a structured field and is literal; "summary text" is Holmes's own deterministic note; "body text" is the weakest and may be a passing mention.
                \(lines.joined(separator: "\n"))
                """)
            }
        }

        if let thread, !thread.messages.isEmpty {
            // Oldest→newest, as rendered. "Me" is the user.
            let transcript = thread.messages.map { m in
                "\(m.isFromMe ? "Me" : (m.sender.isEmpty ? who : m.sender)): \(m.text)"
            }.joined(separator: "\n")
            sections.append("""
            THREAD (read from the Messages window, oldest first)
            \(transcript)
            """)
            if !thread.inputFieldValue.isEmpty {
                sections.append("""
                THE USER HAS ALREADY STARTED TYPING (continue in this direction, keep their words):
                \(thread.inputFieldValue)
                """)
            }
        }

        if let context {
            var lines: [String] = [
                "What they're doing: \(context.headline)",
                "App: \(context.app)\(context.site.map { " · \($0)" } ?? "")",
                "Activity: \(context.activity)",
                "Read via: \(context.source.rawValue) (\(context.confidence.rawValue))"
            ]
            if !context.title.isEmpty { lines.append("Window/page: \(context.title)") }
            if !context.detail.isEmpty { lines.append("Specifics:\n\(context.detail)") }
            if !context.entities.isEmpty {
                lines.append("Entities: " + context.entities
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", "))
            }
            if let selection = context.selection, !selection.isEmpty {
                lines.append("Selected text: \(String(selection.prefix(400)))")
            }
            if !context.bodyText.isEmpty {
                lines.append("Page/thread text:\n\(String(context.bodyText.prefix(2500)))")
            }
            if !context.isTrustworthy {
                // Anti-hallucination: an .inferred/.structural read may be
                // garbled, so the model must not quote it as if it were literal.
                lines.append("WARNING: this context was NOT read exactly (confidence: \(context.confidence.rawValue)). Treat every specific in it as possibly misread — do not quote numbers, names, or code from it as fact.")
            }
            sections.append("CONTEXT — WHAT THE USER IS DOING RIGHT NOW\n" + lines.joined(separator: "\n"))
        } else {
            sections.append("CONTEXT — WHAT THE USER IS DOING RIGHT NOW\n(unavailable — Holmes could not read the screen. Rely on memory only, and do not assert anything about the user's current work.)")
        }

        if !related.isEmpty {
            // Secondary by construction: these rows matched the CURRENT task,
            // not the subject that was asked about, so they are labelled as
            // background rather than as an answer.
            let heading = hits.isEmpty
                ? "MEMORY — RELATED WORK HOLMES HAS OBSERVED"
                : "MEMORY — RELATED WORK (BACKGROUND ONLY — this did not come from searching for what they asked about)"
            sections.append(heading + "\n" + MemoryStore.format(related))
        }
        if !digest.isEmpty {
            sections.append("MEMORY — THE LAST 12 HOURS\n\(digest)")
        }
        if !exemplars.isEmpty {
            sections.append("STYLE SAMPLES — THINGS THE USER ACTUALLY WROTE\n"
                            + exemplars.map { "· \($0)" }.joined(separator: "\n"))
        } else {
            sections.append("STYLE SAMPLES\n(none available — write plainly and briefly, and do not perform enthusiasm.)")
        }

        sections.append("Draft the reply now. JSON only.")
        return sections.joined(separator: "\n\n")
    }

    /// How much memory holds on the subject, stated as a count and a span so the
    /// draft can be honest about depth. It ends with an explicit fence: the
    /// model sees a NUMBER of rows but only the top handful of rows themselves,
    /// and must not treat the count as licence to assert anything the listed
    /// rows don't say.
    private static func coverageLine(subject: String, coverage: TopicFacts) -> String {
        var parts = ["Coverage: \(coverage.rowCount) stored row\(coverage.rowCount == 1 ? "" : "s") mention \"\(subject)\""]
        if let first = coverage.firstSeen, let last = coverage.lastSeen {
            let span = Calendar.current.isDate(first, inSameDayAs: last)
                ? Self.dayFormatter.string(from: last)
                : "\(Self.dayFormatter.string(from: first)) → \(Self.dayFormatter.string(from: last))"
            parts.append("spanning \(span)")
        }
        if !coverage.apps.isEmpty {
            parts.append("seen in \(coverage.apps.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
            + ". Only the rows listed above are visible to you — the count tells you how much or how little exists, and nothing else."
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Response parsing

    /// Tolerant JSON extraction: the model is asked for a bare object, but a
    /// stray code fence or a leading sentence must not cost the user a draft.
    /// The reply's shape, enforced by Ollama's schema-constrained `format`
    /// rather than by asking the model to "return JSON". `uncertain` is part of
    /// the contract precisely because the model must have a way to say the
    /// context didn't answer the question — see draftConfidence.
    private static let draftSchema: [String: Any] = OllamaClient.objectSchema([
        "reply": [
            "type": "string",
            "description": "The reply body, ready to paste. No greeting boilerplate, no signature, no quotes around it."
        ],
        "usedContext": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Short labels for the specific facts from CONTEXT/MEMORY this draft leans on. Empty when it leans on none."
        ],
        "uncertain": [
            "type": "boolean",
            "description": "True when the context did not actually answer what was asked and the draft says so instead of guessing."
        ]
    ])

    private func parseDraft(_ raw: String) -> (reply: String, usedContext: [String], uncertain: Bool)? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end
        else { return nil }

        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var reply = (object["reply"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Some responses wrap the body in quotes on top of the JSON string.
        if reply.count > 1, reply.hasPrefix("\""), reply.hasSuffix("\"") {
            reply = String(reply.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !reply.isEmpty else { return nil }

        let used = (object["usedContext"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let uncertain = (object["uncertain"] as? Bool)
            ?? ((object["uncertain"] as? NSNumber)?.boolValue ?? false)

        return (reply, used, uncertain)
    }
}
