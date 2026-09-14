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

        // Recovered: the message IS a call.
        let whole = recover(#"{"name":"open_app","parameters":{"name":"Finder"}}"#)
        expect(whole?.name == "open_app" && whole?.arguments["name"] as? String == "Finder", "A whole message call is recovered")
        let fenced = recover("I'll take a screenshot first.\n```json\n{\"name\": \"computer\", \"arguments\": {\"action\": \"screenshot\"}}\n```")
        expect(fenced?.name == "computer" && fenced?.arguments["action"] as? String == "screenshot",
               "A code fence after a short lead in is recovered")
        let function = recover("Calling it:\n```\n{\"function\":{\"name\":\"computer\",\"arguments\":{\"action\":\"key\",\"text\":\"cmd+s\"}}}\n```")
        expect(function?.name == "computer" && function?.arguments["text"] as? String == "cmd+s",
               "The nested function form is recovered from a fence")
        let upper = recover("```json {\"tool\":\"OPEN_APP\",\"input\":{\"name\":\"Mail\"}}```")
        expect(upper?.name == "open_app" && upper?.arguments["name"] as? String == "Mail",
               "A one line fence matches the offered tool name case insensitively")
        let unterminated = recover("```json\n{\"name\":\"open_app\",\"parameters\":{\"name\":\"Notes\"}}")
        expect(unterminated?.arguments["name"] as? String == "Notes", "A fence left open at the end of the message is recovered")
        let bare = recover(#"{"action":"screenshot"}"#)
        expect(bare?.name == "computer", "A message that is only bare computer arguments is still recovered")

        // Not recovered: prose that mentions or quotes a call.
        expect(recover(#"Opened it with {"name":"open_app","parameters":{"name":"Notes"}}."#) == nil,
               "A final answer quoting a past call in prose is never re executed")
        expect(recover(#"{"name":"open_app","parameters":{"name":"Notes"}} Opening Notes now."#) == nil,
               "A call followed by prose is not a call")
        expect(recover(#"Use the {tool} form: {"tool":"open_app","input":{"name":"Mail"}} and wait."#) == nil,
               "A call embedded mid sentence is not a call")
        expect(recover("Done.\n```json\n{\"name\":\"open_app\",\"parameters\":{\"name\":\"Notes\"}}\n```\nThat opened Notes for you.") == nil,
               "A fence followed by more prose is an example, not a call")
        let longLeadIn = String(repeating: "I reviewed everything carefully. ", count: 7)
        expect(recover(longLeadIn + "\n```json\n{\"name\":\"open_app\",\"parameters\":{}}\n```") == nil,
               "A fence after a long answer is not recovered")
        expect(recover("Here:\n```json\n{\"action\":\"left_click\",\"coordinate\":[1,2]}\n```") == nil,
               "Bare arguments after a lead in are not re executed")
        expect(recover("```json\n{\"name\":\"delete_everything\",\"arguments\":{}}\n```") == nil,
               "A call to a tool that was not offered is never recovered")
        expect(recover(#"I clicked using {"action":"left_click","coordinate":[1,2]} and it worked."#) == nil,
               "Bare arguments quoted inside a prose answer are not re executed")
        expect(recover("All done, the file is saved.") == nil, "Plain prose has no tool call")
        let noComputer = OllamaClient.toolCallFromContent(#"{"action":"screenshot"}"#,
            tools: [OllamaClient.ToolDef(name: "open_app", description: "", inputSchema: [:])])
        expect(noComputer == nil, "Bare arguments need the computer tool to be offered")

        print("Passed \(checks) tool call recovery checks")
    }
}
