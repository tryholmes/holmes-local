import Foundation

// MARK: - TopicExtractor
// "What are they actually asking ABOUT?"
//
// This is the front half of the topic-keyed recall path. MemoryStore.findSimilar
// answers "what past work resembles what the user is doing RIGHT NOW"; that keys
// off the user's own screen. This keys off SOMEONE ELSE'S MESSAGE: when a text
// arrives saying "hey what is holmes?", the subject of the question — "holmes" —
// is the query, and the user's current screen is irrelevant to it.
//
// DETERMINISTIC FIRST, always. Quoted phrases, owner/name repo slugs, @handles,
// hostnames, #482-style references, "what/who/how is X" patterns and proper nouns
// are all read straight out of the text by rules in this file. That is not a
// cost optimization dressed up as a principle:
//   • it is instant, so recall can run the moment a message lands rather than a
//     network round-trip later, and
//   • a rule can only ever return words that are literally in the message, so it
//     cannot invent a subject the sender never named — which is exactly the
//     failure mode that would poison recall with confident nonsense.
// The model is called ONLY when the deterministic pass finds nothing usable and
// the message is actually a question (see ReplyComposer). It is asked to pick
// words out of the text, never to guess at what the sender "meant".
//
// Nothing here reads the screen, touches memory, or sends anything. It is a pure
// text → [Topic] function plus one narrowly-scoped model fallback.

enum TopicExtractor {

    // MARK: - Model

    /// WHERE a topic came from. Two jobs: it ranks candidates (a quoted phrase
    /// beats a stray capitalized word), and it gives the UI a plain-English
    /// reason so the user can see why Holmes searched for what it searched for.
    enum Origin: String {
        case quoted
        case repoSlug
        case handle
        case domain
        case reference        // "#482", "PR 482"
        case questionSubject  // "what is X", "tell me about X"
        case properNoun
        case model            // the fallback pass, only when rules found nothing

        /// Higher wins when two passes yield the same term, and orders the list.
        var priority: Int {
            switch self {
            case .quoted:          return 90
            case .repoSlug:        return 85
            case .handle:          return 80
            case .domain:          return 75
            case .reference:       return 70
            case .questionSubject: return 65
            case .properNoun:      return 40
            case .model:           return 30
            }
        }

        var label: String {
            switch self {
            case .quoted:          return "quoted in their message"
            case .repoSlug:        return "repo named in their message"
            case .handle:          return "@handle in their message"
            case .domain:          return "site named in their message"
            case .reference:       return "reference in their message"
            case .questionSubject: return "the subject of their question"
            case .properNoun:      return "a name in their message"
            case .model:           return "subject read from their message"
            }
        }
    }

    /// One thing the sender named. `term` is verbatim from their text (minus
    /// punctuation) — never a synonym, never an expansion.
    struct Topic: Hashable {
        let term: String
        let origin: Origin

        /// Why Holmes is searching for this. Shown next to the recalled rows.
        var reason: String { origin.label }
    }

    // MARK: - Tuning

    /// Longest message we bother scanning. A pasted wall of text is not a
    /// question about a subject, and scanning it would just harvest noise.
    private static let maxScanLength = 2000

    /// Default cap on returned topics. Recall widens each one into an FTS OR
    /// clause, so more than a handful stops being a query and starts being a
    /// dragnet.
    private static let defaultLimit = 5

    // MARK: - Public API — deterministic pass

    /// Pulls every subject the text NAMES, best-evidence first. Returns [] when
    /// the message names nothing — an honest empty result, so the caller can
    /// decide whether the model fallback is worth it.
    static func extract(from text: String, limit: Int = defaultLimit) -> [Topic] {
        let source = String(text.prefix(maxScanLength))
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var candidates: [Topic] = []
        func add(_ raw: String, _ origin: Origin) {
            guard let term = normalizeTerm(raw, origin: origin) else { return }
            candidates.append(Topic(term: term, origin: origin))
        }

        // 1 — Quoted spans. Someone who put it in quotes is naming it exactly.
        //     Only double/smart quotes: a single quote is an apostrophe far more
        //     often than it is a quotation, and "don't ... won't" would otherwise
        //     be read as a quoted phrase.
        for span in captures(in: source, pattern: "[\"“”]([^\"“”]{2,60})[\"“”]") { add(span, .quoted) }
        for span in captures(in: source, pattern: "`([^`]{2,60})`") { add(span, .quoted) }

        // 2 — URLs first, so the host and the repo path are read from the link
        //     rather than being mangled by the bare-slug rule below.
        for url in matches(in: source, pattern: "https?://[^\\s<>()\\[\\]\"']+") {
            let host = MemoryStore.normalizedSite(url)
            if !host.isEmpty { add(host, .domain) }
            for slug in repoSlugs(inURLPath: url) {
                add(slug, .repoSlug)
                if let name = slug.split(separator: "/").last { add(String(name), .repoSlug) }
            }
        }

        // 3 — Bare owner/name slugs ("tryholmes/holmes"). Both the full slug and
        //     the bare name are emitted: memory rows phrase the same repo both
        //     ways ("Reviewing PR #482 in tryholmes/holmes", "the holmes repo").
        //     `isRepoShaped` is what keeps ordinary slashed English out.
        for pair in capturePairs(in: source,
                                 pattern: "(?<![\\w/@.])([A-Za-z][A-Za-z0-9._-]{0,38})/([A-Za-z][A-Za-z0-9._-]{0,38})(?![\\w/])")
        where isRepoShaped(owner: pair.0, name: pair.1) {
            add("\(pair.0)/\(pair.1)", .repoSlug)
            // The bare half only when it is long enough to be a name in its own
            // right. Unlike the URL path above, nothing here has confirmed this
            // is a repository at all — a short right-hand half is far more
            // likely to be a word than a project, and at .repoSlug priority it
            // would outrank the actual subject of the sentence.
            if pair.1.count >= 4 { add(pair.1, .repoSlug) }
        }

        // 4 — @handles and bare hostnames.
        for handle in captures(in: source, pattern: "(?<![\\w])@([A-Za-z0-9_.-]{2,30})") { add(handle, .handle) }
        for host in matches(in: source,
                            pattern: "(?<![\\w@/.])[A-Za-z0-9][A-Za-z0-9-]{0,40}(?:\\.[A-Za-z0-9-]{1,30})+(?![\\w])")
        where hasKnownTLD(host) {
            add(MemoryStore.normalizedSite(host), .domain)
        }

        // 5 — Issue/PR references. "#482" and "PR 482" both end up as "#482",
        //     which recall tokenizes to "482" for the FTS pass and matches
        //     literally against a summary that reads "Reviewing PR #482 …".
        for number in captures(in: source, pattern: "(?<![\\w])#(\\d{1,6})(?![\\w])") { add("#\(number)", .reference) }
        for number in captures(in: source,
                               pattern: "(?i)(?<![\\w])(?:pr|pull request|issue|ticket)\\s*#?\\s*(\\d{1,6})(?![\\w])") {
            add("#\(number)", .reference)
        }

        // 6 — The grammatical subject of a question. THIS is the rule that
        //     carries "hey what is holmes?" — no quotes, no capitals, nothing
        //     else in the sentence to go on.
        for phrase in questionSubjects(in: source) {
            add(phrase, .questionSubject)
            // A multi-word subject also contributes its distinctive words, since
            // memory may have filed the same thing under one of them alone.
            let words = significantWords(in: phrase)
            if words.count > 1 {
                for word in words { add(word, .questionSubject) }
            }
        }

        // 7 — Proper nouns. Weakest deterministic signal, and last, so a real
        //     subject always outranks a mid-sentence capital.
        for name in properNouns(in: source) { add(name, .properNoun) }

        return rank(candidates, limit: limit)
    }

    /// Is "owner/name" a repository slug, or is it just English with a slash in
    /// it? A false positive here is not one harmless extra term: `.repoSlug`
    /// outranks the actual subject of the question, so admitting "and/or" makes
    /// "or" the TOP topic — and recall then runs FTS `"or"` plus a
    /// `entities_json LIKE '%or%'` that matches keys like "author" on nearly
    /// every row, pulls the 200 most recent, and hands the user a dragnet
    /// labelled as the memories the draft was built on.
    ///
    /// Four literal tests, no cleverness:
    ///   1. both halves at least 3 characters — kills "and/or", "he/she", "km/h"
    ///   2. neither half a stopword or a word people actually slash together —
    ///      kills "read/write", "input/output", "client/server"
    ///   3. at least one half that reads as an IDENTIFIER rather than a word: it
    ///      carries a digit, a hyphen, a dot or an underscore, or it is 5+
    ///      characters ("tryholmes/holmes" passes on the owner)
    ///   4. no hostname on the left — "github.com/holmes" is a URL fragment and
    ///      was already handled by the URL rule above
    /// A miss costs one topic and the question-subject rule usually catches the
    /// same word anyway; a false positive costs the whole recall.
    static func isRepoShaped(owner: String, name: String) -> Bool {
        guard !owner.contains(".") else { return false }
        let left = owner.lowercased()
        let right = name.lowercased()
        guard left.count >= 3, right.count >= 3 else { return false }
        for half in [left, right] {
            guard !stopTerms.contains(half), !slashedEnglish.contains(half) else { return false }
        }
        return [left, right].contains { half in
            half.count >= 5 || half.contains(where: { $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        }
    }

    /// Words that show up on either side of a slash in ordinary writing. Not a
    /// dictionary and not trying to be — it only has to cover the pairs people
    /// actually type, because everything else is caught by the length and
    /// identifier tests in `isRepoShaped`.
    private static let slashedEnglish: Set<String> = [
        "and", "or", "not", "but", "nor", "per", "via", "vs", "versus", "aka",
        "yes", "no", "off", "out", "up", "down", "in", "on", "to", "from",
        "read", "write", "input", "output", "before", "after", "start", "stop",
        "open", "close", "copy", "paste", "cut", "undo", "redo", "login",
        "logout", "signin", "signup", "http", "https", "true", "false",
        "pass", "fail", "success", "failure", "win", "lose", "buy", "sell",
        "pros", "cons", "client", "server", "frontend", "backend", "front",
        "back", "left", "right", "top", "bottom", "high", "low", "old", "new",
        "big", "small", "hot", "cold", "black", "white", "male", "female",
        "his", "hers", "him", "she", "her", "they", "them", "one", "two",
        "each", "both", "either", "any", "all", "etc", "date", "time", "day",
        "week", "month", "year", "hour", "hours", "min", "mins", "sec", "secs",
        "sqft", "mph", "kmh", "kph", "lbs", "kgs", "oz", "unit", "units",
        "question", "answer", "name", "value", "key", "owner", "user", "admin"
    ]

    /// True when the text reads as a question — the gate the caller uses before
    /// spending a model call on extraction. Deliberately generous: a missing
    /// question mark is the norm in texting.
    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("?") { return true }
        // Leading interrogative, allowing one filler opener ("hey", "yo", "so").
        var words = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        if let first = words.first, Self.openers.contains(first) { words.removeFirst() }
        guard let lead = words.first else { return false }
        if Self.interrogatives.contains(lead) { return true }
        // "tell me about x", "any idea what x is"
        return trimmed.contains("tell me about")
            || trimmed.contains("any idea")
            || trimmed.contains("what's the deal")
            || trimmed.contains("whats the deal")
    }

    // MARK: - Public API — model fallback

    /// Last resort: ask the local model to name the subject when the rules found none.
    ///
    /// The prompt's whole job is to keep this from becoming an invention step —
    /// the model may only return words that appear in the message, and must
    /// return an empty list when the message names no subject at all. Anything
    /// it returns that is NOT present in the original text is dropped here, in
    /// code, so the contract is enforced rather than requested.
    static func extractWithModel(from text: String, limit: Int = 3) async -> [Topic] {
        let source = String(text.prefix(maxScanLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, OllamaConfig.isConfigured else { return [] }

        let system = """
        You extract the SUBJECT of a message so a memory database can be searched for it.

        Rules:
        • Return only words or short phrases that literally appear in the message. Copy them verbatim.
        • Return the thing being ASKED ABOUT — a project, product, person, company, file, repo, place or event — not the verbs, not the pleasantries, not the sender's name.
        • Never expand an abbreviation, never translate, never guess at what they "meant", never add a subject that is not in the text.
        • If the message names no subject (small talk, a greeting, a yes/no), return an empty list. An empty list is a correct answer and is much better than a guess.
        • At most \(limit) items, most important first.
        """
        let user = """
        MESSAGE
        \(source)

        List the subject(s) this message is asking about.
        """

        let raw: String
        do {
            raw = try await OllamaClient.shared.complete(
                system: system, user: user, maxTokens: 300,
                asJSON: true, schema: Self.topicSchema)
        } catch {
            print("[Holmes] TopicExtractor: model extraction failed — \(error.localizedDescription)")
            return []
        }

        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["topics"] as? [String]
        else { return [] }

        // Verbatim check: the model's answer has to be IN the message. This is
        // what stops a plausible-sounding hallucinated subject from being turned
        // into a memory query whose results would look like corroboration.
        let haystack = source.lowercased()
        var topics: [Topic] = []
        for candidate in list {
            guard let term = normalizeTerm(candidate, origin: .model) else { continue }
            guard haystack.contains(term.lowercased()) else {
                print("[Holmes] TopicExtractor: dropped \"\(term)\" — not present in the message")
                continue
            }
            topics.append(Topic(term: term, origin: .model))
        }
        return rank(topics, limit: limit)
    }

    private static let topicSchema: [String: Any] = OllamaClient.objectSchema([
        "topics": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Subjects named in the message, copied verbatim from it, most important first. Empty when the message names no subject."
        ]
    ])

    // MARK: - Ranking

    /// Dedupes case-insensitively (keeping the strongest origin for a term) and
    /// returns the best `limit`, strongest evidence first. Ties keep discovery
    /// order, so the result is stable for identical input.
    private static func rank(_ candidates: [Topic], limit: Int) -> [Topic] {
        var bestByTerm: [String: (topic: Topic, order: Int)] = [:]
        for (index, candidate) in candidates.enumerated() {
            let key = candidate.term.lowercased()
            if let existing = bestByTerm[key],
               existing.topic.origin.priority >= candidate.origin.priority { continue }
            bestByTerm[key] = (candidate, bestByTerm[key]?.order ?? index)
        }
        return bestByTerm.values
            .sorted { a, b in
                if a.topic.origin.priority != b.topic.origin.priority {
                    return a.topic.origin.priority > b.topic.origin.priority
                }
                return a.order < b.order
            }
            .prefix(max(1, limit))
            .map(\.topic)
    }

    // MARK: - Term normalization

    /// Cleans one raw candidate into a searchable term, or rejects it.
    /// Rejection is the common case and is deliberately aggressive: a junk term
    /// costs a wasted OR clause in recall and, worse, can surface an unrelated
    /// memory that the draft would then treat as an answer.
    private static func normalizeTerm(_ raw: String, origin: Origin) -> String? {
        var term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping punctuation and trailing possessives/plurals-of-name.
        term = term.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"“”'`()[]{}<>,.;:!?—–-"))
        if term.lowercased().hasSuffix("'s") || term.lowercased().hasSuffix("’s") {
            term = String(term.dropLast(2))
        }
        term = term.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard term.count >= 2, term.count <= 60 else { return nil }
        // Must carry at least one letter or digit — "#" and "—" are not subjects.
        guard term.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil else { return nil }

        let lower = term.lowercased()
        // A reference term ("#482") is meaningful precisely because it is short
        // and numeric, so it skips the vocabulary filters below.
        if origin == .reference { return term }
        guard !stopTerms.contains(lower) else { return nil }
        // Every word being a stopword means the phrase says nothing searchable
        // ("that thing", "your stuff").
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty, !words.allSatisfy({ stopTerms.contains($0) || $0.count < 2 }) else { return nil }
        // Single bare words shorter than 3 characters are noise unless the
        // sender pointed at them EXPLICITLY — quotes and @handles are the
        // sender's own act of naming, and nothing else is. `.repoSlug` is
        // deliberately NOT waived here: a 2-character half of a slash pair is a
        // word ("or", "h"), and promoting it to the top-priority origin is
        // exactly how a two-letter term became the query memory was searched on.
        if words.count == 1, term.count < 3,
           origin != .quoted, origin != .handle { return nil }
        return term
    }

    /// Words that can never be a subject on their own.
    private static let stopTerms: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its", "there",
        "here", "thing", "things", "stuff", "something", "anything", "everything",
        "nothing", "someone", "anyone", "everyone", "you", "your", "yours", "ur",
        "me", "my", "mine", "we", "our", "they", "them", "their", "he", "she",
        "him", "her", "his", "hers", "who", "what", "whats", "which", "where",
        "when", "why", "how", "hows", "is", "are", "was", "were", "be", "been",
        "am", "do", "does", "did", "done", "can", "could", "would", "should",
        "will", "shall", "may", "might", "must", "have", "has", "had", "get",
        "got", "going", "go", "goes", "make", "made", "just", "now", "then",
        "today", "tomorrow", "yesterday", "tonight", "week", "weekend", "month",
        "year", "time", "day", "days", "sure", "okay", "ok", "yeah", "yes", "no",
        "nope", "yep", "thanks", "thank", "please", "sorry", "hey", "hi", "hello",
        "yo", "sup", "lol", "haha", "btw", "idk", "imo", "tbh", "much", "many",
        "more", "less", "any", "some", "all", "good", "bad", "great", "cool",
        "nice", "well", "work", "working", "up", "down", "out", "about", "with",
        "for", "from", "into", "onto", "over", "under", "again", "still", "like",
        "want", "need", "think", "know", "see", "look", "tell", "say", "said",
        "message", "text", "call", "email", "reply", "answer", "question",
        "thoughts", "update", "news", "deal", "story", "status", "point", "idea"
    ]

    /// Sentence openers skipped when deciding whether a message is a question.
    private static let openers: Set<String> = [
        "hey", "hi", "hello", "yo", "so", "ok", "okay", "um", "uh", "well",
        "also", "and", "but", "quick", "sorry", "btw", "lol"
    ]

    private static let interrogatives: Set<String> = [
        "what", "whats", "what's", "who", "whos", "who's", "how", "hows", "how's",
        "why", "when", "where", "which", "is", "are", "was", "were", "do", "does",
        "did", "can", "could", "would", "should", "any", "have", "has", "anyone"
    ]

    /// Hostname suffixes accepted as a real domain, so "e.g" and "v1.2" aren't
    /// filed as sites. Not exhaustive by design — a miss costs one topic, a
    /// false positive costs a garbage query.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "co", "app", "so", "sh", "xyz",
        "gg", "me", "tv", "fm", "cloud", "tech", "edu", "gov", "uk", "us", "ca",
        "de", "fr", "jp", "in", "eu", "info", "biz", "site", "page", "run"
    ]

    private static func hasKnownTLD(_ host: String) -> Bool {
        guard let tld = host.split(separator: ".").last else { return false }
        return knownTLDs.contains(String(tld).lowercased())
    }

    // MARK: - Question subjects

    /// Sentence shapes whose capture group is the thing being asked about. The
    /// character class excludes sentence punctuation, so a capture stops at the
    /// end of the clause without needing a second trim pass.
    private static let subjectPatterns: [String] = [
        // "what is holmes", "who are the folks", "which is tryholmes/holmes"
        "(?i)\\b(?:what|who|which)\\s+(?:is|are|was|were)\\s+(?:(?:the|a|an|this|that|your|ur|his|her|their)\\s+)?([\\p{L}\\p{N}@#._/][\\p{L}\\p{N}@#._/'’ -]{0,48})",
        // contraction form with no separate verb: "whats holmes", "who's sarah"
        "(?i)\\b(?:whats|what's|whos|who's|hows|how's)\\s+(?:(?:the|a|an|this|that|your|ur)\\s+)?([\\p{L}\\p{N}@#._/][\\p{L}\\p{N}@#._/'’ -]{0,48})",
        // "tell me about holmes", "heard about holmes", "asking about holmes"
        "(?i)\\b(?:tell\\s+me\\s+about|talking\\s+about|hear(?:d)?\\s+about|know\\s+about|ask(?:ing)?\\s+about|curious\\s+about|about)\\s+(?:(?:the|a|an|this|that|your|ur)\\s+)?([\\p{L}\\p{N}@#._/][\\p{L}\\p{N}@#._/'’ -]{0,48})",
        // "how is holmes going", "how did the holmes thing go"
        "(?i)\\bhow\\s+(?:is|are|was|were|did|does)\\s+(?:(?:the|a|an|this|that|your|ur)\\s+)?([\\p{L}\\p{N}@#._/][\\p{L}\\p{N}@#._/'’ -]{0,48})",
        // "what's the deal with holmes", "any update on holmes"
        "(?i)\\b(?:deal|story|status|update|news|latest)\\s+(?:with|on|about)\\s+(?:(?:the|a|an|this|that|your|ur)\\s+)?([\\p{L}\\p{N}@#._/][\\p{L}\\p{N}@#._/'’ -]{0,48})"
    ]

    /// Trailing words that are grammar, not subject — "how is holmes GOING".
    private static let trailingFiller: Set<String> = [
        "going", "coming", "doing", "happening", "again", "now", "today", "lately",
        "these", "days", "then", "though", "tho", "btw", "actually", "really",
        "exactly", "anyway", "anyways", "yet", "still", "about", "like", "for",
        "with", "and", "or", "so", "up", "at", "in", "on", "to", "of", "thing",
        "stuff", "project", "one", "ok", "okay", "lol", "haha", "please", "pls"
    ]

    private static func questionSubjects(in text: String) -> [String] {
        var found: [String] = []
        for pattern in subjectPatterns {
            for capture in captures(in: text, pattern: pattern) {
                guard let phrase = tidySubject(capture) else { continue }
                found.append(phrase)
            }
        }
        return found
    }

    /// Cuts a captured clause down to the noun phrase: stop at a conjunction,
    /// drop trailing grammar words, and refuse a phrase that is nothing but
    /// filler ("what is going on" must not become the topic "going on").
    private static func tidySubject(_ capture: String) -> String? {
        var words = capture
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map(String.init)

        // Everything after a conjunction belongs to a different clause.
        // "and/or" is listed literally because it is written as one token and
        // would otherwise sail past a word-by-word conjunction test.
        if let cut = words.firstIndex(where: { conjunctions.contains(bareWord($0)) }) {
            words = Array(words[..<cut])
        }
        while let last = words.last,
              trailingFiller.contains(bareWord(last)) {
            words.removeLast()
        }
        // And the same from the front — "what's the DEAL WITH holmes" captures
        // the framing along with the subject, and "deal with holmes" is not a
        // thing memory has ever recorded.
        while let first = words.first, leadingFiller.contains(bareWord(first)) {
            words.removeFirst()
        }
        // A subject is a name, not a sentence.
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let phrase = words.joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    /// Framing words a question puts IN FRONT of its subject. Kept short and
    /// unambiguous on purpose: "project" is not here, because "project ledger"
    /// is a name and trimming it would search for the wrong thing.
    private static let leadingFiller: Set<String> = [
        "deal", "story", "status", "update", "news", "latest", "thing", "stuff",
        "about", "with", "on", "of", "the", "a", "an", "up", "and", "or"
    ]

    /// Words that end the noun phrase because what follows them is a different
    /// clause.
    private static let conjunctions: Set<String> = [
        "and", "or", "and/or", "but", "so", "because", "if", "when", "while"
    ]

    /// A word with its trailing sentence punctuation removed, lowercased.
    private static func bareWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }

    /// Words inside a phrase worth searching for on their own.
    ///
    /// Slash-joined tokens are held to the same bar as a bare slug: "and/or"
    /// reaching recall as a term is a dragnet, because MemoryStore's multi-word
    /// containment test then matches any row whose prose happens to contain both
    /// halves — which is nearly all of them.
    private static func significantWords(in phrase: String) -> [String] {
        phrase.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "." && $0 != "-" })
            .map(String.init)
            .filter { word in
                guard word.count >= 3, !stopTerms.contains(word) else { return false }
                guard let slash = word.firstIndex(of: "/") else { return true }
                return isRepoShaped(owner: String(word[..<slash]),
                                    name: String(word[word.index(after: slash)...]))
            }
    }

    // MARK: - Proper nouns

    /// Capitalized tokens and acronyms. Sentence-initial words are admitted only
    /// when they aren't a common opener, because "Hey" and "Thanks" start half
    /// the messages a person receives and neither is a subject.
    private static func properNouns(in text: String) -> [String] {
        var names: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences {
            let words = sentence
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" || $0 == ":" })
                .map(String.init)
            guard words.count >= 2 else { continue }
            for (index, word) in words.enumerated() {
                let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`()[]{}<>,.;:!?—–"))
                guard let first = bare.first else { continue }
                // ALL-CAPS acronyms ("AWS", "PR") count anywhere in the sentence.
                let isAcronym = bare.count >= 2 && bare.count <= 6
                    && bare.allSatisfy { $0.isUppercase || $0.isNumber }
                guard isAcronym || (first.isUppercase && bare.dropFirst().contains(where: { $0.isLowercase })) else { continue }
                if index == 0, openers.contains(bare.lowercased()) { continue }
                names.append(bare)
            }
        }
        return names
    }

    // MARK: - Regex helpers

    /// All full matches of `pattern`.
    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// First capture group of every match.
    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges >= 2, match.range(at: 1).location != NSNotFound else { return nil }
                return ns.substring(with: match.range(at: 1))
            }
    }

    /// First two capture groups of every match — the owner/name shape.
    private static func capturePairs(in text: String, pattern: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges >= 3,
                      match.range(at: 1).location != NSNotFound,
                      match.range(at: 2).location != NSNotFound else { return nil }
                return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
            }
    }

    /// "https://github.com/tryholmes/holmes/pull/482" → ["tryholmes/holmes"].
    /// Only the first two path segments, and only for hosts that actually use
    /// owner/name addressing — elsewhere a two-segment path means nothing.
    private static func repoSlugs(inURLPath url: String) -> [String] {
        let host = MemoryStore.normalizedSite(url)
        guard ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"].contains(host) else { return [] }
        var rest = url
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        guard let slash = rest.firstIndex(of: "/") else { return [] }
        let segments = rest[rest.index(after: slash)...]
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard segments.count >= 2 else { return [] }
        return ["\(segments[0])/\(segments[1])"]
    }
}

// MARK: - Topic classification
//
// `Origin` above records HOW a term was found — the provenance the UI shows the
// user. `Kind` records WHAT the term is, which is what a caller needs when it
// wants to weight a repo above a stray proper noun, or phrase a recall line as
// "the repository tryholmes/holmes" rather than "the term tryholmes/holmes".
//
// Both are derived, never stored: a Topic's kind is a function of where it came
// from plus the shape of the term itself, so there is exactly one place the
// classification can be wrong and no way for the two to drift apart.

extension TopicExtractor {

    /// What the term names.
    enum Kind: String {
        case repo
        case person
        case product
        case domain
        case quoted
        case capitalized
        case other

        /// Noun for the "why this matched" line next to a recalled memory row.
        var label: String {
            switch self {
            case .repo:        return "repository"
            case .person:      return "person"
            case .product:     return "product or project"
            case .domain:      return "site"
            case .quoted:      return "quoted term"
            case .capitalized: return "proper noun"
            case .other:       return "subject"
            }
        }
    }
}

extension TopicExtractor.Topic {

    /// What this term names, from its origin and its own shape.
    var kind: TopicExtractor.Kind {
        switch origin {
        case .repoSlug: return .repo
        case .handle:   return .person
        case .domain:   return .domain
        case .quoted:   return .quoted
        case .properNoun:
            // A proper noun that is shaped like something more specific is that
            // more specific thing — "tryholmes/holmes" is a repo no matter which
            // rule happened to catch it first.
            let shaped = Self.shapeKind(of: term)
            return shaped == .other ? .capitalized : shaped
        case .reference, .questionSubject, .model:
            return Self.shapeKind(of: term)
        }
    }

    /// How much weight to give this topic, 0…1. Ordered exactly like
    /// `Origin.priority` — an explicit signal (quotes, a slug, a handle) beats
    /// an inferred one (a mid-sentence capital, the model fallback) — and
    /// expressed as a number so callers can threshold on it.
    var confidence: Double {
        switch origin {
        case .quoted:          return 0.95
        case .repoSlug:        return 0.93
        case .handle:          return 0.90
        case .domain:          return 0.86
        case .reference:       return 0.84
        case .questionSubject: return 0.80
        case .properNoun:      return 0.60
        case .model:           return 0.50
        }
    }

    /// Classification from the term's own characters, for the origins that
    /// don't imply one. Cheap, literal tests only — no guessing.
    private static func shapeKind(of term: String) -> TopicExtractor.Kind {
        if term.contains("/") { return .repo }
        if term.hasPrefix("@") { return .person }
        // host.tld, with a real alphabetic suffix — "v1.2" and "e.g" are not sites.
        if term.contains("."), !term.contains(" "),
           let suffix = term.split(separator: ".").last,
           suffix.count >= 2, suffix.allSatisfy({ $0.isLetter }) {
            return .domain
        }
        // ALLCAPS acronyms read as product/protocol names ("MCP", "FTS5").
        if term.count <= 6, term == term.uppercased(),
           term.rangeOfCharacter(from: .letters) != nil { return .product }
        if let first = term.first, first.isUppercase { return .capitalized }
        return .other
    }
}
