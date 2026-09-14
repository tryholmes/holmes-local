import Foundation

// Apple Mail compose matching over fake accessibility trees. No Mail, no AX API.
@main
struct MailComposeMatcherTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        var nextID = 0
        func node(_ role: String, _ labels: Set<String> = [], value: String? = nil, settable: Bool = false,
                  _ children: [MailAXNode] = []) -> MailAXNode {
            nextID += 1
            return MailAXNode(id: nextID, role: role, labels: labels, value: value, valueSettable: settable, children: children)
        }
        func headers(subject: String = "Running late", to: String = "Dana Lee <dana@example.com>") -> [MailAXNode] {
            [node("AXTextField", ["to"], value: to), node("AXTextField", ["cc"], value: ""), node("AXTextField", ["subject"], value: subject)]
        }

        // The classic text view body still works.
        let classic = node("AXWindow", [], headers() + [node("AXScrollArea", [], [node("AXTextArea", ["message body"], value: "", settable: true)])])
        let classicMatch = MailComposeMatcher.match(window: classic)
        expect(classicMatch?.bodyKind == .textArea && classicMatch?.bodyReadable == true && classicMatch?.bodyText == ""
               && classicMatch?.bodyValueSettable == true, "A labeled text area body is matched and writable")

        // Regression: current Mail renders the body as an unlabeled WebKit AXWebArea.
        let web = node("AXWebArea", [], [
            node("AXGroup", [], [node("AXStaticText", value: "Hi Dana,")]),
            node("AXGroup"),
            node("AXGroup", [], [node("AXStaticText", value: "Thanks for "), node("AXLink", [], [node("AXStaticText", value: "the notes")]), node("AXStaticText", value: ".")])
        ])
        let webWindow = node("AXWindow", [], headers() + [node("AXScrollArea", [], [web])])
        let webMatch = MailComposeMatcher.match(window: webWindow)
        expect(webMatch?.bodyKind == .webArea && webMatch?.bodyReadable == true && webMatch?.bodyID == web.id,
               "An AXWebArea body is a readable compose body, not rich content")
        expect(webMatch?.bodyText == "Hi Dana,\n\nThanks for the notes.", "Web area text keeps blocks as lines, blank blocks as blank lines, and inline links")
        expect(webMatch?.bodyValueSettable == false, "An unsettable web area reports that a paste is needed")
        expect(MailComposeMatcher.recipients(MailComposeMatcher.node(webMatch!.toID, in: webWindow)) == ["dana@example.com"], "Recipients are read from the To field")

        let emptyWeb = node("AXWindow", [], headers(subject: "") + [node("AXWebArea", [], [node("AXGroup")])])
        let emptyMatch = MailComposeMatcher.match(window: emptyWeb)
        expect(emptyMatch?.bodyText == "" && emptyMatch?.bodyReadable == true && emptyMatch?.subject == "", "An empty WebKit body reads as empty")

        let valued = node("AXWindow", [], headers() + [node("AXWebArea", [], value: "Typed text", settable: true, [])])
        expect(MailComposeMatcher.match(window: valued)?.bodyText == "Typed text" && MailComposeMatcher.match(window: valued)?.bodyValueSettable == true,
               "A web area that exposes AXValue uses it directly")

        let withLogo = node("AXWindow", [], headers() + [node("AXWebArea", [], [node("AXGroup", [], [node("AXStaticText", value: "Alex")]), node("AXImage")])])
        expect(MailComposeMatcher.match(window: withLogo)?.bodyReadable == false, "An image in the body makes it unreadable, so it is never overwritten")

        // A quoted message viewer can be a second web area; only a labeled body is trusted then.
        let twoUnlabeled = node("AXWindow", [], headers() + [node("AXWebArea", [], [node("AXGroup")]), node("AXWebArea", [], [node("AXGroup", [], [node("AXStaticText", value: "Quoted")])])])
        expect(MailComposeMatcher.match(window: twoUnlabeled) == nil, "Two unlabeled web areas are ambiguous")
        let labeledBody = node("AXWebArea", ["message body"], [node("AXGroup")])
        let twoLabeled = node("AXWindow", [], headers() + [node("AXWebArea", [], [node("AXGroup", [], [node("AXStaticText", value: "Quoted")])]), labeledBody])
        expect(MailComposeMatcher.match(window: twoLabeled)?.bodyID == labeledBody.id, "A labeled web area wins over an unlabeled viewer")

        let readerPane = node("AXWindow", [], [node("AXWebArea", [], [node("AXGroup", [], [node("AXStaticText", value: "Incoming message")])])])
        expect(MailComposeMatcher.match(window: readerPane) == nil, "The reader pane without Subject and To is never a composer")
        let noBody = node("AXWindow", [], headers())
        expect(MailComposeMatcher.match(window: noBody) == nil, "A composer without a body control is not matched")
        let unresolved = node("AXWindow", [], [node("AXTextField", ["to"], value: "Dana"), node("AXTextField", ["subject"], value: "Hi"), node("AXWebArea", [], [])])
        expect(MailComposeMatcher.recipients(MailComposeMatcher.node(MailComposeMatcher.match(window: unresolved)!.toID, in: unresolved)) == ["(recipient address unavailable)"],
               "A name without an address blocks readiness instead of disappearing")
        // Regression: rollback sent Command Z even when the paste never reached the body,
        // which could undo an unrelated edit of the person's.
        expect(MailComposeMatcher.rollback(bodyNow: "Hi", before: "Hi", valueSettable: false, usedPaste: true) == .none,
               "An unchanged body needs no rollback, so no Command Z is sent")
        expect(MailComposeMatcher.rollback(bodyNow: "Hi\n\nPasted", before: "Hi", valueSettable: false, usedPaste: true) == .undoPaste,
               "Only a body changed by Holmes's paste is undone with Command Z")
        expect(MailComposeMatcher.rollback(bodyNow: "Written", before: "", valueSettable: true, usedPaste: false) == .setValue,
               "A settable body is restored through its AX value")
        expect(MailComposeMatcher.rollback(bodyNow: "Changed elsewhere", before: "", valueSettable: false, usedPaste: false) == .none,
               "Without a paste of Holmes's own there is nothing Holmes may undo")
        expect(MailComposeMatcher.canPaste(focusedID: 7, bodyID: 7) && !MailComposeMatcher.canPaste(focusedID: 3, bodyID: 7)
               && !MailComposeMatcher.canPaste(focusedID: nil, bodyID: 7), "A paste requires focus to be on the exact body element")
        print("Mail compose matcher: \(checks) checks passed on synthetic accessibility trees")
    }
}
