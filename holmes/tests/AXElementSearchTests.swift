import Foundation

final class FakeElement {
    let role: String
    let title: String?
    let descriptionText: String?
    let help: String?
    let identifier: String?
    var children: [FakeElement] = []
    init(_ role: String, title: String? = nil, description: String? = nil, help: String? = nil, identifier: String? = nil) {
        self.role = role
        self.title = title
        self.descriptionText = description
        self.help = help
        self.identifier = identifier
    }
    var names: [String?] { [title, descriptionText, help, identifier] }
}

@main
struct AXElementSearchTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func findButton(_ label: String, in root: FakeElement, maxDepth: Int = 30, maxNodes: Int = 3000) -> AXElementSearch.Result<FakeElement> {
            AXElementSearch.best(from: root, maxDepth: maxDepth, maxNodes: maxNodes,
                                 stopScore: AXLabelMatch.exact.rawValue,
                                 children: { $0.children },
                                 score: { node in
                                     guard node.role == "AXButton" else { return nil }
                                     return AXElementSearch.labelMatch(label, names: node.names)?.rawValue
                                 })
        }

        // Ranking: the old title substring match pressed the first "Reply…" it met.
        let window = FakeElement("AXWindow")
        let replyAll = FakeElement("AXButton", title: "Reply All")
        let reply = FakeElement("AXButton", title: "Reply")
        window.children = [replyAll, reply]
        expect(findButton("Reply", in: window).node === reply, "An exact title beats an earlier substring match")
        expect(findButton("reply all", in: window).node === replyAll, "A case insensitive full match beats substring matches")
        expect(findButton("All", in: window).node === replyAll, "A substring still matches when nothing better exists")

        let toolbar = FakeElement("AXToolbar")
        let icon = FakeElement("AXButton", description: "Send")
        let helpOnly = FakeElement("AXButton", help: "Archive message")
        let idOnly = FakeElement("AXButton", identifier: "composeButton")
        toolbar.children = [icon, helpOnly, idOnly]
        expect(findButton("Send", in: toolbar).node === icon, "An icon button is found by its AXDescription")
        expect(findButton("Archive message", in: toolbar).node === helpOnly, "A control is found by its AXHelp")
        expect(findButton("composeButton", in: toolbar).node === idOnly, "A control is found by its AXIdentifier")
        expect(findButton("Delete", in: toolbar).node == nil, "No match returns nil rather than a guess")
        expect(AXElementSearch.labelMatch("  ", names: ["Send"]) == nil, "A blank label never matches")
        expect(AXElementSearch.labelMatch("send", names: ["Send later", "SEND"]) == .caseInsensitive,
               "The strongest match across all names wins")

        // Bounds: a pathological tree cannot stall the caller.
        let deepRoot = FakeElement("AXGroup")
        var cursor = deepRoot
        for level in 1...200 {
            let next = FakeElement(level == 150 ? "AXButton" : "AXGroup", title: level == 150 ? "Deep" : nil)
            cursor.children = [next]
            cursor = next
        }
        let deep = findButton("Deep", in: deepRoot, maxDepth: 40)
        expect(deep.node == nil && deep.truncated && deep.visited <= 41, "Depth is bounded (visited \(deep.visited))")

        let wideRoot = FakeElement("AXWindow")
        wideRoot.children = (0..<20_000).map { _ in FakeElement("AXStaticText") }
        wideRoot.children.append(FakeElement("AXButton", title: "Last"))
        let wide = findButton("Last", in: wideRoot, maxNodes: 500)
        expect(wide.node == nil && wide.truncated && wide.visited == 500, "Visited element count is bounded (visited \(wide.visited))")

        var scored = 0
        let early = AXElementSearch.best(from: window, stopScore: AXLabelMatch.exact.rawValue,
                                         children: { $0.children },
                                         score: { node -> Int? in
                                             scored += 1
                                             return node === replyAll ? AXLabelMatch.exact.rawValue : nil
                                         })
        expect(early.node === replyAll && scored == 2, "An exact match ends the walk immediately")

        print("Passed \(checks) bounded accessibility search and label ranking checks")
    }
}
