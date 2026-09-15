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
    var names: AXNames { AXNames(title: title, description: descriptionText, help: help, identifier: identifier) }
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
                                     return AXElementSearch.labelMatch(label, in: node.names)?.rawValue
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

        // ax_type with no field hint: the message body, not a shallow search field.
        let composeWindow = FakeElement("AXWindow")
        let composeToolbar = FakeElement("AXToolbar")
        let searchField = FakeElement("AXTextField", description: "Search")
        composeToolbar.children = [searchField]
        let split = FakeElement("AXSplitGroup")
        let scroll = FakeElement("AXScrollArea")
        let body = FakeElement("AXTextArea", description: "Message body")
        scroll.children = [body]
        split.children = [scroll]
        composeWindow.children = [composeToolbar, split]
        func findTextEntry(_ hint: String?) -> FakeElement? {
            AXElementSearch.best(from: composeWindow,
                                 stopScore: AXElementSearch.textEntryStopScore(hasHint: hint != nil),
                                 children: { $0.children },
                                 score: { node in
                                     AXElementSearch.textEntryScore(role: node.role, hint: hint, names: { node.names })
                                 }).node
        }
        expect(findTextEntry(nil) === body, "With no hint, a deeper text area beats a shallower search field")
        expect(findTextEntry("Search") === searchField, "A hint naming the search field still selects it")
        expect(findTextEntry("message") === body, "A hint matching the body selects the body")
        expect(AXElementSearch.textEntryScore(role: "AXButton", hint: nil, names: { AXNames() }) == nil,
               "Only text areas and text fields are typing targets")

        // Help text is exact only: "message" must not pick a control whose help is "Send the message".
        let helpBar = FakeElement("AXToolbar")
        let sendIcon = FakeElement("AXButton", help: "Send the message")
        helpBar.children = [sendIcon]
        expect(findButton("message", in: helpBar).node == nil, "A substring of help text never selects a control")
        expect(findButton("send the message", in: helpBar).node === sendIcon, "Help text still matches in full")

        // The commit gate runs on the MATCHED control, not only the requested label.
        let later = FakeElement("AXButton", title: "Send later")
        let laterBar = FakeElement("AXToolbar")
        laterBar.children = [later]
        let matchedLater = findButton("later", in: laterBar).node
        expect(matchedLater === later, "A harmless looking label can substring match a send control")
        expect(CommitControlGate.pressNeedsConfirmation(requested: "later", matched: later.names, userConfirmed: false),
               "Pressing the matched Send later control needs confirmation")
        expect(CommitControlGate.pressNeedsConfirmation(requested: "message",
                                                        matched: AXNames(description: "Send"), userConfirmed: false),
               "An icon button described as Send needs confirmation")
        expect(!CommitControlGate.pressNeedsConfirmation(requested: "later", matched: later.names, userConfirmed: true),
               "An approved press goes through")
        expect(!CommitControlGate.pressNeedsConfirmation(requested: "Save draft",
                                                         matched: AXNames(title: "Save Draft"), userConfirmed: false),
               "A non commit control presses freely")
        expect(CommitControlGate.pressNeedsConfirmation(requested: "Don't Save",
                                                        matched: AXNames(title: "Don’t Save"), userConfirmed: false)
               || CommitControlGate.looksLikeCommit("Don't Save"),
               "Don't Save counts as a commit")

        // The time budget stops the whole walk, including scoring of nodes
        // already queued, not only further child reads.
        let budgetRoot = FakeElement("AXWindow")
        budgetRoot.children = (0..<50).map { _ in FakeElement("AXStaticText") }
        var scoredBeforeBudget = 0
        var budgetChecks = 0
        let budgeted = AXElementSearch.best(from: budgetRoot,
                                            shouldStop: { budgetChecks += 1; return budgetChecks > 5 },
                                            children: { $0.children },
                                            score: { _ -> Int? in scoredBeforeBudget += 1; return nil })
        expect(budgeted.truncated && budgeted.visited == 5 && scoredBeforeBudget == 5,
               "An expired budget ends the walk before scoring more queued elements (scored \(scoredBeforeBudget))")

        print("Passed \(checks) bounded accessibility search and label ranking checks")
    }
}
