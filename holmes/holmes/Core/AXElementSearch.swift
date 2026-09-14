import Foundation

// MARK: - AXElementSearch
//
// Pure pieces of Accessibility element lookup, kept free of AX types so they
// can be tested with a fake tree:
//   • a BOUNDED breadth first walk. A real app's tree (a browser, Xcode, a
//     long chat) can hold tens of thousands of elements, and every attribute
//     read is a cross process round trip, so an unbounded recursive walk could
//     stall for many seconds. Depth and visited element count are capped.
//   • label ranking. A control is identified by its title, description, help
//     text or identifier (icon buttons usually have only a description). An
//     exact match beats a case insensitive match beats a substring match, so
//     "Reply" presses Reply, not "Reply All" that happened to come first.

enum AXLabelMatch: Int, Comparable {
    case substring = 1
    case caseInsensitive = 2
    case exact = 3

    static func < (lhs: AXLabelMatch, rhs: AXLabelMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The accessible names of one element. Help text is a sentence ABOUT a
/// control ("Send the message now"), so it only counts as a match when it
/// equals the requested label; a substring of it must never pick a control.
struct AXNames {
    var title: String?
    var description: String?
    var help: String?
    var identifier: String?
    var placeholder: String?

    init(title: String? = nil, description: String? = nil, help: String? = nil,
         identifier: String? = nil, placeholder: String? = nil) {
        self.title = title
        self.description = description
        self.help = help
        self.identifier = identifier
        self.placeholder = placeholder
    }

    var substringNames: [String?] { [title, description, identifier, placeholder] }
    var exactOnlyNames: [String?] { [help] }
    /// What a person sees as the control's name, for the commit gate.
    var visibleName: String {
        [title, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What happened when Holmes tried to press a named control.
enum AXPressOutcome: Equatable {
    case pressed(matched: String)
    case notFound
    case failed(code: Int32)
    /// The label matched a send/submit class control and the press was not
    /// confirmed; nothing was pressed.
    case needsConfirmation(matched: String)
}

/// The commit gate for a control that was actually MATCHED. The requested
/// label alone is not enough: "later" substring matches "Send later".
enum CommitControlGate {
    private static let commitRegex = try! NSRegularExpression(
        pattern: #"\b(send|submit|post|publish|tweet|reply|confirm|pay|buy|order|delete|archive|trash|purchase|accept|share|discard|remove|don'?t save)\b"#,
        options: [.caseInsensitive])

    static func looksLikeCommit(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return commitRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// True when pressing the matched control needs the user's confirmation.
    static func pressNeedsConfirmation(requested: String, matched: AXNames, userConfirmed: Bool) -> Bool {
        guard !userConfirmed else { return false }
        return looksLikeCommit(requested) || looksLikeCommit(matched.visibleName)
    }
}

enum AXElementSearch {
    static let defaultMaxDepth = 30
    static let defaultMaxNodes = 3000

    /// Label match against an element's names, with help text exact only.
    static func labelMatch(_ label: String, in names: AXNames) -> AXLabelMatch? {
        let loose = labelMatch(label, names: names.substringNames)
        guard let strict = labelMatch(label, names: names.exactOnlyNames), strict != .substring else { return loose }
        return max(loose ?? strict, strict)
    }

    /// The strongest match of `label` against any of an element's names.
    static func labelMatch(_ label: String, names: [String?]) -> AXLabelMatch? {
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        var best: AXLabelMatch?
        for raw in names {
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let match: AXLabelMatch?
            if name == wanted {
                match = .exact
            } else if name.compare(wanted, options: [.caseInsensitive]) == .orderedSame {
                match = .caseInsensitive
            } else if name.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                match = .substring
            } else {
                match = nil
            }
            if let match, best.map({ match > $0 }) ?? true { best = match }
            if best == .exact { return best }
        }
        return best
    }

    /// Score for "the field to type into". A text AREA (a message or document
    /// body) always outranks a text FIELD (a toolbar search box) of the same
    /// label quality, so a shallow search field never wins over the body just
    /// because a breadth first walk meets it first. With a hint, label quality
    /// comes first and the area preference breaks ties.
    static func textEntryScore(role: String, hint: String?, names: () -> AXNames) -> Int? {
        let isArea = role == "AXTextArea"
        guard isArea || role == "AXTextField" else { return nil }
        let areaBonus = isArea ? 1 : 0
        guard let hint else { return 1 + areaBonus }
        guard let match = labelMatch(hint, in: names()) else { return nil }
        return match.rawValue * 2 + areaBonus
    }

    /// The score at which a text entry search can stop: a text area (no hint),
    /// or an exact label match on a text area (hint).
    static func textEntryStopScore(hasHint: Bool) -> Int {
        hasHint ? AXLabelMatch.exact.rawValue * 2 + 1 : 2
    }

    struct Result<Node> {
        let node: Node?
        let visited: Int
        /// True when the walk stopped at a limit before seeing the whole tree.
        let truncated: Bool
    }

    /// Breadth first search for the highest scoring node. `score` returns nil
    /// for a non match; a score of `stopScore` or more ends the walk at once.
    /// Earlier nodes win ties (they are closer to the root).
    static func best<Node>(from root: Node,
                           maxDepth: Int = defaultMaxDepth,
                           maxNodes: Int = defaultMaxNodes,
                           stopScore: Int = Int.max,
                           shouldStop: () -> Bool = { false },
                           children: (Node) -> [Node],
                           score: (Node) -> Int?) -> Result<Node> {
        var frontier: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0
        var visited = 0
        var bestNode: Node?
        var bestScore = Int.min
        var truncated = false
        while head < frontier.count {
            // A wall clock budget bounds the WHOLE walk: attribute reads on
            // already queued nodes are IPC calls too, not just child reads.
            if shouldStop() {
                truncated = true
                break
            }
            if visited >= maxNodes {
                truncated = true
                break
            }
            let (node, depth) = frontier[head]
            head += 1
            visited += 1
            if let value = score(node), value > bestScore {
                bestScore = value
                bestNode = node
                if value >= stopScore { break }
            }
            if depth >= maxDepth {
                // Children are not read past the limit: each read is an IPC call.
                truncated = true
                continue
            }
            for child in children(node) {
                frontier.append((child, depth + 1))
            }
            // Release consumed prefix occasionally so a wide tree stays cheap.
            if head > 1024 {
                frontier.removeFirst(head)
                head = 0
            }
        }
        return Result(node: bestNode, visited: visited, truncated: truncated)
    }
}
