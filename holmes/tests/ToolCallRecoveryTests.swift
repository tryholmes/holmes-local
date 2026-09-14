import Foundation

@main
struct ToolCallRecoveryTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let tools = [
            OllamaClient.ToolDef(name: "computer", description: "Pixel control", inputSchema: [:]),
            OllamaClient.ToolDef(name: "open_app", description: "Launch an app", inputSchema: [:])
        ]
        func recover(_ text: String) -> OllamaClient.ToolCall? {
            OllamaClient.toolCallFromContent(text, tools: tools)
        }

        let whole = recover(#"{"name":"open_app","parameters":{"name":"Finder"}}"#)
        expect(whole?.name == "open_app" && whole?.arguments["name"] as? String == "Finder", "A whole message call is recovered")

        // Embedded calls used to be ignored, ending the run with prose instead of acting.
        let fenced = recover("I'll take a screenshot first.\n```json\n{\"name\": \"computer\", \"arguments\": {\"action\": \"screenshot\"}}\n```")
        expect(fenced?.name == "computer" && fenced?.arguments["action"] as? String == "screenshot",
               "A call in a code fence after prose is recovered")
        let before = recover(#"{"name":"open_app","parameters":{"name":"Notes"}} Opening Notes now."#)
        expect(before?.arguments["name"] as? String == "Notes", "A call followed by prose is recovered")
        let braces = recover(#"Use the {tool} form: {"tool":"OPEN_APP","input":{"name":"Mail"}} and wait."#)
        expect(braces?.name == "open_app" && braces?.arguments["name"] as? String == "Mail",
               "Prose braces before the call are skipped and the offered tool name matches case insensitively")
        let function = recover(#"Calling it: {"function":{"name":"computer","arguments":{"action":"key","text":"cmd+s"}}}"#)
        expect(function?.name == "computer" && function?.arguments["text"] as? String == "cmd+s",
               "The nested function form is recovered from prose")

        expect(recover(#"Done. I would have used {"name":"delete_everything","arguments":{}} here."#) == nil,
               "A call to a tool that was not offered is never recovered")
        expect(recover(#"I clicked using {"action":"left_click","coordinate":[1,2]} and it worked."#) == nil,
               "Bare arguments quoted inside a prose answer are not re executed")
        let bare = recover(#"{"action":"screenshot"}"#)
        expect(bare?.name == "computer", "A message that is only bare computer arguments is still recovered")
        expect(recover("All done, the file is saved.") == nil, "Plain prose has no tool call")
        let noComputer = OllamaClient.toolCallFromContent(#"{"action":"screenshot"}"#,
            tools: [OllamaClient.ToolDef(name: "open_app", description: "", inputSchema: [:])])
        expect(noComputer == nil, "Bare arguments need the computer tool to be offered")

        print("Passed \(checks) tool call recovery checks")
    }
}
