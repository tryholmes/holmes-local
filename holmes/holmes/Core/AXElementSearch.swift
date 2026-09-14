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

enum AXElementSearch {
    static let defaultMaxDepth = 30
    static let defaultMaxNodes = 3000

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
                           children: (Node) -> [Node],
                           score: (Node) -> Int?) -> Result<Node> {
        var frontier: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0
        var visited = 0
        var bestNode: Node?
        var bestScore = Int.min
        var truncated = false
        while head < frontier.count {
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
