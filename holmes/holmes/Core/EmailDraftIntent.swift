import Foundation

/// Recognizes a request to produce editable email text. Context only resolves
/// pronouns ("write it for me"); it never turns an unrelated writing task into mail.
enum EmailDraftIntent {
    static func matches(_ query: String, isEmailContext: Bool) -> Bool {
        guard let request = ActionRequestIntent.normalizedAction(query) else { return false }
        let words = request.split(separator: " ").map(String.init)
        guard let verb = words.first,
              ["draft", "write", "compose", "rewrite", "reply", "respond"].contains(verb) else { return false }
        let object = words.dropFirst().joined(separator: " ")
        // A request that includes delivery belongs to the guarded action router.
        guard !matchesPattern(#"\b(?:and|then)\s+(?:please\s+)?(?:send|submit|post)\b"#, in: object) else { return false }
        guard !matchesPattern(#"^(?:(?:a|an|the|this|that|my|your|short|quick|polite|professional|friendly)\s+)*(?:poem|poetry|essay|story|novel|code|function|script|pull request|pr|report|blog|tweet|song|resume|résumé)\b"#, in: object),
              !matchesPattern(#"\b(?:imessage|slack|discord|teams|telegram|whatsapp)\b"#, in: object) else { return false }
        if matchesPattern(#"\b(?:e-?mail|gmail|outlook)\b"#, in: object) { return true }
        guard isEmailContext else { return false }
        if verb == "reply" || verb == "respond" { return true }
        return object.isEmpty || matchesPattern(#"^(?:(?:a|an|the|this|that|my|your|short|quick|polite|professional|friendly)\s+)*(?:it|this|that|reply|response|message|draft)(?:\b|$)"#, in: object)
            || ["for me", "something for me"].contains(object)
    }

    private static func matchesPattern(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Shared by voice and typed entry. Polite imperatives are actions even when
/// punctuated as questions; requests for instructions and statements stay questions.
enum ActionRequestIntent {
    static func normalizedAction(_ query: String) -> String? {
        var text = query.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.hasPrefix("/") else { return nil }
        text = replacingPrefix(#"^(?:(?:hey\s+)?(?:holmes|clicky)[,\s]+|hey[,\s]+)"#, in: text)
        text = replacingPrefix(#"^agent[,\s]+"#, in: text)
        // Remove only request wrappers, never arbitrary text before an action verb.
        for _ in 0..<4 {
            let stripped = replacingPrefix(#"^(?:please|kindly|can you|could you|would you|will you|help me)\s+"#, in: text)
            if stripped == text { break }
            text = stripped
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        guard !text.isEmpty else { return nil }
        let first = text.split(separator: " ").first.map(String.init) ?? ""
        let teachingOrNegation: Set<String> = [
            "how", "what", "why", "where", "when", "who", "which", "should",
            "explain", "describe", "tell", "show", "teach", "help", "understand",
            "don't", "dont", "never", "stop", "avoid", "not"
        ]
        guard !teachingOrNegation.contains(first), !text.hasPrefix("do not ") else { return nil }
        return text
    }

    static func matches(_ query: String) -> Bool {
        guard let text = normalizedAction(query) else { return false }
        let first = text.split(separator: " ").first.map(String.init) ?? ""
        let verbs: Set<String> = [
            "click", "type", "open", "book", "fill", "send", "buy", "order",
            "purchase", "install", "schedule", "compose", "navigate", "select",
            "press", "drag", "scroll", "paste", "submit", "download"
        ]
        if verbs.contains(first) { return true }
        if text.hasPrefix("do this") || text.hasPrefix("do it") || text.hasPrefix("just do") { return true }
        let original = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return original == "agent" || original.range(
            of: #"^(?:(?:hey\s+)?(?:holmes|clicky)[,\s]+)?agent(?:[,\s]|$)"#,
            options: .regularExpression) != nil
    }

    private static func replacingPrefix(_ pattern: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
