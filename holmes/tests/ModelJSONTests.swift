import Foundation

@main
struct ModelJSONTests {
    static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func hasSteps(_ object: [String: Any]) -> Bool { object["steps"] is [Any] }

        // The first "{" to last "}" slice these replies used to get is invalid JSON.
        let trailingBraces = #"{"steps":[{"action":"open_app"}],"rationale":"ok"} Let me know if {anything} else is needed."#
        expect(ModelJSON.firstObject(in: trailingBraces, where: hasSteps) != nil,
               "Trailing prose containing braces must not break the plan")
        let leadingBraces = #"I used the {steps} format: {"steps":[{"action":"key","input":{"text":"cmd+s"}}],"rationale":"save"}"#
        let leading = ModelJSON.firstObject(in: leadingBraces, where: hasSteps)
        expect((leading?["steps"] as? [[String: Any]])?.first?["action"] as? String == "key",
               "Leading prose containing braces must not hide the object")
        let fenced = "Here is the plan:\n```json\n{\"steps\":[],\"rationale\":\"a } inside a string\"}\n```\nDone."
        expect(ModelJSON.firstObject(in: fenced)?["rationale"] as? String == "a } inside a string",
               "Code fences, surrounding prose and braces inside strings are tolerated")
        let escaped = #"{"summary":"say \"hi {there}\"","n":1}"#
        expect(ModelJSON.firstObject(in: escaped)?["n"] as? Int == 1, "Escaped quotes inside strings keep the scan balanced")
        let rawNewline = "{\"goal\":\"line one\nline two\",\"headline\":\"\"}"
        expect(ModelJSON.firstObject(in: rawNewline)?["goal"] as? String == "line one\nline two",
               "Raw newlines inside string values are tolerated")
        let two = #"{"note":"first"} and {"steps":[1]}"#
        expect(ModelJSON.firstObject(in: two, where: hasSteps)?["steps"] != nil,
               "A rejected first object does not stop the search for an accepted one")
        expect(ModelJSON.firstObject(in: "I could not make a plan.") == nil, "Prose without an object yields nil")
        expect(ModelJSON.firstObject(in: #"{"steps": [ "#) == nil, "A truncated object yields nil")
        expect(ModelJSON.firstObject(in: #"a stray { brace, then {"ok":true}"#)?["ok"] as? Bool == true,
               "An unbalanced stray brace before the object is skipped")
        expect(ModelJSON.objectCandidates(in: #"x {"a":1} y {"b":{"c":2}} z"#) == [#"{"a":1}"#, #"{"b":{"c":2}}"#],
               "Candidates are the balanced top level objects in order")

        // One repair attempt, surfaced honestly when it also fails.
        var repairCalls = 0
        let repaired = await ModelJSONRepair.parse("not json", what: "plan",
            attempt: { ModelJSON.firstObject(in: $0, where: hasSteps) },
            repair: { _ in repairCalls += 1; return #"{"steps":[{"action":"open_app"}]}"# })
        expect(repaired.value != nil && repaired.repaired && repairCalls == 1, "An unreadable reply is repaired once")
        repairCalls = 0
        let clean = await ModelJSONRepair.parse(trailingBraces, what: "plan",
            attempt: { ModelJSON.firstObject(in: $0, where: hasSteps) },
            repair: { _ in repairCalls += 1; return "" })
        expect(clean.value != nil && !clean.repaired && repairCalls == 0, "A readable reply never costs a repair request")
        let failed = await ModelJSONRepair.parse("nope", what: "plan",
            attempt: { ModelJSON.firstObject(in: $0, where: hasSteps) },
            repair: { _ in repairCalls += 1; return "still nope" })
        expect(failed.value == nil && failed.failure?.contains("unreadable plan twice") == true && repairCalls == 1,
               "Two unreadable replies give a user facing failure and no retry loop")
        struct Offline: Error {}
        let transport = await ModelJSONRepair.parse("nope", what: "plan",
            attempt: { ModelJSON.firstObject(in: $0, where: hasSteps) },
            repair: { _ in throw Offline() })
        expect(transport.value == nil && transport.failure?.contains("repair request failed") == true,
               "A failed repair request is reported, not swallowed")
        expect(ModelJSONRepair.repairPrompt(for: "broken", shape: "{\"steps\":[]}").contains("broken"),
               "The repair prompt carries the broken reply")

        print("Passed \(checks) model JSON extraction and repair checks")
    }
}
