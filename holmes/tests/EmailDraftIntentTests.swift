import Foundation

@main
struct EmailDraftIntentTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        let explicit = [
            "Draft an email", "write an email to Jamie", "Compose this email",
            "Can you draft this email?", "Could you please write an email for me?",
            "Would you compose a polite email?", "help me draft an email",
            "Hey Holmes, draft this email", "Holmes, please rewrite the email",
            "Can you help me draft an e-mail?", "draft an email about the project report",
            "write an email explaining the code", "reply to this email", "respond to the email"
        ]
        for query in explicit {
            expect(EmailDraftIntent.matches(query, isEmailContext: false), "Explicit email request must route to drafts: \(query)")
            expect(EmailDraftIntent.matches(query, isEmailContext: true), "Email context keeps explicit request: \(query)")
        }
        let contextual = [
            "could you please write it for me?", "write a reply", "draft this",
            "compose a professional response", "rewrite that", "reply saying Tuesday works",
            "Can you respond for me?", "Hey Holmes, draft a reply", "please draft"
        ]
        for query in contextual {
            expect(EmailDraftIntent.matches(query, isEmailContext: true), "Trusted email context resolves pronoun: \(query)")
            expect(!EmailDraftIntent.matches(query, isEmailContext: false), "Missing context must not guess email: \(query)")
        }
        let excluded = [
            "How do I draft an email?", "Can you explain how to draft an email?",
            "Show me how to write this email", "help me understand how to compose email",
            "Please don't draft the email", "Could you not write the email?",
            "Do not compose an email", "Never draft an email", "I need to draft an email",
            "My coworker can draft the email", "I will write an email", "The email is a draft",
            "write a poem", "write a poem about email", "draft a PR", "draft a report",
            "compose a song", "write code", "reply in Slack", "reply imessage",
            "send the email", "Can you send this email?", "draft an email and send it",
            "/plan draft an email", "/ask draft an email", "", "Can an assistant draft email?"
        ]
        for query in excluded {
            expect(!EmailDraftIntent.matches(query, isEmailContext: true), "Must not route to an email draft: \(query)")
        }

        for query in ["could you click Save?", "Would you please scroll down?", "Hey Holmes, please click the button",
                      "can you fill this form?", "agent, book a table", "Click the menu", "do this for me"] {
            expect(ActionRequestIntent.matches(query), "Polite action must use guarded agent: \(query)")
        }
        for query in ["how do I click Save?", "can you explain how to click Save?", "please show me where to click",
                      "could you not click Save?", "don't send the email", "I clicked Save", "should I click Save?",
                      "agent, explain how to click Save", "/plan click Save", "what is this button?"] {
            expect(!ActionRequestIntent.matches(query), "Teaching/negation/statement must not run agent: \(query)")
        }
        expect(ActionRequestIntent.normalizedAction("Hey Holmes, could you please write it for me?") == "write it for me",
               "Greeting and polite prefixes normalize in order")
        print("Passed \(checks) email draft and polite action intent checks")
    }
}
