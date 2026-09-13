import Foundation

/// Opt-in local-model check. Uses only fixture text and volatile configuration;
/// never reads a browser, writes user defaults, or inserts/sends an email.
@main
struct EmailDraftLiveSmoke {
    @MainActor static func main() async throws {
        let model = ProcessInfo.processInfo.environment["HOLMES_SMOKE_MODEL"] ?? "qwen3-vl:8b-instruct"
        UserDefaults.standard.setVolatileDomain([
            "ollama.host": "http://127.0.0.1:11434", "ollama.model": model,
            "ollama.numCtx": 32768, "ollama.thinkingEnabled": false,
            "ollama.keepAlive": "10m"
        ], forName: UserDefaults.argumentDomain)
        OllamaConfig.updateReadiness(ready: true, problem: nil)
        let cases: [(String, EmailDraftInput)] = [
            ("sick-notes", EmailDraftInput(instruction: "Finish this email using its subject and any existing notes. Preserve the facts and intent of the existing text. Keep it concise and natural.", compose: nil,
                subject: "", recipient: "boss@example.com", sourceBody: "I am sick")),
            ("reported-lateness", EmailDraftInput(instruction: "Draft this email for me.", compose: nil,
                subject: "Im gonna be late", recipient: "boss@gmail.com")),
            ("specified-delay", EmailDraftInput(instruction: "Write a polite email saying I will be 15 minutes late because my train is delayed.", compose: nil,
                subject: "Running late", recipient: "manager@example.com")),
            ("self-contained", EmailDraftInput(instruction: "Could you draft an email to my boss saying I'm running late?", compose: nil)),
            ("rewrite", EmailDraftInput(instruction: "Rewrite this email more professionally and keep it short.", compose: nil,
                subject: "Project review", recipient: "alex@example.com", sourceBody: "hey alex, the report is attached. can you review it by Friday? thanks")),
            ("read-reply", EmailDraftInput(instruction: "Draft a reply saying I need to check my calendar first.", compose: nil,
                subject: "Coffee", recipient: "alex@example.com", sourceBody: "Are you free for coffee tomorrow at 3?", isReply: true))
        ]
        print("Live model: \(model), num_ctx=\(OllamaConfig.numCtx)")
        fflush(stdout)
        var completed = 0
        for (name, input) in cases {
            if let only = ProcessInfo.processInfo.environment["HOLMES_SMOKE_CASE"], name != only { continue }
            let started = Date()
            guard input.hasContent else { fatalError("Fixture was rejected: \(name)") }
            let body = try await EmailDraftText.generate(input: input) { system, user in
                let raw = try await OllamaClient.shared.complete(system: system, user: user, maxTokens: 768, asJSON: true,
                    schema: OllamaClient.objectSchema(["body": ["type": "string", "description": "The finished email body only"]]), priority: .agent)
                if (try? EmailDraftText.body(from: raw)) == nil { print("REJECTED \(name): \(raw)"); fflush(stdout) }
                return raw
            }
            print("DRAFT \(name): \(body)")
            fflush(stdout)
            if name == "reported-lateness" || name == "self-contained" {
                let lower = body.lowercased()
                guard lower.contains("late") || lower.contains("delay") else { fatalError("Lateness fact missing") }
                guard !lower.contains("as soon as"), !lower.contains("keep you updated") else {
                    fatalError("Unsupported commitment: \(body)")
                }
                guard lower.range(of: #"\b(?:traffic|train|car|accident|sick|minutes|hours|a\.m\.|p\.m\.|\d+)\b"#, options: .regularExpression) == nil else {
                    fatalError("Unsupported ETA/excuse in lateness draft: \(body)")
                }
            }
            guard !body.contains("["), !body.lowercased().contains("as an ai") else { fatalError("Placeholder/meta answer: \(body)") }
            let row: [String: Any] = ["case": name, "seconds": Date().timeIntervalSince(started), "body": body]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            completed += 1
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
        print("\(completed) live local-model email cases passed; review the printed bodies for factual quality.")
    }
}
