import AppKit
import Foundation

// MARK: - Text entry support
//
// Small, testable pieces behind ActionExecutor's typing, pasting and
// AppleScript paths. Kept free of AX and CGEvent so they run in unit tests.

/// What actually happened when Holmes tried to put text into another app.
enum TextEntryResult: Equatable {
    /// The field's value was read back and contains the text.
    case verified
    /// The events were delivered but the field does not expose its value, so
    /// Holmes cannot prove the text landed. Never reported as plain success.
    case unverified(String)
    case failed(String)

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }

    var isVerified: Bool { self == .verified }

    /// One sentence for a tool result or status line.
    func describe(action: String, app: String) -> String {
        switch self {
        case .verified: return "\(action) in \(app) (verified)."
        case .unverified(let why): return "\(action) in \(app), but it could not be verified: \(why)"
        case .failed(let why): return "Couldn't \(action.lowercased()) in \(app): \(why)"
        }
    }
}

// MARK: - AppleScript string literals

enum AppleScriptText {
    /// An AppleScript EXPRESSION that evaluates to exactly `text`: quotes and
    /// backslashes are escaped, and control characters (which cannot appear
    /// raw inside an AppleScript string) are joined in as `linefeed`,
    /// `return`, `tab` or `(character id N)`. Safe for app names and message
    /// bodies alike; a crafted name can never close the string and inject code.
    static func literal(_ text: String) -> String {
        var parts: [String] = []
        var run = ""
        func flush() {
            if !run.isEmpty { parts.append("\"" + run + "\""); run = "" }
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": run += "\\\\"
            case "\"": run += "\\\""
            case "\n": flush(); parts.append("linefeed")
            case "\r": flush(); parts.append("return")
            case "\t": flush(); parts.append("tab")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                    || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    flush()
                    parts.append("(character id \(scalar.value))")
                } else {
                    run.unicodeScalars.append(scalar)
                }
            }
        }
        flush()
        return parts.isEmpty ? "\"\"" : parts.joined(separator: " & ")
    }
}

// MARK: - Keyboard text chunks

enum KeyboardText {
    /// CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
    static let maxUnitsPerEvent = 20

    /// Splits text into UTF-16 chunks for keyboard events without ever
    /// separating a surrogate pair (emoji and other non BMP characters), and
    /// keeping whole grapheme clusters together whenever they fit.
    static func utf16Chunks(_ text: String, maxUnits: Int = maxUnitsPerEvent) -> [[UniChar]] {
        let limit = max(2, maxUnits)
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        func append(_ units: [UniChar]) {
            if current.count + units.count > limit, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current += units
        }
        for character in text {
            let units = Array(String(character).utf16)
            if units.count <= limit {
                append(units)
            } else {
                // A cluster longer than one event: split between scalars, which
                // never cuts a surrogate pair.
                for scalar in character.unicodeScalars {
                    append(Array(String(scalar).utf16))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Verification and clipboard timing

enum TextEntryVerifier {
    /// True when a field's read back value contains the text Holmes entered.
    /// Line endings and Unicode normalization differ between apps, so both
    /// sides are normalized first.
    static func fieldValue(_ value: String?, contains typed: String) -> Bool {
        guard let value else { return false }
        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .precomposedStringWithCanonicalMapping
        }
        let wanted = normalize(typed)
        guard !wanted.isEmpty else { return true }
        return normalize(value).contains(wanted)
    }

    /// How long to keep Holmes' text on the clipboard when the paste could
    /// not be confirmed: long enough for a slow app to read a large paste.
    static func unconfirmedRestoreDelay(forLength length: Int) -> TimeInterval {
        min(4.0, 1.5 + Double(max(0, length)) / 4000.0)
    }
}

// MARK: - Pasteboard snapshot

/// Every item and every type on a pasteboard, so borrowing the clipboard for a
/// paste can hand back images, files and rich text, not just plain text.
struct PasteboardSnapshot {
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(capturing pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    var isEmpty: Bool { items.isEmpty }

    /// Puts the captured items back. Returns the pasteboard's new change count.
    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return pasteboard.changeCount
    }
}
