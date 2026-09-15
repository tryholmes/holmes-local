import Foundation

// MARK: - ModelJSON
//
// One robust reader for JSON a local model wrote. Grammar constrained output is
// usually clean, but a degraded reply wraps the object in code fences, leads
// with prose, trails prose that itself contains braces ("{…} Hope that helps
// {smile}"), or puts raw newlines inside string values. Slicing from the first
// "{" to the LAST "}" breaks on every one of those; this scanner finds each
// balanced top level object, respecting strings and escapes, and returns the
// first one the caller accepts.

enum ModelJSON {
    /// Longest reply scanned, and most object starts retried, so a pathological
    /// reply cannot turn parsing into quadratic work.
    static let maxScannedCharacters = 200_000
    static let maxCandidates = 64

    /// The first JSON object in `raw` that parses and satisfies `accept`.
    static func firstObject(in raw: String,
                            where accept: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        let text = raw.count > maxScannedCharacters ? String(raw.prefix(maxScannedCharacters)) : raw
        if let object = scan(text, accept: accept) { return object }
        // A fence marker can sit inside the scanned region in odd ways (a
        // backtick run glued to the brace); retry once without fence lines.
        let unfenced = stripCodeFences(text)
        return unfenced == text ? nil : scan(unfenced, accept: accept)
    }

    /// Every balanced top level object candidate text, in order of appearance.
    static func objectCandidates(in raw: String) -> [String] {
        var results: [String] = []
        var searchFrom = raw.startIndex
        var attempts = 0
        while attempts < maxCandidates, let start = raw[searchFrom...].firstIndex(of: "{") {
            attempts += 1
            if let range = balancedObjectRange(in: raw, startingAt: start) {
                results.append(String(raw[range]))
                searchFrom = range.upperBound
            } else {
                searchFrom = raw.index(after: start)
            }
        }
        return results
    }

    /// Removes Markdown code fence lines (```json, ```), wherever they appear.
    static func stripCodeFences(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scan(_ raw: String, accept: ([String: Any]) -> Bool) -> [String: Any]? {
        var searchFrom = raw.startIndex
        var attempts = 0
        while attempts < maxCandidates, let start = raw[searchFrom...].firstIndex(of: "{") {
            attempts += 1
            if let range = balancedObjectRange(in: raw, startingAt: start) {
                let candidate = normalizeNewlinesInsideStrings(String(raw[range]))
                if let data = candidate.data(using: .utf8),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   accept(object) {
                    return object
                }
            }
            // Retry from the next brace: prose like "use {this} form: {…}"
            // must not hide the real object behind a non JSON brace pair, and a
            // rejected wrapper may still contain the object the caller wants.
            searchFrom = raw.index(after: start)
        }
        return nil
    }

    /// The balanced `{…}` beginning at `start`, string and escape aware so braces
    /// inside JSON string values cannot unbalance the scan.
    static func balancedObjectRange(in raw: String, startingAt start: String.Index) -> Range<String.Index>? {
        guard start < raw.endIndex, raw[start] == "{" else { return nil }
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

    /// Escapes literal newlines, carriage returns and tabs INSIDE string
    /// regions: spec invalid, common from small models, and otherwise fatal to
    /// JSONSerialization.
    static func normalizeNewlinesInsideStrings(_ candidate: String) -> String {
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

// MARK: - One repair attempt

enum ModelJSONRepair {
    struct Outcome<Value> {
        let value: Value?
        /// True when the value came from the repair reply.
        let repaired: Bool
        /// A user facing reason when both attempts failed.
        let failure: String?
    }

    /// Parses `raw`; when that fails, asks for ONE repaired reply and parses it.
    /// Never loops: a model that cannot produce the shape twice is reported.
    static func parse<Value>(_ raw: String,
                             what: String,
                             attempt: (String) -> Value?,
                             repair: (String) async throws -> String) async -> Outcome<Value> {
        if let value = attempt(raw) { return Outcome(value: value, repaired: false, failure: nil) }
        let repairedRaw: String
        do {
            repairedRaw = try await repair(raw)
        } catch is CancellationError {
            return Outcome(value: nil, repaired: false, failure: "Stopped.")
        } catch {
            return Outcome(value: nil, repaired: false,
                           failure: "The local model's \(what) was unreadable, and the repair request failed: \(error.localizedDescription)")
        }
        if let value = attempt(repairedRaw) { return Outcome(value: value, repaired: true, failure: nil) }
        return Outcome(value: nil, repaired: false,
                       failure: "The local model returned an unreadable \(what) twice. Nothing was run.")
    }

    /// The short repair prompt: the broken reply goes back with the one job of
    /// returning the same content as a single valid JSON object.
    static func repairPrompt(for raw: String, shape: String) -> String {
        """
        Your previous reply could not be parsed as JSON. Return the SAME content as ONE valid JSON object with this shape and nothing else, no prose and no code fences:
        \(shape)

        Previous reply:
        \(String(raw.prefix(6000)))
        """
    }
}
