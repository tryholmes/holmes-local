import Foundation

// MARK: - DefaultPlaybooks
// THE FIVE. Holmes used to ship 154 heuristic playbooks; they fired randomly,
// burned a full matcher sweep over 16KB of screen text every 3s tick, and eroded
// trust. This is the deliberate replacement: five deeply-engineered automations
// chosen for (a) deterministic, works-every-time execution, (b) high-precision
// triggers with near-zero false positives, (c) real daily value.
//
//   1. meeting-join            — a meeting is starting → open its URL (app lane).
//   2. terminal-command-failed — a command failed → explain the fix out loud (teach).
//   3. github-brief            — a repo is open → 5-line project brief (read-only draft).
//   4. chat-reply              — a chat needs answering → draft the reply (never sends).
//   5. finder-downloads-sort   — Downloads is a mess → sort it (file lane, undoable).
//
// The doctrine (the "school of agentic actions"): every automation runs on the
// most deterministic backend that can do the job — structured APIs first
// (NSWorkspace / FileManager / EventKit / MCP), AX second, pixels last — and a
// matcher earns autoTriggers only when it keys off STRUCTURAL signals (app
// identity, window title, extracted entities), never off loose words in OCR.

enum DefaultPlaybooks {

    // The safety sentence every draft goal carries. Enforcement is in the tool
    // filter (ComposioCatalog); this keeps the model's intent aligned.
    static let safetyRule =
        "You may use read/fetch/search tools to gather context. You must NEVER send, post, or publish anything."

    // MARK: - Scene builder (what Holmes saw)

    static func scene(_ ctx: PlaybookContext, maxChars: Int = 1500) -> String {
        var lines: [String] = []
        lines.append("Active app: \(ctx.appName)")
        if !ctx.windowTitle.isEmpty { lines.append("Window title: \(ctx.windowTitle)") }
        if !ctx.contextType.isEmpty { lines.append("Detected context: \(ctx.contextType)") }
        for (key, value) in ctx.entities.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            lines.append("\(key): \(value)")
        }
        let excerpt = String(ctx.screenText.prefix(maxChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            lines.append("Screen text excerpt (OCR, may be noisy):\n\"\"\"\n\(excerpt)\n\"\"\"")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - All playbooks (evaluation order = priority order)

    static let all: [Playbook] = [
        meetingJoin,            // time-critical first
        terminalCommandFailed,
        githubBrief,
        chatReply,
        finderDownloadsSort,
    ]

    // MARK: - Recognition helpers

    /// Terminal emulators, matched against app NAME + window TITLE only.
    private static let terminalSignals: [String] = [
        "terminal", "iterm", "ghostty", "warp", "kitty", "alacritty",
        "wezterm", "hyper", "tabby"
    ]

    private static func isTerminal(_ ctx: PlaybookContext) -> Bool {
        let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
        return terminalSignals.contains { identity.contains($0) }
    }

    /// Case-insensitive "the screen text contains any of these needles".
    private static func screenTextContainsAny(_ ctx: PlaybookContext, _ needles: [String]) -> Bool {
        let haystack = ctx.screenText.lowercased()
        return needles.contains { haystack.contains($0) }
    }

    /// Video-conferencing join URLs. A match means a real meeting link is on
    /// screen (calendar detail, invite email, or a "starting now" banner).
    private static let meetingHosts: [String] = [
        "zoom.us/j/", "zoom.us/wc/", "meet.google.com/", "teams.microsoft.com/l/meetup",
        "teams.microsoft.com/l/meeting", "teams.live.com/meet", "whereby.com/", "webex.com/meet"
    ]

    private static func detectMeetingHost(in screenText: String) -> String? {
        let haystack = screenText.lowercased()
        return meetingHosts.first(where: { haystack.contains($0) })
    }

    /// The FULL meeting URL from the screen text — the token containing a known
    /// meeting host, cleaned of trailing punctuation and given a scheme. This is
    /// what makes the join deterministic: the plan is one app-lane open_url step
    /// on this exact URL, not a pixel hunt for a Join button.
    private static func extractMeetingURL(from screenText: String) -> String? {
        guard detectMeetingHost(in: screenText) != nil else { return nil }
        for rawToken in screenText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(rawToken)
            let lower = token.lowercased()
            guard meetingHosts.contains(where: { lower.contains($0) }) else { continue }
            var url = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]<>\"'"))
            if !url.lowercased().hasPrefix("http") { url = "https://" + url }
            return url
        }
        return nil
    }

    /// EXACT special-folder title check. `contains` let "Downloads backup 2019"
    /// qualify as the Downloads folder; only the folder itself passes now.
    private static func finderWindowIsExactly(_ ctx: PlaybookContext, _ name: String) -> Bool {
        let title = ctx.windowTitle.lowercased().trimmingCharacters(in: .whitespaces)
        return title == name || title.hasPrefix(name + " — ") || title.hasPrefix(name + " - ")
    }

    /// Count of tokens that look like real loose files (`name.ext`), EXCLUDING
    /// URL-ish and version-ish tokens ("v2.1", "example.com/x") that inflated
    /// the old count on code checkouts and web content.
    private static func countFileLikeTokens(in screenText: String) -> Int {
        guard !screenText.isEmpty else { return 0 }
        let tokens = screenText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var count = 0
        for token in tokens {
            guard !token.contains("/") else { continue }              // URL/path fragment
            guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { continue }
            let ext = token[token.index(after: dot)...]
            guard (1...5).contains(ext.count),
                  ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                  ext.contains(where: { $0.isLetter }) else { continue }  // "2.1" is a version, not a file
            count += 1
        }
        return count
    }

    // MARK: - 1. Meeting Join (ACTION — AUTO, deterministic URL open)

    static let meetingJoin = Playbook(
        id: "meeting-join",
        name: "Meeting Join",
        icon: "video.badge.checkmark",
        summary: "When a video meeting is starting, opens its link for you.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard let host = DefaultPlaybooks.detectMeetingHost(in: ctx.screenText) else { return nil }
            // An IMMINENCE signal is required — a link merely sitting on a page
            // must not hijack the browser. The old bare "join"/"now" needles
            // matched any page with a Join button; only unambiguous phrases stay.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "starting soon", "happening now", "is about to start",
                "in 1 minute", "in 2 minutes", "ready to join", "waiting for you to join"
            ]) else { return nil }
            return "meeting|" + host
        },
        makeGoal: { ctx in
            if let url = DefaultPlaybooks.extractMeetingURL(from: ctx.screenText) {
                return "A video meeting is starting. Join it by opening its URL. Produce exactly ONE step: open the URL \(url) with the \"app\" backend (action open_url). Do not click anything on screen; the URL launch is the whole job. Joining is reversible — the user can leave."
            }
            return "A video meeting that's about to start is on screen. Find its full join URL in the visible page (a zoom.us, meet.google.com, or teams.microsoft.com link) and open that URL with the \"app\" backend (action open_url) as a single step. Do not click anything on screen. Joining is reversible — the user can leave."
        },
        makeTitle: { _ in "Join the meeting" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 2. Terminal Command Failed (TEACH — AUTO, zero mutation)

    static let terminalCommandFailed = Playbook(
        id: "terminal-command-failed",
        name: "Terminal Command Help",
        icon: "terminal",
        summary: "A failed command in your terminal → explains the error and the fix out loud.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) else { return nil }
            // Exact failure strings ONLY. The old generic "error:" / "fatal:"
            // needles matched compiler warnings and ordinary output; each of
            // these is something a shell prints exclusively on real failure.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "command not found", "no such file or directory", "permission denied",
                "exited with code", "returned exit code", "non-zero exit",
                "npm err", "segmentation fault", "cannot execute"
            ]) else { return nil }
            return "term-fail|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "My terminal shows a command that just failed. In one or two spoken sentences, explain why it failed and suggest the exact command or flag that would fix it. Keep it short and spoken; point at the failing line if it helps."
        },
        makeTitle: { _ in "Explain the failure" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 3. GitHub Brief (DRAFT — AUTO, read-only)

    static let githubBrief = Playbook(
        id: "github-brief",
        name: "GitHub Brief",
        icon: "arrow.triangle.branch",
        summary: "When you open a specific repo, builds a 5-line brief: what it is, open PRs/issues, next actions.",
        autoTriggers: true,
        // 30 min per repo — one brief per repo per browsing session.
        cooldownSeconds: 1800,
        composioApps: ["GITHUB"],
        usesDing: false,
        kind: .repoBrief,
        matches: { ctx in
            // Fire ONLY when a specific repo is actually open — its main page, PRs,
            // or issues — never on the dashboard/feed/notifications. Two gates:
            //
            //   1. The exact-context extractor pulled BOTH repoOwner and repoName.
            //   2. The "owner/repo" slug appears in the WINDOW TITLE — what tells
            //      "I'm ON this repo" apart from "it scrolled past in my feed".
            guard ctx.contextType.lowercased().contains("github") else { return nil }
            let owner = (ctx.entities["repoOwner"] ?? "").trimmingCharacters(in: .whitespaces)
            let repo = (ctx.entities["repoName"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !owner.isEmpty, !repo.isEmpty else { return nil }
            let slug = owner + "/" + repo
            let title = ctx.windowTitle
            guard title.localizedCaseInsensitiveContains(slug) else { return nil }
            // Belt-and-suspenders: never fire on account-wide surfaces.
            let titleL = title.lowercased()
            let nonRepoSurfaces = ["notifications", "dashboard", "your feed", "explore", "marketplace"]
            if nonRepoSurfaces.contains(where: { titleL.contains($0) }) { return nil }
            return slug
        },
        makeGoal: { ctx in
            let owner = ctx.entities["repoOwner"] ?? ""
            let repo = ctx.entities["repoName"] ?? ""
            let repoLabel = (!owner.isEmpty && !repo.isEmpty)
                ? "\(owner)/\(repo)"
                : "the repository shown on screen (read its owner/name from the screen text below — it usually appears as \"owner/repo\" in the tab title or page header)"
            return """
            The user is looking at the GitHub repository \(repoLabel). Give them a fast, at-a-glance project brief.

            What Holmes saw on screen:
            \(scene(ctx, maxChars: 600))

            Do the MINIMUM work: at most 3 tool calls total, then STOP calling tools and write the brief. Fetch the repo plus its open pull requests and open issues in as few calls as possible — when only Composio meta tools are offered, call COMPOSIO_SEARCH_TOOLS ONCE for GITHUB, then batch the read-only slugs (e.g. GITHUB_GET_A_REPOSITORY, GITHUB_LIST_ISSUES) into a single COMPOSIO_MULTI_EXECUTE_TOOL call.

            Then write a brief of about 5 short lines, in this shape (one line each):
            - What it is — one sentence: purpose + main language/stack.
            - Open PRs — the count, then the 1-2 most notable (e.g. "7 open — #42 auth refactor, #38 CI fix").
            - Open issues — the count, then what's hot or recurring.
            - Next actions — up to 3 concrete suggestions, one per line (e.g. "Review PR #42 — touches auth, waiting 5 days").

            If GitHub tools are unavailable, build the brief from the screen text and mark the unverified parts.

            Respond with ONLY the brief — those lines and nothing else. Do NOT narrate your steps, do NOT write "let me…" or "now let me…", do NOT explain which tools you are calling or what you found before the brief, and do NOT wrap it in markdown fences.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let owner = (ctx.entities["repoOwner"] ?? "").trimmingCharacters(in: .whitespaces)
            let repo = (ctx.entities["repoName"] ?? "").trimmingCharacters(in: .whitespaces)
            if !owner.isEmpty, !repo.isEmpty { return "Brief — \(owner)/\(repo)" }
            return "GitHub Brief"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 4. Chat Reply (DRAFT — CONFIRM, never sends)

    static let chatReply = Playbook(
        id: "chat-reply",
        name: "Chat Reply",
        icon: "bubble.left.and.bubble.right",
        summary: "Drafts replies for iMessage, Discord, and Slack in the conversation's tone.",
        autoTriggers: true,
        cooldownSeconds: 120,
        composioApps: [],
        usesDing: false,
        kind: .chatReply,
        matches: { ctx in
            // EXACT app-name token gate — the old substring test on
            // contextType+appName let any app whose title mentioned "message"
            // qualify. A chat surface is one of these actual clients.
            let chatApps: Set<String> = ["messages", "discord", "slack", "whatsapp", "telegram", "signal"]
            let appTokens = Set(
                ctx.appName.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            guard !appTokens.isDisjoint(with: chatApps) else { return nil }
            // A REAL contact extracted from the AX tree / DOM — never OCR guess.
            guard let contact = ctx.entities["contact"], !contact.isEmpty else { return nil }
            return contact
        },
        makeGoal: { ctx in
            let contact = ctx.entities["contact"] ?? "the contact"
            return """
            Holmes noticed an open conversation with \(contact) in \(ctx.appName) that looks like it needs a reply.

            What Holmes saw on screen:
            \(scene(ctx))

            Your task: draft a reply to \(contact)'s most recent message that matches the conversation's existing tone and rhythm — if it's casual, keep it short and natural (contractions, lowercase vibes fine); if it's a work thread, keep it friendly but tight. Answer what was actually asked; don't over-explain, and never sound like an assistant wrote it. If the last message contains a question about plans or availability, answer it directly.

            Return ONLY the reply text — no quotes around it, no "Reply:" label.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let contact = ctx.entities["contact"] ?? "chat"
            return "Reply to \(contact)"
        },
        makeTarget: { ctx in .typeIntoApp(appName: ctx.appName) }
    )

    // MARK: - 5. Finder Downloads Sort (ACTION — CONFIRM, file lane, undoable)

    static let finderDownloadsSort = Playbook(
        id: "finder-downloads-sort",
        name: "Downloads Sorter",
        icon: "arrow.down.circle",
        summary: "When your Downloads folder is full of loose files, sorts them into type subfolders.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            // The window must BE the Downloads folder, not merely contain the word.
            guard DefaultPlaybooks.finderWindowIsExactly(ctx, "downloads") else { return nil }
            // ≥10 genuinely file-shaped tokens (URL/version tokens excluded) —
            // a folder with three files doesn't need an intervention.
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 10 else { return nil }
            return "downloads"
        },
        makeGoal: { _ in
            "The Downloads folder is open in Finder and full of loose files. Sort them into type-based subfolders inside ~/Downloads — e.g. Images, Documents, Archives, Installers, Media — creating each subfolder as needed. Every step MUST use the \"file\" backend (create the folder, then move_file each file); never click or drag in Finder, never use the computer backend, and never delete anything. Each move must be individually undoable."
        },
        makeTitle: { _ in "Sort Downloads" },
        makeTarget: { _ in .clipboard }
    )
}
