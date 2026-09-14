import AppKit
import Foundation

@main
struct TextEntrySupportTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        // AppleScript literals. The old escaping left newlines and control
        // characters raw (a compile error) and never escaped the app name.
        expect(AppleScriptText.literal("") == "\"\"", "Empty text is an empty literal")
        expect(AppleScriptText.literal(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#, "Quotes and backslashes are escaped")
        expect(AppleScriptText.literal("one\ntwo") == #""one" & linefeed & "two""#, "Newlines join in as linefeed")
        expect(AppleScriptText.literal("a\rb\tc") == #""a" & return & "b" & tab & "c""#, "Return and tab join in by name")
        expect(AppleScriptText.literal("bell\u{7}") == #""bell" & (character id 7)"#, "Other control characters use character id")
        let hostileName = #"Notes" to quit"# + "\n" + #"do shell script "echo pwned"#
        let hostile = AppleScriptText.literal(hostileName)
        expect(!hostile.contains("\n") && hostile.hasPrefix(#""Notes\" to quit""#), "A crafted app name cannot close the string: \(hostile)")

        // Round trip through the real AppleScript compiler (offline, no apps):
        // the expression must evaluate to exactly the original text.
        for sample in ["plain", #"quote " and \ backslash"#, "line one\nline two\r\nend", "tab\there", "emoji 😀 ok",
                       "bell\u{7} and nul\u{1}", "\n\nstarts and ends with newlines\n", hostileName] {
            var error: NSDictionary?
            let script = NSAppleScript(source: "return " + AppleScriptText.literal(sample))
            let value = script?.executeAndReturnError(&error).stringValue
            expect(error == nil && value == sample,
                   "AppleScript literal round trips exactly: \(sample.debugDescription) gave \(String(describing: value)) \(String(describing: error))")
        }

        // UTF-16 keyboard chunks. The old code sent UniChar(scalar.value),
        // truncating every emoji to a garbage BMP character.
        let emoji = "a😀b"
        let chunks = KeyboardText.utf16Chunks(emoji, maxUnits: 2)
        expect(chunks == [[0x61], [0xD83D, 0xDE00], [0x62]], "A surrogate pair is never split across events: \(chunks)")
        let mixed = "Hi 👋🏽 from 🇺🇸 and 👨‍👩‍👧‍👦, café ok " + String(repeating: "x", count: 45)
        let mixedChunks = KeyboardText.utf16Chunks(mixed)
        expect(mixedChunks.flatMap { $0 } == Array(mixed.utf16), "Chunks reassemble to the exact UTF-16 text")
        expect(mixedChunks.allSatisfy { $0.count <= 20 && !$0.isEmpty }, "Each chunk fits one keyboard event")
        expect(mixedChunks.allSatisfy { !UTF16.isLeadSurrogate($0.last!) && !UTF16.isTrailSurrogate($0.first!) },
               "No chunk starts or ends inside a surrogate pair")
        let hugeCluster = "e" + String(repeating: "\u{301}", count: 30)
        let hugeChunks = KeyboardText.utf16Chunks(hugeCluster)
        expect(hugeChunks.flatMap { $0 } == Array(hugeCluster.utf16) && hugeChunks.allSatisfy { $0.count <= 20 },
               "A cluster longer than one event is split between scalars")
        expect(KeyboardText.utf16Chunks("").isEmpty, "Empty text posts no events")

        // Read back verification.
        expect(TextEntryVerifier.fieldValue("Hello\r\nworld and more", contains: "Hello\nworld"), "Line endings are normalized")
        expect(TextEntryVerifier.fieldValue("cafe\u{301}", contains: "café"), "Unicode normalization is ignored")
        expect(!TextEntryVerifier.fieldValue("", contains: "text") && !TextEntryVerifier.fieldValue(nil, contains: "text"),
               "An empty or unreadable field is not verified")
        expect(TextEntryVerifier.unconfirmedRestoreDelay(forLength: 10) >= 1.5
               && TextEntryVerifier.unconfirmedRestoreDelay(forLength: 1_000_000) == 4.0,
               "An unconfirmed paste keeps the clipboard longer, adaptively and bounded")
        expect(TextEntryResult.unverified("no value").succeeded && !TextEntryResult.unverified("no value").isVerified,
               "Unverified is distinct from verified success")
        expect(!TextEntryResult.failed("x").succeeded, "Failed is a failure")

        // Pasteboard snapshot: every item and type comes back, not just text.
        let board = NSPasteboard(name: NSPasteboard.Name("holmes-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let first = NSPasteboardItem()
        first.setString("plain text", forType: .string)
        first.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        board.writeObjects([first, second])
        let snapshot = PasteboardSnapshot(capturing: board)
        board.clearContents()
        board.setString("Holmes borrowed the clipboard", forType: .string)
        snapshot.restore(to: board)
        let items = board.pasteboardItems ?? []
        expect(items.count == 2, "Both clipboard items are restored")
        expect(items.first?.string(forType: .string) == "plain text"
               && items.first?.data(forType: .rtf) == Data("{\\rtf1 rich}".utf8),
               "Every type of the first item is restored")
        expect(items.last?.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]), "A non text item is restored")
        board.clearContents()
        let emptySnapshot = PasteboardSnapshot(capturing: board)
        board.setString("temp", forType: .string)
        emptySnapshot.restore(to: board)
        expect(emptySnapshot.isEmpty && (board.pasteboardItems ?? []).isEmpty, "An empty clipboard is restored as empty")

        print("Passed \(checks) AppleScript escaping, keyboard chunking, verification and clipboard checks")
    }
}
