import Foundation

/// Only an explicit request to open an app belongs on the model-free path.
/// Questions about opening apps and instructions with additional work keep
/// going through the ordinary answer/agent router.
enum AppLaunchIntent {
    static func appName(in request: String) -> String? {
        let text = request.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let pattern = #"^(?:(?:hey\s+)?(?:holmes|clicky)[,\s]+|hey[,\s]+)?(?:agent[,\s]+)?(?:(?:please|can\s+you|could\s+you|would\s+you|will\s+you)\s+)*(?:open(?:\s+up)?|launch|start|switch\s+to|go\s+to|bring\s+up)\s+(?:the\s+|my\s+)?["“']?([\p{L}\p{N}][\p{L}\p{N} .'&+_-]{0,79}?)["”']?(?:\s+(?:app|application))?(?:\s+(?:for\s+me|please|now|thanks))*[.!?]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("apple ") {
            name = String(name.dropFirst(6))
        }
        let lowered = name.lowercased()
        let nonApps: Set<String> = [
            "it", "this", "that", "something", "file", "files", "folder", "folders",
            "link", "tab", "window", "menu", "settings", "preferences", "downloads",
            "desktop", "documents", "a new tab", "new tab", "new window", "recording"
        ]
        guard !name.isEmpty, !nonApps.contains(lowered),
              ![" and ", " then ", " so ", " because "].contains(where: lowered.contains),
              !["a ", "an ", "new "].contains(where: lowered.hasPrefix) else { return nil }
        return name
    }
}
