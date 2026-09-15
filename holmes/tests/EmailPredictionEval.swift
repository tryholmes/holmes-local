import Foundation

/// Live evaluation of predictive email writing against the local Ollama model.
/// Uses the production prompt, parser, grounding and repair retry. Fixtures are
/// synthetic; nothing reads a browser, calendar, mailbox or user defaults.
@main
struct EmailPredictionEval {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        let model = env["HOLMES_EVAL_MODEL"] ?? "qwen3-vl:4b-instruct"
        guard let fixturePath = env["HOLMES_EVAL_FIXTURES"], let outputPath = env["HOLMES_EVAL_OUTPUT"] else {
            fatalError("HOLMES_EVAL_FIXTURES and HOLMES_EVAL_OUTPUT are required")
        }
        UserDefaults.standard.setVolatileDomain([
            "ollama.host": env["OLLAMA_HOST"] ?? "http://127.0.0.1:11434", "ollama.model": model,
            "ollama.numCtx": 8192, "ollama.thinkingEnabled": false, "ollama.keepAlive": "10m"
        ], forName: UserDefaults.argumentDomain)
        OllamaConfig.updateReadiness(ready: true, problem: nil)

        let scenarios = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath))) as! [[String: Any]]
        print("Email prediction eval: model \(model), \(scenarios.count) scenarios")
        var rows: [[String: Any]] = []
        for scenario in scenarios {
            let id = scenario["id"] as! String
            if let only = env["HOLMES_EVAL_CASE"], !only.split(separator: ",").map(String.init).contains(id) { continue }
            let context = Self.context(scenario)
            let expect = scenario["expect"] as? [String: Any] ?? [:]
            var attempts: [String] = []
            var row: [String: Any] = ["id": id]
            let started = Date()
            do {
                let prediction = try await EmailPredictionGenerator.generate(context: context) { system, user in
                    let raw = try await OllamaClient.shared.complete(system: system, user: user, maxTokens: 700, asJSON: true,
                                                                     schema: EmailPredictionPrompt.schema, priority: .agent)
                    attempts.append(raw)
                    return raw
                }
                row["parsed"] = true
                row["body"] = prediction.body
                row["subject"] = prediction.subject ?? NSNull()
                row["actions"] = prediction.actions.map { action -> [String: Any] in
                    switch action {
                    case .calendarEvent(let title, let start, let minutes):
                        return ["type": "calendarEvent", "title": title, "start": ISO8601DateFormatter().string(from: start), "minutes": minutes]
                    case .followUp(let days): return ["type": "followUp", "days": days]
                    }
                }
                row["checks"] = Self.score(prediction, expect: expect, context: context)
            } catch {
                Self.lastReasons = []
                row["parsed"] = false
                row["error"] = "\(error)"
                row["checks"] = ["parse": false, "clean": false, "grounded": false, "subject": false, "actions": false]
            }
            row["attempts"] = attempts
            row["firstAttemptValid"] = attempts.first.map { raw -> Bool in
                if case .success = EmailPredictionParser.parse(raw, context: context) { return true }
                return false
            } ?? false
            row["seconds"] = Date().timeIntervalSince(started)
            let checks = row["checks"] as! [String: Bool]
            let failed = checks.filter { !$0.value }.map(\.key).sorted()
            print("\(failed.isEmpty ? "PASS" : "FAIL") \(id) (\(String(format: "%.1f", row["seconds"] as! Double))s, \(attempts.count) call\(attempts.count == 1 ? "" : "s"))"
                  + (failed.isEmpty ? "" : " failed: " + failed.joined(separator: ", ")))
            if !failed.isEmpty {
                print("  body: " + ((row["body"] as? String) ?? (row["error"] as? String ?? "")).replacingOccurrences(of: "\n", with: "\\n"))
                if let reasons = row["reasons"] as? [String] { print("  " + reasons.joined(separator: "; ")) }
            }
            if let reasons = checks.isEmpty ? nil : Self.lastReasons, !failed.isEmpty, !reasons.isEmpty { print("  reasons: " + reasons.joined(separator: "; ")) }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
    }

    static var lastReasons: [String] = []

    static func score(_ prediction: EmailPrediction, expect: [String: Any], context: EmailPredictionContext) -> [String: Bool] {
        var reasons: [String] = []
        let body = prediction.body
        let lower = body.lowercased().replacingOccurrences(of: "’", with: "'")
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // Independent of the sanitizer: what a person would call chatter.
        var clean = true
        if let first = lines.first?.lowercased(), first.range(of: #"^(here's|here is|below is|sure|certainly|of course|absolutely|okay|great)\b"#, options: .regularExpression) != nil {
            clean = false; reasons.append("preamble")
        }
        if body.range(of: #"\[[^\]]*\]|\{[^}]*\}|<[^>]*>"#, options: .regularExpression) != nil { clean = false; reasons.append("placeholder") }
        if let last = lines.last?.lowercased(), last.range(of: #"^(best|best regards|kind regards|regards|thanks|thank you|cheers|sincerely|warmly|cordialement|saludos|viele grüße|liebe grüße|mit freundlichen grüßen|un saludo|bien à vous)\s*[,.]?$"#, options: .regularExpression) != nil {
            clean = false; reasons.append("sign off")
        }
        if lower.range(of: #"(let me know if you('d| would) like (any )?(changes|edits)|as an ai|feel free to adjust|(?m)^subject:)"#, options: .regularExpression) != nil {
            clean = false; reasons.append("commentary")
        }

        var grounded = EmailGrounding.ungrounded(body, context: context).isEmpty
        for group in expect["mustMention"] as? [[String]] ?? [] where !group.contains(where: { lower.contains($0.lowercased()) }) {
            grounded = false; reasons.append("missing one of \(group)")
        }
        let subjectLower = (prediction.subject ?? "").lowercased()
        for banned in expect["mustNotMention"] as? [String] ?? [] where lower.contains(banned.lowercased()) || subjectLower.contains(banned.lowercased()) {
            grounded = false; reasons.append("contains \"\(banned)\"")
        }

        var subjectOK = true
        if let wantsSubject = expect["subject"] as? Bool {
            subjectOK = wantsSubject ? !(prediction.subject ?? "").isEmpty : prediction.subject == nil
            if !subjectOK { reasons.append(wantsSubject ? "subject not filled" : "subject changed") }
        }

        var actionsOK = true
        let hasEvent = prediction.actions.contains { if case .calendarEvent = $0 { return true }; return false }
        let hasFollowUp = prediction.actions.contains { if case .followUp = $0 { return true }; return false }
        if let event = expect["event"] as? Bool, event != hasEvent { actionsOK = false; reasons.append(event ? "calendar event missing" : "unexpected calendar event") }
        if let follow = expect["followUp"] as? Bool, follow != hasFollowUp { actionsOK = false; reasons.append(follow ? "follow up missing" : "unexpected follow up") }
        lastReasons = reasons
        return ["parse": true, "clean": clean, "grounded": grounded, "subject": subjectOK, "actions": actionsOK]
    }

    static func context(_ scenario: [String: Any]) -> EmailPredictionContext {
        let zone = TimeZone(identifier: scenario["timeZone"] as? String ?? "America/Los_Angeles")!
        func date(_ text: String) -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            return formatter.date(from: text)!
        }
        let now = date(scenario["now"] as? String ?? "2026-09-13T10:30")
        let compose = scenario["compose"] as! [String: Any]
        let notes = compose["notes"] as? String ?? ""
        let signature = compose["signature"] as? String ?? ""
        let thread = (scenario["thread"] as? [[String: String]] ?? []).map {
            EmailThreadMessage(from: $0["from"] ?? "", fromEmail: $0["fromEmail"] ?? "", date: $0["date"] ?? "", text: $0["text"] ?? "")
        }
        let bodyText = [notes, signature.isEmpty ? "" : "--\n" + signature].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var snapshot = EmailComposeSnapshot(source: .browser, identity: "eval/" + (scenario["id"] as! String),
            provider: scenario["provider"] as? String ?? "Gmail", app: "Chrome",
            recipients: compose["recipients"] as? [String] ?? [], cc: compose["cc"] as? [String] ?? [], bcc: compose["bcc"] as? [String] ?? [],
            subject: compose["subject"] as? String ?? "", body: bodyText, bodyReadable: true, bodyIsEmpty: bodyText.isEmpty, capturedAt: now)
        snapshot.userText = notes
        snapshot.autoWritable = notes.isEmpty
        snapshot.hasSignature = !signature.isEmpty
        snapshot.hasQuote = !thread.isEmpty
        snapshot.subjectEditable = compose["subjectEditable"] as? Bool ?? true
        snapshot.isReply = !thread.isEmpty
        snapshot.threadSubject = compose["threadSubject"] as? String ?? ""
        snapshot.thread = thread
        snapshot.recipientNames = compose["recipientNames"] as? [String: String] ?? [:]

        var context = EmailPredictionContext(compose: snapshot)
        context.now = now
        context.timeZone = zone
        context.instruction = scenario["instruction"] as? String ?? ""
        if let blocks = scenario["calendar"] as? [[String: Any]] {
            context.calendarAvailable = true
            context.calendar = blocks.map {
                EmailCalendarBlock(title: $0["title"] as? String ?? "", start: date($0["start"] as! String), end: date($0["end"] as! String),
                                   isAllDay: $0["allDay"] as? Bool ?? false)
            }
        }
        context.memory = scenario["memory"] as? [String] ?? []
        context.sentSamples = (scenario["sent"] as? [[String: String]] ?? []).map {
            EmailSentSample(to: $0["to"] ?? "", subject: $0["subject"] ?? "", date: $0["date"] ?? "", text: $0["text"] ?? "")
        }
        return context
    }
}
