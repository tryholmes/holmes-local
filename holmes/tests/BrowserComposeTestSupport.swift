import Foundation

// Supporting app models only. The harness compiles the production BrowserBridge,
// LiveContext parser/formatter, ContextEngine and EmailComposeSnapshot unchanged.
struct DetectedContext { let icon: String; let description: String; let appName: String }
struct UpcomingMeeting {}
struct FocusedContext {
    let role: String
    let roleDescription: String
    let label: String
    let value: String
    let selectedText: String
    var isEditable: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) }
}
struct ScreenReading {
    enum Kind { case editor, terminal, chat, generic }
    var appName: String
    var windowTitle: String
    var bodyText: String = ""
    var kind: Kind = .generic
    var documentPath: String?
    var fileName: String?
    var workspace: String?
    var symbol: String?
    var lineNumber: Int?
    var selectedText: String?
    var command: String?
    var workingDir: String?
    var url: String?
    var contact: String?
    var lastMessage: String?
    var emailCompose: EmailComposeSnapshot?
}
