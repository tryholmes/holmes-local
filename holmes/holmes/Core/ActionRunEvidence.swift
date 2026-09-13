import Foundation

/// Tool outcomes, rather than the model's closing prose, determine whether an
/// action run succeeded. Reading the screen cannot repair a failed mutation.
struct ActionRunEvidence {
    private struct Operation: Hashable {
        let tool: String
        let action: String?
    }

    private struct FailedOperation {
        let sequence: UInt64
        let message: String
    }

    private var unresolvedActions: [Operation: FailedOperation] = [:]
    private var sequence: UInt64 = 0
    private var lastReadFailure: String?
    private var hasSuccessfulTool = false
    private(set) var hasSuccessfulAction = false
    private(set) var declined = false

    /// Prefer the latest unresolved action failure. Read failures matter only
    /// when every recorded tool failed; a later successful read/action can recover.
    var failure: String? {
        if let unresolved = unresolvedActions.values.max(by: { $0.sequence < $1.sequence }) {
            return unresolved.message
        }
        return hasSuccessfulTool ? nil : lastReadFailure
    }

    mutating func record(tool: String, action: String?, readOnly: Bool, isError: Bool, text: String) {
        sequence &+= 1
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDecline = message.range(of: #"^User declined\b"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
        if isDecline { declined = true }

        let operation = Operation(tool: tool, action: action)
        // A declined operation did not succeed even if a provider omitted its
        // error flag. The sticky flag also lets the caller stop further actions.
        if isError || isDecline {
            let failureText = message.isEmpty ? "\(tool)\(action.map { " (\($0))" } ?? "") failed." : message
            if readOnly {
                lastReadFailure = failureText
            } else {
                unresolvedActions[operation] = FailedOperation(sequence: sequence, message: failureText)
            }
            return
        }

        hasSuccessfulTool = true
        if !readOnly {
            hasSuccessfulAction = true
            unresolvedActions.removeValue(forKey: operation)
        }
    }
}
