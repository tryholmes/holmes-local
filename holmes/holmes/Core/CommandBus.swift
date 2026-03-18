import Foundation
import Observation

// Shared bus: ActionSuggestions → SearchBarWindowController → CommandViewModel
// Allows tapping a suggestion in MainPanel to open the bar and auto-run the command.

@Observable
final class CommandBus {
    static let shared = CommandBus()
    private init() {}

    var pendingCommand: String? = nil

    func dispatch(_ command: String) {
        pendingCommand = command
        // Open the search bar, which will pick up pendingCommand on appear
        DispatchQueue.main.async {
            SearchBarWindowController.shared.show()
        }
    }

    func consume() -> String? {
        let cmd = pendingCommand
        pendingCommand = nil
        return cmd
    }
}
