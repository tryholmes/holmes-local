import Foundation

// MARK: - DefaultPlaybooks
// The built-in proactive automations. Each playbook is declarative: a matcher over
// the live PlaybookContext, a goal prompt for the draft-only agent pass, and a
// target describing where the approved draft should land. Every goal ends with the
// draft-never-send safety sentence — and the tool policy in ComposioCatalog enforces
// it regardless of what the prompt says.

enum DefaultPlaybooks {

    // The safety sentence every goal carries. Enforcement is in the tool filter;
    // this just keeps the model's intent aligned with what it's allowed to do.
    private static let safetyRule =
        "You may use read/fetch/search tools to gather context. You must NEVER send, post, or publish anything."

    // MARK: - Scene builder (what Holmes saw)

    private static func scene(_ ctx: PlaybookContext, maxChars: Int = 1500) -> String {
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
        emailReply, promptCoach, githubBrief, meetingPrep, linkedInPost, chatReply, aiResearch,
        morningBrief, emailTriage,
        followUpChaser, prRadar, scheduleGuard, eveningWrapup,

        // Autonomy — email & calendar surfaces (specific signals first)
        acceptCalendarInvite, archiveNewsletter, replyAndStage,

        // Autonomy — web surfaces (a consent banner is dismissed before richer help)
        cookieBannerDismiss, meetingJoin, formFieldGuidance, prReviewBrief,
        closeDuplicateTabs, spreadsheetInsight, docSummarize, shortcutSuggestion,

        // Autonomy — desktop/screenshots
        renameScreenshots,

        // Autonomy — a modal save-changes dialog (teach; never presses Save)
        saveFilePrompt,

        // Autonomy — coding TEACH (specific: conflicts, then terminal, then IDE
        // errors) BEFORE the general codingCopilot fallback
        gitConflictHelp, terminalCommandFailed, codingErrorHelp,

        // Autonomy — Finder ACTION (special folders first, then generic organizers)
        emptyTrash, finderDownloadsSort, desktopDeclutter, organizeMessyFolder,

        finderOrganizer, codingCopilot
    ]

    // MARK: - Autonomy scenario heuristics (shared by the two action/teach playbooks)

    /// A rough count of "loose files" visible in a Finder window, from the OCR
    /// text: tokens that look like `name.ext` with a short, alphanumeric
    /// extension. Deliberately generous and heuristic — the Finder Organizer is
    /// an opt-in CONFIRM playbook, so a loose threshold is fine.
    private static func countFileLikeTokens(in screenText: String) -> Int {
        guard !screenText.isEmpty else { return 0 }
        let tokens = screenText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var count = 0
        for token in tokens {
            guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { continue }
            let ext = token[token.index(after: dot)...]
            guard (1...5).contains(ext.count),
                  ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                  ext.contains(where: { $0.isLetter }) else { continue }
            count += 1
        }
        return count
    }

    /// True when the screen text carries a compiler/runtime diagnostic worth
    /// explaining. Strong, whole-signal markers only (checked case-insensitively)
    /// so ordinary prose doesn't read as an error.
    private static func screenHasDiagnostic(_ screenText: String) -> Bool {
        guard !screenText.isEmpty else { return false }
        let haystack = screenText.lowercased()
        let markers = [
            "error", "exception", "traceback", "cannot find", "undefined",
            "failed", "fatal", "unresolved", "segmentation fault", "panic:",
            "syntaxerror", "referenceerror", "typeerror", "build failed"
        ]
        return markers.contains { haystack.contains($0) }
    }

    /// App-name/window signals that identify a code editor / IDE / terminal.
    /// Matched against app NAME + window TITLE only (never OCR body) so a web
    /// page merely mentioning an editor can't qualify.
    private static let editorSignals: [String] = [
        "xcode", "visual studio code", "vscode", "code", "cursor", "zed",
        "sublime", "nova", "jetbrains", "intellij", "pycharm", "webstorm",
        "goland", "clion", "rider", "android studio", "fleet",
        "terminal", "iterm", "ghostty", "warp", "kitty", "alacritty",
        "neovim", "nvim", "vim", "emacs"
    ]

    // MARK: - Recognition helpers (shared by the autonomy scenarios below)

    /// App names that identify a web browser. Matched on the app NAME so a page
    /// that merely mentions "Chrome" can't read as a browser surface.
    private static let browserSignals: [String] = [
        "safari", "chrome", "arc", "firefox", "edge", "brave", "opera",
        "vivaldi", "chromium", "orion", "duckduckgo", "sidekick", "zen browser"
    ]

    /// True when the frontmost surface is a web browser (by app name, or the
    /// classifier's `browsing` context type).
    private static func isBrowser(_ ctx: PlaybookContext) -> Bool {
        let app = ctx.appName.lowercased()
        if browserSignals.contains(where: { app.contains($0) }) { return true }
        return ctx.contextType.lowercased() == "browsing"
    }

    /// Terminal emulators — the subset of `editorSignals` that are shells, so a
    /// terminal-only scenario doesn't also fire inside a GUI IDE.
    private static let terminalSignals: [String] = [
        "terminal", "iterm", "ghostty", "warp", "kitty", "alacritty",
        "wezterm", "hyper", "tabby"
    ]

    private static func isTerminal(_ ctx: PlaybookContext) -> Bool {
        let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
        return terminalSignals.contains { identity.contains($0) }
    }

    /// A GUI code editor / IDE (an `editorSignals` match that is NOT a terminal).
    private static func isEditorOrIDE(_ ctx: PlaybookContext) -> Bool {
        let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
        return editorSignals.contains(where: { identity.contains($0) }) && !isTerminal(ctx)
    }

    /// Case-insensitive "the OCR text contains any of these needles".
    private static func screenTextContainsAny(_ ctx: PlaybookContext, _ needles: [String]) -> Bool {
        let haystack = ctx.screenText.lowercased()
        return needles.contains { haystack.contains($0) }
    }

    /// True when the frontmost surface is a genuine email client / webmail — the
    /// same word-boundary token test the Email Reply matcher uses, factored out.
    private static func isEmailSurface(_ ctx: PlaybookContext) -> Bool {
        if ctx.contextType.lowercased().contains("email") { return true }
        let tokens = Set(
            (ctx.appName + " " + ctx.windowTitle).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        return tokens.contains("mail") || tokens.contains("gmail") || tokens.contains("outlook")
    }

    /// A stable per-email key for cooldowns: sender|subject when known, else the
    /// window title. Never the degenerate "|" (two different emails would share
    /// one cooldown), so returns nil when nothing identifies the message.
    private static func emailKey(_ ctx: PlaybookContext) -> String? {
        let sender = (ctx.entities["sender"] ?? "").trimmingCharacters(in: .whitespaces)
        let subject = (ctx.entities["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        if !sender.isEmpty || !subject.isEmpty { return sender + "|" + subject }
        let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : "title|" + title
    }

    /// The most-repeated OCR line, a cheap proxy for "many duplicate browser
    /// tabs" (identical tab titles render as repeated short lines). Lines are
    /// bounded in length so body prose and blank lines don't dominate.
    private static func maxRepeatedLineCount(in screenText: String) -> Int {
        guard !screenText.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for rawLine in screenText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.count >= 6, line.count <= 60 else { continue }
            counts[line, default: 0] += 1
        }
        return counts.values.max() ?? 0
    }

    /// Video-conferencing join URLs. A match means an imminent-meeting link is
    /// visible on screen (calendar detail, email, or a "starting now" banner).
    private static let meetingHosts: [String] = [
        "zoom.us/j/", "zoom.us/wc/", "meet.google.com/", "teams.microsoft.com/l/meetup",
        "teams.microsoft.com/l/meeting", "teams.live.com/meet", "whereby.com/", "webex.com/meet"
    ]

    private static func detectMeetingHost(in screenText: String) -> String? {
        let haystack = screenText.lowercased()
        return meetingHosts.first(where: { haystack.contains($0) })
    }

    /// True when the OCR shows a default, date-stamped screenshot filename
    /// ("Screenshot 2026-07-23 at 10.14.32.png", "Screen Shot 20…", "CleanShot").
    private static func hasDefaultScreenshotName(_ screenText: String) -> Bool {
        let haystack = screenText.lowercased()
        return haystack.contains("screenshot 20")
            || haystack.contains("screen shot 20")
            || haystack.contains("cleanshot")
    }

    /// The three special Finder folders each owned by a dedicated playbook, so
    /// the generic organizers can stand back from them.
    private static func finderWindowIs(_ ctx: PlaybookContext, _ names: [String]) -> Bool {
        let title = ctx.windowTitle.lowercased()
        return names.contains { title == $0 || title.hasPrefix($0 + " ") || title.contains($0) }
    }

    private static func isSpecialFinderFolder(_ ctx: PlaybookContext) -> Bool {
        finderWindowIs(ctx, ["downloads", "desktop", "trash", "bin"])
    }

    /// A spreadsheet surface — Numbers/Excel, or Google Sheets in a browser.
    private static func isSpreadsheet(_ ctx: PlaybookContext) -> Bool {
        let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
        if identity.contains("numbers") || identity.contains("excel") { return true }
        if isBrowser(ctx),
           identity.contains("google sheets") || identity.contains("- sheets")
            || ctx.screenText.lowercased().contains("google sheets") {
            return true
        }
        return false
    }

    // MARK: - 1. Email Reply

    static let emailReply = Playbook(
        id: "email-reply",
        name: "Email Reply",
        icon: "envelope.badge",
        summary: "Drafts a grounded reply when you're reading or composing an email.",
        autoTriggers: true,
        cooldownSeconds: 180,
        composioApps: ["GMAIL"],
        usesDing: false,
        kind: .emailReply,
        matches: { ctx in
            let sender = (ctx.entities["sender"] ?? "").trimmingCharacters(in: .whitespaces)
            let subject = (ctx.entities["subject"] ?? "").trimmingCharacters(in: .whitespaces)
            // Genuine email required — otherwise a bare terminal with a stray name
            // in its OCR (the "Reply to Ada" on a Ghostty screen bug) matches and
            // hallucinates a reply. Two ways to qualify:
            //   • the classifier says this is an email AND we actually pulled a
            //     real sender/subject, or
            //   • the app/window is unmistakably an email client (checked on the
            //     app NAME + window TITLE only, never OCR body text, so a terminal
            //     showing the word "mail" can't sneak through).
            let isEmailContext = ctx.contextType.lowercased().contains("email")
            // App NAME + window TITLE only (never OCR body). Match "mail" as a
            // whole token, not a bare substring, so "Mailchimp Campaigns" or a
            // page mentioning "hotmail" can't read as an email client and burn a
            // Claude/MCP run. Real clients ("Mail", "Gmail", "Proton Mail",
            // "Outlook") still qualify via a word-boundary token.
            let clientHaystack = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let clientTokens = Set(
                clientHaystack
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            let isEmailClient = clientTokens.contains("mail")
                || clientTokens.contains("gmail")
                || clientTokens.contains("outlook")
            let genuineEmail = (isEmailContext && (!sender.isEmpty || !subject.isEmpty)) || isEmailClient
            guard genuineEmail else { return nil }
            if !sender.isEmpty || !subject.isEmpty { return sender + "|" + subject }
            // Email client but no extractable entities: never use the degenerate
            // "|" key (it would make two different emails share one cooldown, and
            // flip-flopping extraction would double-fire one email). Key on the
            // window title instead; if that's empty too, don't auto-trigger.
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : "title|" + title
        },
        makeGoal: { ctx in
            let sender = ctx.entities["sender"] ?? "unknown"
            let subject = ctx.entities["subject"] ?? "unknown"
            return """
            Holmes may have noticed the user reading or composing an email. Before drafting anything, decide from the ON-SCREEN text whether that is actually true.

            What Holmes saw on screen:
            \(scene(ctx))

            STEP 0 — Reality check (do this FIRST, from the screen text above): Is the user genuinely viewing, reading, or composing ONE specific real email right now — an actual message with a sender, a subject, and body text visible on screen? A terminal, a chat/messaging app, a code editor, a docs or web page, an AI assistant like Claude or ChatGPT, a settings screen, or a bare inbox LIST with no message opened do NOT count. If the screen is not clearly a single open email, reply with EXACTLY the single line NOTHING_TO_REPORT and nothing else. Never invent a sender, a thread, or a conversation that is not visibly on screen.

            If (and ONLY if) the screen genuinely shows one specific email, continue:
            1. Ground the reply in that on-screen email FIRST. If Gmail tools are available, fetch the exact thread matching sender "\(sender)" / subject "\(subject)" with GMAIL_FETCH_EMAILS (and GMAIL_FETCH_MESSAGE_BY_THREAD_ID once you have a thread id) so the reply is grounded in the real conversation, not just the noisy screen excerpt. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GMAIL, then run those read-only slugs via COMPOSIO_MULTI_EXECUTE_TOOL. If no Gmail tools are available, work from the screen text above. If Gmail returns no thread that matches the email on screen, reply with EXACTLY NOTHING_TO_REPORT rather than guessing.
            2. Write a reply in the user's likely tone — mirror the formality of the thread; concise, warm, no boilerplate. Answer the sender's actual questions and address their asks; don't restate their email back to them.
            3. If Gmail tools are reachable, ALSO save the reply into the user's Gmail Drafts folder via GMAIL_CREATE_EMAIL_DRAFT (through COMPOSIO_MULTI_EXECUTE_TOOL when only meta tools are offered — this exact slug is sanctioned). Fill the recipient, subject, and thread id from the thread you fetched so the draft lands on the right conversation, and address it ONLY to people who actually appear in that thread. A draft cannot send itself; the user reviews it in Gmail. If Gmail tools are unreachable or the call fails, skip this step.

            Return ONLY the reply body text — no subject line, no "Here's a draft:", no markdown fences, no signature placeholders. If (and only if) the GMAIL_CREATE_EMAIL_DRAFT call succeeded, add "Saved to your Gmail Drafts" as the final line of that text.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let sender = ctx.entities["sender"] ?? ""
            if !sender.isEmpty { return "Reply to \(sender)" }
            let subject = ctx.entities["subject"] ?? ""
            if !subject.isEmpty { return "Reply — \(subject)" }
            return "Email reply draft"
        },
        // The agent also saves the reply as a Gmail draft (the one sanctioned
        // autonomous write), so the card shows the Gmail-drafts affordance.
        makeTarget: { _ in .remoteDraft(urlString: nil) }
    )

    // MARK: - 2. Prompt Coach

    static let promptCoach = Playbook(
        id: "prompt-coach",
        name: "Prompt Coach",
        icon: "wand.and.stars",
        summary: "Rewrites your in-progress AI prompt to get a dramatically better answer.",
        autoTriggers: true,
        cooldownSeconds: 90,
        composioApps: [],
        usesDing: true,
        kind: .promptSuggestion,
        matches: { ctx in
            let haystack = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isAIApp = haystack.contains("claude") || haystack.contains("chatgpt") || haystack.contains("gemini")
            // Fire on any real in-progress prompt of 8+ chars (trimmed). The old
            // >40 gate meant a short question like "how to make a car?" (18 chars)
            // never triggered the coach at all.
            guard isAIApp,
                  let promptText = ctx.entities["promptText"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  promptText.count >= 8
            else { return nil }
            // Key on the conversation SURFACE, not the text: a prefix-of-prompt key
            // minted a fresh cooldown entry every time the user paused typing,
            // producing repeated glow+ding cycles for one prompt composition.
            let platform = ctx.entities["platform"] ?? ctx.appName
            return platform + "|" + ctx.windowTitle
        },
        makeGoal: { ctx in
            let promptText = ctx.entities["promptText"] ?? ""
            return """
            Holmes noticed the user mid-typing a prompt into \(ctx.appName) and wants to hand them a dramatically better version of it.

            The user's in-progress prompt:
            \"\"\"
            \(String(promptText.prefix(1500)))
            \"\"\"

            Surrounding screen context, in case it reveals what they're working on:
            \(scene(ctx, maxChars: 600))

            ALWAYS return an improved prompt — even when the user's draft is short, vague, or only a few words (e.g. "how to make a car?"). Never refuse, never ask a clarifying question back, never return the draft unchanged. Rewrite it to be dramatically better while preserving the user's exact intent and every concrete fact they included:
            - Make it specific: name the subject, the constraints, and clear success criteria that obviously fit what the user wants.
            - Add structure: a short role/context line, the actual task spelled out, and the desired output format (length, depth, tone, sections).
            - When the draft is thin, flesh it out with the reasonable, on-topic scope a knowledgeable person would have meant — but do NOT invent requirements that contradict what they wrote.
            - Keep the result a PROMPT the user can send to an AI, not an answer to their question.

            Return ONLY the improved prompt text, ready to paste in place of the original. No preamble, no explanation of what you changed, no quotes around it.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Improved prompt" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 3. GitHub Brief

    static let githubBrief = Playbook(
        id: "github-brief",
        name: "GitHub Brief",
        icon: "arrow.triangle.branch",
        summary: "When you open a specific repo, builds a 5-line brief: what it is, open PRs/issues, next actions.",
        autoTriggers: true,
        // 30 min per repo — a single brief per repo per browsing session, never a
        // re-fire while you scroll around inside it.
        cooldownSeconds: 1800,
        composioApps: ["GITHUB"],
        usesDing: false,
        kind: .repoBrief,
        matches: { ctx in
            // Fire ONLY when a specific repo is actually open — its main page, PRs,
            // or issues — never on the dashboard/feed/notifications. Two gates:
            //
            //   1. The exact-context extractor pulled BOTH repoOwner and repoName.
            //      (On the feed/dashboard there is no single repo, so these are
            //      empty.)
            //   2. The "owner/repo" slug appears in the WINDOW TITLE. A real repo /
            //      PR / issue tab is titled "…owner/repo…"; the feed, dashboard, and
            //      notifications tabs are titled just "GitHub"/"Dashboard"/
            //      "Notifications" and only MENTION repos (e.g. superset-sh/superset)
            //      in the activity list. Requiring the slug in the title is what
            //      tells "I'm ON this repo" apart from "it scrolled past in my feed"
            //      — the OCR-body fallback that made the brief fire on any repo name.
            guard ctx.contextType.lowercased().contains("github") else { return nil }
            let owner = (ctx.entities["repoOwner"] ?? "").trimmingCharacters(in: .whitespaces)
            let repo = (ctx.entities["repoName"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !owner.isEmpty, !repo.isEmpty else { return nil }
            let slug = owner + "/" + repo
            let title = ctx.windowTitle
            guard title.localizedCaseInsensitiveContains(slug) else { return nil }
            // Belt-and-suspenders: never fire on the account-wide surfaces, even if
            // a repo slug happened to leak into the title.
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
            // Show the real "owner/repo" when known; a clean fallback otherwise —
            // never the "?/?" the old unconditional interpolation produced.
            if !owner.isEmpty, !repo.isEmpty { return "Brief — \(owner)/\(repo)" }
            return "GitHub Brief"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 4. Meeting Prep

    static let meetingPrep = Playbook(
        id: "meeting-prep",
        name: "Meeting Prep",
        icon: "calendar.badge.clock",
        summary: "Prepares a 60-second briefing sheet before your next meeting.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: ["GOOGLECALENDAR", "GMAIL"],
        usesDing: false,
        kind: .meetingPrep,
        matches: { ctx in
            let eventId = ctx.entities["eventId"] ?? ""
            let eventTitle = ctx.entities["eventTitle"] ?? ""
            guard !eventId.isEmpty || !eventTitle.isEmpty else { return nil }
            return eventId.isEmpty ? eventTitle : eventId
        },
        makeGoal: { ctx in
            let eventTitle = ctx.entities["eventTitle"] ?? "the upcoming meeting"
            let eventId = ctx.entities["eventId"] ?? ""
            return """
            Holmes noticed the user has a meeting starting soon: "\(eventTitle)"\(eventId.isEmpty ? "" : " (event id: \(eventId))"). Prepare them before they walk in.

            What Holmes saw on screen:
            \(scene(ctx, maxChars: 600))

            Your task: use calendar and Gmail read tools to gather context, then produce a prep sheet. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GOOGLECALENDAR and GMAIL, then run read-only slugs (e.g. GOOGLECALENDAR_FIND_EVENT, GMAIL_FETCH_EMAILS) via COMPOSIO_MULTI_EXECUTE_TOOL:
            1. WHO — the attendees, and for each anything relevant Holmes can find (role if inferable, last thing they emailed the user about).
            2. AGENDA GUESS — from the event title/description and recent threads, what this meeting is most likely about.
            3. TALKING POINTS — 3-5 points the user should be ready to speak to.
            4. OPEN ITEMS — unanswered emails, pending asks, or loose ends with these attendees that could come up.

            Keep it scannable — the user has 60 seconds. If calendar/Gmail tools are unavailable, build the best sheet you can from the screen context and label guesses as guesses.

            Return ONLY the prep sheet.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let eventTitle = ctx.entities["eventTitle"] ?? "next meeting"
            return "Prep — \(eventTitle)"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 5. LinkedIn Post

    static let linkedInPost = Playbook(
        id: "linkedin-post",
        name: "LinkedIn Post",
        icon: "text.badge.checkmark",
        summary: "Drafts an authentic LinkedIn post grounded in what's on your screen.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: ["LINKEDIN"],
        usesDing: false,
        kind: .linkedInPost,
        matches: { ctx in
            let haystack = (ctx.appName + " " + ctx.windowTitle).lowercased()
            return haystack.contains("linkedin") ? "linkedin" : nil
        },
        makeGoal: { ctx in
            """
            Holmes noticed the user on LinkedIn and wants to hand them a post draft worth publishing.

            What Holmes saw on screen:
            \(scene(ctx))

            Your task: draft an authentic, non-cringe LinkedIn post grounded in what's actually on screen (a topic they're reading about, something they're commenting on, their own profile activity). Rules:
            - Write in the user's first person, like a real human — specific and concrete, one clear idea.
            - Open with a real observation, not a hook formula. No "I'm humbled/thrilled to announce", no engagement bait, no hashtag walls (2 relevant hashtags max, or none), no emoji spam.
            - Short paragraphs, 80-150 words total. End with a genuine question or takeaway only if it earns its place.

            Return ONLY the post text.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "LinkedIn post draft" },
        makeTarget: { ctx in .typeIntoApp(appName: ctx.appName) }
    )

    // MARK: - 6. Chat Reply

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
            let haystack = (ctx.contextType + " " + ctx.appName).lowercased()
            let isChat = haystack.contains("message") || haystack.contains("discord") || haystack.contains("slack")
            guard isChat,
                  let contact = ctx.entities["contact"],
                  !contact.isEmpty
            else { return nil }
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

    // MARK: - 7. AI Research (manual only)

    static let aiResearch = Playbook(
        id: "ai-research",
        name: "AI Research",
        icon: "magnifyingglass.circle",
        summary: "On demand: researches the question on screen and returns a sourced answer.",
        autoTriggers: false,
        cooldownSeconds: 0,
        composioApps: ["PERPLEXITYAI", "COMPOSIO_SEARCH"],
        usesDing: false,
        kind: .aiAnswer,
        matches: { _ in nil },   // manual only — never auto-fires
        makeGoal: { ctx in
            let promptText = ctx.entities["promptText"] ?? ""
            let question = promptText.isEmpty
                ? "The question is whatever the screen text below is centrally about — infer it before researching."
                : "The question: \"\(String(promptText.prefix(500)))\""
            return """
            The user asked Holmes to research what they're looking at.

            \(question)

            What Holmes saw on screen:
            \(scene(ctx))

            Your task: research this question using any available search or AI tools (Perplexity, Composio search, or others). Cross-check at least two sources when the answer is factual. Then produce:
            1. A direct answer up front — no throat-clearing.
            2. Supporting detail: key facts, numbers, and nuance the user should know.
            3. SOURCES — the titles/URLs you drew from, so the user can verify.

            If tools are unavailable, answer from your own knowledge and say clearly that the answer is unverified. If sources disagree, present both sides.

            Return ONLY the answer.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let promptText = ctx.entities["promptText"] ?? ""
            if promptText.isEmpty { return "Research — \(ctx.appName)" }
            return "Research — \(String(promptText.prefix(40)))"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 8. Morning Brief (manual / autopilot only)

    static let morningBrief = Playbook(
        id: "morning-brief",
        name: "Morning Brief",
        icon: "sunrise",
        summary: "Builds a 'Your Day' digest from Gmail, Calendar, and GitHub.",
        autoTriggers: false,
        cooldownSeconds: 21600,
        composioApps: ["GMAIL", "GOOGLECALENDAR", "GITHUB"],
        usesDing: false,
        kind: .briefing,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is preparing the user's morning briefing — one crisp digest of everything that matters today, built from REAL data.

            Your task: gather with read-only tools, then write the digest. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GMAIL, GOOGLECALENDAR, and GITHUB, then run these read-only slugs via COMPOSIO_MULTI_EXECUTE_TOOL:
            - GMAIL_FETCH_EMAILS — unread and important emails from the last 24 hours.
            - GOOGLECALENDAR_EVENTS_LIST — today's events.
            - GITHUB_LIST_NOTIFICATIONS — unread notifications.

            Then produce a "Your Day" digest with exactly this shape:
            1. Three sections headed Email / Calendar / GitHub. Each section: at most 5 bullets, most important first, with the single most-important item in the section starred (★). If a source is empty or unreachable, say so in one bullet.
            2. A closing "Top 3 priorities" list — the 3 things the user should tackle first today, drawn from across all three sections, each with a short why.

            Plain text only — no markdown tables, no code fences. Scannable; the whole digest should read in under a minute.

            Return ONLY the digest.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Your Day" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 9. Email Triage (manual / autopilot only)

    static let emailTriage = Playbook(
        id: "email-triage",
        name: "Email Triage",
        icon: "tray.full",
        summary: "Sorts unread email and stages reply drafts in your Gmail Drafts folder.",
        autoTriggers: false,
        cooldownSeconds: 1500,
        composioApps: ["GMAIL"],
        usesDing: false,
        kind: .triage,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is triaging the user's inbox so they only have to touch what matters.

            Your task:
            1. Fetch unread emails from the last 24 hours with GMAIL_FETCH_EMAILS. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GMAIL, then run the slug via COMPOSIO_MULTI_EXECUTE_TOOL.
            2. Classify every message into exactly one bucket: URGENT (time-sensitive, needs the user personally, today), NEEDS REPLY (a real person is waiting on an answer), or FYI (newsletters, notifications, receipts, everything else).
            3. For up to 3 NEEDS REPLY messages, compose a reply in the user's likely tone — mirror each thread's formality; concise, warm, no boilerplate — and CREATE A GMAIL DRAFT for each via GMAIL_CREATE_EMAIL_DRAFT (this exact slug is sanctioned; a draft cannot send itself). Fill the recipient, subject, and thread id from the fetched message data so each draft lands on its thread.
            4. Never send anything. The drafts wait in the user's Gmail Drafts folder for review.

            Return a plain-text summary:
            - Counts per bucket, e.g. "2 urgent · 3 need replies · 9 FYI".
            - One line per created draft: "Draft ready for <sender>: <subject>".
            - The URGENT items, one line each, with why each is urgent.

            Return ONLY the summary.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Inbox triage" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 10. Follow-up Chaser (manual / autopilot only)

    static let followUpChaser = Playbook(
        id: "follow-up-chaser",
        name: "Follow-up Chaser",
        icon: "arrow.uturn.left.circle",
        summary: "Finds sent emails that never got a reply and stages polite nudge drafts.",
        autoTriggers: false,
        cooldownSeconds: 21600,
        composioApps: ["GMAIL"],
        usesDing: false,
        kind: .followUp,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is chasing the threads other people owe the user an answer on — sent mail that never got a reply.

            Your task:
            1. Fetch the user's sent mail from 3 to 14 days ago with GMAIL_FETCH_EMAILS using the Gmail query "in:sent older_than:3d newer_than:14d". If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GMAIL, then run the slugs via COMPOSIO_MULTI_EXECUTE_TOOL. Where a thread is ambiguous, confirm it with GMAIL_FETCH_MESSAGE_BY_THREAD_ID.
            2. Identify the threads where the USER sent the last message and nobody replied. From those, pick up to 3 that clearly await a response — a question the user asked, a deliverable they requested, an intro left hanging. Skip newsletters, receipts, one-way announcements, scheduling confirmations, and anything that plainly needed no answer.
            3. For each picked thread, write a short, polite nudge in the user's likely tone — two or three sentences, specific to what the user is waiting on, no guilt-tripping, no "just circling back" filler — and CREATE A GMAIL DRAFT for it via GMAIL_CREATE_EMAIL_DRAFT (this exact slug is sanctioned; a draft cannot send itself). Address each draft ONLY to the thread's existing recipients exactly as they appear in the fetched thread data — never introduce an address that was not in the thread — and fill the subject and thread id from that same data so the nudge lands on its conversation.
            4. Never send anything. The drafts wait in the user's Gmail Drafts folder for review.

            Return a plain-text summary, one line per created draft: "Nudge drafted for <person>: <subject>". If no thread qualifies for a nudge, reply with EXACTLY the single line NOTHING_TO_REPORT and nothing else.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Follow-up nudges" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 11. PR Radar (manual / autopilot only)

    static let prRadar = Playbook(
        id: "pr-radar",
        name: "PR Radar",
        icon: "dot.radiowaves.left.and.right",
        summary: "Watches GitHub for PRs waiting on your review, failing checks, or new comments.",
        autoTriggers: false,
        cooldownSeconds: 2400,
        composioApps: ["GITHUB"],
        usesDing: false,
        kind: .prRadar,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is sweeping GitHub for pull requests that need the user's attention right now.

            Your task: use GitHub read-only tools. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GITHUB, then run these read-only slugs via COMPOSIO_MULTI_EXECUTE_TOOL:
            1. GITHUB_GET_THE_AUTHENTICATED_USER — learn the user's login first; every search below depends on it.
            2. GITHUB_FIND_PULL_REQUESTS — open PRs where the user's review is requested (e.g. "is:pr is:open review-requested:<login>") and the user's own open PRs (e.g. "is:pr is:open author:<login>"). Do NOT call GITHUB_SEARCH_ISSUES_AND_PULL_REQUESTS — it is rejected in draft-only mode and the call would be wasted.
            3. For the user's own open PRs, look for trouble: failing check runs (GITHUB_LIST_CHECK_RUNS_FOR_A_REF on the head ref) and new comments since the user's last activity.

            Then return a short plain-text action list, most urgent first, one line per item:
            - "Review waiting: <repo>#<n> — <title>"
            - "Checks failing: <repo>#<n> — <title>"
            - "New comments: <repo>#<n> — <title>"

            Keep it under 10 lines, no prose around it. If nothing needs the user's attention, reply with EXACTLY the single line NOTHING_TO_REPORT and nothing else.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "PR radar" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 12. Schedule Guard (manual / autopilot only)

    static let scheduleGuard = Playbook(
        id: "schedule-guard",
        name: "Schedule Guard",
        icon: "exclamationmark.shield",
        summary: "Scans the next 48 hours for overlaps, missing video links, and marathon blocks.",
        autoTriggers: false,
        cooldownSeconds: 21600,
        composioApps: ["GOOGLECALENDAR"],
        usesDing: false,
        kind: .scheduleAlert,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is auditing the user's calendar for the next 48 hours, catching trouble before it happens.

            Your task:
            1. List every event in the next 48 hours with GOOGLECALENDAR_EVENTS_LIST; use GOOGLECALENDAR_FIND_EVENT when an event needs a closer look. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GOOGLECALENDAR, then run the slugs via COMPOSIO_MULTI_EXECUTE_TOOL.
            2. Flag exactly these problems:
               - OVERLAP — two events whose times collide.
               - NO VIDEO LINK — a meeting with other attendees but no video link anywhere in it (skip solo focus blocks and all-day events).
               - MARATHON — 3 or more back-to-back meetings with no break between them.
            3. For each flag, add one concrete suggestion (e.g. "Move X 30 min later", "Add a Meet link to Y", "Block 15 min after Z to breathe").

            Return the warnings as a short plain-text list — one line per flag, suggestion on the same line or the next. If the next 48 hours look clean, reply with EXACTLY the single line NOTHING_TO_REPORT and nothing else.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Schedule check" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 13. Evening Wrap-up (manual / autopilot only)

    static let eveningWrapup = Playbook(
        id: "evening-wrapup",
        name: "Evening Wrap-up",
        icon: "moon.stars",
        summary: "Closes your day with a 5-line recap and tomorrow's top 3.",
        autoTriggers: false,
        cooldownSeconds: 21600,
        composioApps: ["GMAIL", "GOOGLECALENDAR", "GITHUB"],
        usesDing: false,
        kind: .wrapup,
        matches: { _ in nil },   // never screen-triggered — runs manually or via Autopilot
        makeGoal: { _ in
            """
            Holmes is closing out the user's day — one calm recap of what's left open and what tomorrow starts with, built from REAL data.

            Your task: gather with read-only tools, then write the recap. If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GMAIL, GOOGLECALENDAR, and GITHUB, then run these read-only slugs via COMPOSIO_MULTI_EXECUTE_TOOL:
            - GMAIL_FETCH_EMAILS — today's inbox (e.g. query "in:inbox newer_than:1d"); pick out the messages still awaiting the user's answer.
            - GOOGLECALENDAR_EVENTS_LIST — tomorrow's events; note especially the FIRST one (time + title).
            - GITHUB_LIST_NOTIFICATIONS — today's GitHub activity worth knowing about.

            Then produce a "close the day" recap of exactly 5 lines, most important first: unanswered emails (count + the one that matters most), tomorrow's first event (time + title), GitHub in one line, and the remaining lines for whatever else deserves a place. If a source is empty or unreachable, say so in its line.

            Finish with a "Tomorrow's top 3" list — the 3 things the user should hit first tomorrow, drawn from across all three sources, each with a short why.

            Always produce the recap, even when everything is quiet — an all-clear evening is still worth 5 calm lines. Plain text only — no markdown tables, no code fences.

            Return ONLY the recap.

            \(safetyRule)
            """
        },
        makeTitle: { _ in "Day wrap-up" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 14. Finder Organizer (autonomy ACTION scenario — default CONFIRM)

    /// An ACTION scenario: when the frontmost app is Finder and its window is
    /// full of loose files, Holmes proposes a plan to file them into subfolders
    /// and — on the master switch + a per-run confirm — moves them via the file
    /// system (the runner keeps a real undo). Default level CONFIRM (moving the
    /// user's files is significant); with the master switch OFF it clamps to the
    /// draft path and merely describes the plan.
    static let finderOrganizer = Playbook(
        id: "finder-organizer",
        name: "Finder Organizer",
        icon: "folder.badge.gearshape",
        summary: "When a Finder window is full of loose files, sorts them into subfolders by type/date.",
        autoTriggers: true,
        // Generous: one proposal per messy folder per browsing session, never a
        // re-fire while you poke around inside it.
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            // Needs a genuinely loose window — a handful of files isn't clutter.
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "finder-window" : "folder|" + folder
        },
        makeGoal: { _ in
            "Organize the loose files in the frontmost Finder window into subfolders by type/date, moving them via the file system."
        },
        makeTitle: { ctx in
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "Organize this folder" : "Organize \(folder)"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 15. Coding Copilot (autonomy TEACH scenario — default AUTO)

    /// A TEACH scenario: when the frontmost app is an editor/IDE/terminal and an
    /// error/diagnostic is on screen, Holmes explains what's wrong and points to
    /// the fix — spoken aloud + drawn on screen (VisualGuidance), never a
    /// mutation. Default level AUTO (nothing is changed), with the cooldown +
    /// autonomy rate budget keeping it from getting naggy.
    static let codingCopilot = Playbook(
        id: "coding-copilot",
        name: "Coding Copilot",
        icon: "curlybraces.square",
        summary: "When an error shows up in your editor or terminal, explains it aloud and points to the fix.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // Editor identity from app NAME + window TITLE only (never OCR body).
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            guard DefaultPlaybooks.editorSignals.contains(where: { identity.contains($0) }) else { return nil }
            // An actual diagnostic must be visible before Holmes pipes up.
            guard DefaultPlaybooks.screenHasDiagnostic(ctx.screenText) else { return nil }
            return "editor|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's an error or diagnostic on my screen. Explain what it means and point to where the fix goes — keep it short and spoken."
        },
        makeTitle: { _ in "Explain the error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // ═══════════════════════════════════════════════════════════════════════
    // NEW AUTONOMY SCENARIOS (recognition for the ACTION + TEACH pipelines)
    //
    // ACTION scenarios (isTeachScenario:false) hand their goal to ActionPlanner →
    // AutonomousActionRunner → BackendRouter → ComputerUseEngine/Clicky. Goals are
    // written as concrete, ordered work Clicky can carry out by driving the real
    // UI (or a structured file/API lane where a visible route is irreversible).
    // TEACH scenarios (isTeachScenario:true) hand their goal to VisualGuidance,
    // which speaks an answer and draws on screen — never a mutation.
    //
    // All use kind:.aiAnswer (no new DraftKind case → no exhaustive-switch break);
    // in draft mode (master switch OFF) they fall back to the aiAnswer draft path.
    // ═══════════════════════════════════════════════════════════════════════

    // MARK: - 16. Finder Downloads Sort (ACTION — CONFIRM)

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
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            return "downloads"
        },
        makeGoal: { _ in
            "The Downloads folder is open in Finder and full of loose files. Sort them into type-based subfolders inside Downloads — e.g. Images, Documents, Archives, Installers, Media — creating each subfolder as needed and moving every file into the matching one with the file system so each move can be undone. Do not delete anything."
        },
        makeTitle: { _ in "Sort Downloads" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 17. Desktop Declutter (ACTION — CONFIRM)

    static let desktopDeclutter = Playbook(
        id: "desktop-declutter",
        name: "Desktop Declutter",
        icon: "menubar.dock.rectangle",
        summary: "When your Desktop is buried in files and screenshots, files them away neatly.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["desktop"]) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            return "desktop"
        },
        makeGoal: { _ in
            "The Desktop is cluttered with loose files and screenshots. Move screenshot images (their names usually start with “Screenshot”, “Screen Shot”, or “CleanShot”) into ~/Pictures/Screenshots, and sort the remaining loose files into type-based subfolders on the Desktop, creating folders as needed. Move each file with the file system so every move can be undone. Do not delete anything."
        },
        makeTitle: { _ in "Tidy the Desktop" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 18. Empty Trash (ACTION — CONFIRM, irreversible)

    static let emptyTrash = Playbook(
        id: "empty-trash",
        name: "Empty Trash",
        icon: "trash",
        summary: "When the Finder Trash is full, empties it (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["trash", "bin"]) else { return nil }
            // Only when it actually holds something worth emptying.
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 3 else { return nil }
            return "trash"
        },
        makeGoal: { _ in
            "The Finder Trash is open and holding files. Empty the Trash — use Finder ▸ Empty Trash (or ⇧⌘⌫) and click Empty on the system confirmation dialog. This permanently deletes the trashed items, so it is irreversible."
        },
        makeTitle: { _ in "Empty the Trash" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 19. Cookie Banner Dismiss (ACTION — AUTO, reversible)

    static let cookieBannerDismiss = Playbook(
        id: "cookie-banner-dismiss",
        name: "Cookie Banner Dismiss",
        icon: "hand.raised.slash",
        summary: "Clears the cookie/consent banner covering a web page, choosing the least-committal option.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "accept cookies", "accept all cookies", "we value your privacy",
                "we use cookies", "this site uses cookies", "cookie policy",
                "manage cookies", "consent", "your privacy choices", "reject all",
                "necessary cookies"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "cookies|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A cookie or privacy-consent banner is covering part of this web page. Dismiss it with the least-committal option available — prefer “Reject all”, “Only necessary”, “Decline”, or a close/✕ button; if none of those exist, click “Accept”. Click exactly ONE button on the banner and nothing else on the page. This is reversible (the site can ask again)."
        },
        makeTitle: { _ in "Dismiss cookie banner" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 20. Close Duplicate Tabs (ACTION — CONFIRM)

    static let closeDuplicateTabs = Playbook(
        id: "close-duplicate-tabs",
        name: "Close Duplicate Tabs",
        icon: "rectangle.on.rectangle",
        summary: "When your browser has many duplicate tabs open, closes the extras.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            // Heuristic: the same tab title rendered several times over → duplicates.
            guard DefaultPlaybooks.maxRepeatedLineCount(in: ctx.screenText) >= 3 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "dupetabs|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This browser window has several duplicate tabs open (the same page loaded more than once). Close the redundant duplicates, keeping ONE tab per unique page and never closing the tab the user is actively viewing. Closing a tab is recoverable with ⌘⇧T, but treat this conservatively — only close tabs that are clearly exact duplicates."
        },
        makeTitle: { _ in "Close duplicate tabs" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 21. Meeting Join (ACTION — AUTO, reversible)

    static let meetingJoin = Playbook(
        id: "meeting-join",
        name: "Meeting Join",
        icon: "video.badge.checkmark",
        summary: "When a video meeting is about to start, opens and joins it for you.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard let host = DefaultPlaybooks.detectMeetingHost(in: ctx.screenText) else { return nil }
            // Require a "join now" signal so a link merely sitting on a page doesn't
            // hijack the browser — a calendar detail, an invite, or a starting banner.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "join", "starting", "happening now", "is about to start", "in 1 minute",
                "in 2 minutes", "now", "ready to join"
            ]) else { return nil }
            return "meeting|" + host
        },
        makeGoal: { _ in
            "A video meeting that’s about to start is on screen — a Zoom, Google Meet, or Microsoft Teams link with a join affordance. Open and join it now: click the visible “Join” button, or open the meeting link so it launches in the browser or the meeting app. Joining a meeting is reversible — the user can leave it."
        },
        makeTitle: { _ in "Join the meeting" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 22. Rename Screenshots (ACTION — CONFIRM)

    static let renameScreenshots = Playbook(
        id: "rename-screenshots",
        name: "Rename Screenshots",
        icon: "photo.badge.plus",
        summary: "Renames a fresh, date-stamped screenshot to a short descriptive name.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.hasDefaultScreenshotName(ctx.screenText) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "screenshot-rename|" + (title.isEmpty ? "desktop" : title)
        },
        makeGoal: { _ in
            "A screenshot with a default date-stamped name (e.g. “Screenshot 2026-07-23 at 10.14.32.png”) is in this Finder folder. Rename it to a short, descriptive, filesystem-safe name based on what the screenshot is of — infer the subject from any visible text or context. Rename it by moving the file from its old name to the new name in the same folder (keep the extension) so the rename can be undone. Do not move it out of the folder or delete it."
        },
        makeTitle: { _ in "Rename screenshot" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 23. Archive Newsletter (ACTION — CONFIRM, reversible)

    static let archiveNewsletter = Playbook(
        id: "archive-newsletter",
        name: "Archive Newsletter",
        icon: "archivebox",
        summary: "When you open a newsletter or promo email, archives it out of your inbox.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            // Marketing / bulk-mail tells, not a personal message.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "unsubscribe", "view in browser", "view this email in your browser",
                "you are receiving this", "you're receiving this", "manage preferences",
                "update your preferences", "newsletter", "no longer wish to receive"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "archive|" + key
        },
        makeGoal: { _ in
            "The open email is a newsletter or promotional message (it carries an Unsubscribe link and marketing content). Archive it out of the inbox — click the Archive button, or press “e” in Gmail. Archiving is reversible: the message stays in All Mail / Archive. Do NOT delete it, and do NOT click Unsubscribe."
        },
        makeTitle: { _ in "Archive newsletter" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 24. Reply and Stage (ACTION — CONFIRM, never sends)

    static let replyAndStage = Playbook(
        id: "reply-and-stage",
        name: "Reply & Stage",
        icon: "arrowshape.turn.up.left",
        summary: "When an email asks you a question, drafts a reply into the compose box (never sends).",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            // Must actually pose a question or request awaiting an answer.
            let hay = ctx.screenText.lowercased()
            guard hay.contains("?") || DefaultPlaybooks.screenTextContainsAny(ctx, [
                "could you", "can you", "would you", "let me know", "please advise",
                "what do you think", "are you available", "any update", "get back to me"
            ]) else { return nil }
            // Don't collide with bulk mail — that's the archive scenario.
            guard !DefaultPlaybooks.screenTextContainsAny(ctx, ["unsubscribe", "view in browser"]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "reply-stage|" + key
        },
        makeGoal: { _ in
            "The open email asks the user a question and needs a reply. Click Reply, then type a concise, appropriately-toned reply in the user's voice into the compose box — answer what was actually asked, no boilerplate. Do NOT press Send: leave the drafted reply staged in the compose box for the user to review and send themselves. Address the reply only to people already on the thread; never introduce a new recipient."
        },
        makeTitle: { _ in "Draft a reply" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 25. Save-File Prompt (TEACH — points at Save, never clicks it)

    static let saveFilePrompt = Playbook(
        id: "save-file-prompt",
        name: "Save Prompt Guide",
        icon: "square.and.arrow.down",
        summary: "When a “save changes?” dialog appears, points out Save vs Don’t Save (never clicks).",
        autoTriggers: true,
        cooldownSeconds: 120,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "do you want to save the changes", "unsaved changes", "don't save",
                "don’t save", "save changes before", "keep changes"
            ]) else { return nil }
            return "save-dialog|" + ctx.appName
        },
        makeGoal: { _ in
            "A “save changes?” dialog is on screen. Point at the Save button and briefly explain what each choice does — Save keeps the work, Don't Save discards it, Cancel goes back. Do NOT click anything: saving (or discarding) is irreversible and the choice is the user's alone."
        },
        makeTitle: { _ in "Save or discard?" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 26. Accept Calendar Invite (ACTION — CONFIRM)

    static let acceptCalendarInvite = Playbook(
        id: "accept-calendar-invite",
        name: "Accept Calendar Invite",
        icon: "calendar.badge.plus",
        summary: "When a pending calendar invitation is on screen, accepts it (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // A pending invite shows the RSVP triad or an explicit invitation line.
            let hasRSVP = DefaultPlaybooks.screenTextContainsAny(ctx, ["yes", "maybe", "no"])
                && DefaultPlaybooks.screenTextContainsAny(ctx, ["maybe"])
                && DefaultPlaybooks.screenTextContainsAny(ctx, ["decline", "no"])
            let explicit = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "has invited you", "invitation from", "rsvp", "going?", "will you attend",
                "accept   maybe   decline", "yes   maybe   no"
            ])
            guard hasRSVP || explicit else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "invite|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A pending calendar invitation is on screen with Accept / Maybe / Decline (or Yes / Maybe / No) options. Accept the invitation — click “Accept” (or “Yes”). This adds the event to the user's calendar and notifies the organizer, so do only this one click."
        },
        makeTitle: { _ in "Accept the invite" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 27. Organize Messy Folder (ACTION — CONFIRM, generic Finder folder)

    static let organizeMessyFolder = Playbook(
        id: "organize-messy-folder",
        name: "Organize Messy Folder",
        icon: "folder.badge.gearshape",
        summary: "Any Finder folder buried in 8+ loose files → sorts them into subfolders by type.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            // The special folders are owned by their dedicated playbooks.
            guard !DefaultPlaybooks.isSpecialFinderFolder(ctx) else { return nil }
            // A higher bar than the general Finder Organizer (6) so a genuinely
            // messy folder is what fires this one.
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 8 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "messy-folder" : "messy|" + folder
        },
        makeGoal: { _ in
            "The frontmost Finder folder is buried in loose files of mixed types. Organize it into subfolders by type (and by date where that helps), creating each subfolder inside this folder and moving every file into the matching one with the file system so each move can be undone. Do not delete anything and do not move files out of this folder."
        },
        makeTitle: { ctx in
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "Organize this folder" : "Organize \(folder)"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 28. Coding Error Help (TEACH — IDE stack traces)

    static let codingErrorHelp = Playbook(
        id: "coding-error-help",
        name: "Coding Error Help",
        icon: "ladybug",
        summary: "A stack trace or red error in your IDE → explains it aloud and points to the fix.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // GUI IDEs only — terminals have their own scenario below.
            guard DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            // A real stack trace / red diagnostic, not merely the word "error".
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "traceback (most recent call last)", "stack trace", "at <anonymous>",
                "exception", "referenceerror", "typeerror", "syntaxerror",
                "nullpointerexception", "unresolved reference", "cannot find",
                "thread 1:", "fatal error", "panic:"
            ]) else { return nil }
            return "ide-error|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a stack trace or red error on my screen in a code editor. In one or two spoken sentences, explain what it means and the most likely cause, then draw an arrow at the line or spot where the fix goes. Keep it short and conversational."
        },
        makeTitle: { _ in "Explain this error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 29. Terminal Command Failed (TEACH)

    static let terminalCommandFailed = Playbook(
        id: "terminal-command-failed",
        name: "Terminal Command Help",
        icon: "terminal",
        summary: "A failed command in your terminal → explains the error and suggests the fix out loud.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "command not found", "no such file or directory", "permission denied",
                "non-zero exit", "exited with code", "returned exit code", "npm err",
                "fatal:", "error:", "not recognized", "cannot execute", "segmentation fault"
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

    // MARK: - 30. Git Conflict Help (TEACH)

    static let gitConflictHelp = Playbook(
        id: "git-conflict-help",
        name: "Merge Conflict Help",
        icon: "arrow.triangle.pull",
        summary: "Merge-conflict markers on screen → explains how to resolve them and points at the markers.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText
            // The canonical conflict markers. "<<<<<<<" alone is enough of a tell.
            guard hay.contains("<<<<<<<") || (hay.contains(">>>>>>>") && hay.contains("=======")) else { return nil }
            return "git-conflict|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There are Git merge-conflict markers on my screen (<<<<<<<, =======, >>>>>>>). In one or two spoken sentences, explain which side is which (HEAD vs the incoming branch) and how to resolve it, then draw at the conflict markers so I can see where to edit. Keep it short and spoken."
        },
        makeTitle: { _ in "Resolve the conflict" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 31. Form Field Guidance (TEACH)

    static let formFieldGuidance = Playbook(
        id: "form-field-guidance",
        name: "Form Field Guidance",
        icon: "exclamationmark.bubble",
        summary: "A web form with a validation error → points at the bad field and says what's wrong.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "is required", "this field is required", "please enter", "please fill",
                "invalid", "must be", "enter a valid", "does not match", "required field",
                "passwords do not match", "please select", "must contain"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "form-error|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This web form has a validation error. In one spoken sentence, say which field is wrong and what it needs, then point an arrow at that field so I can fix it. Keep it short; don't fill anything in for me."
        },
        makeTitle: { _ in "Fix the form field" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 32. PR Review Brief (TEACH)

    static let prReviewBrief = Playbook(
        id: "pr-review-brief",
        name: "PR Review Brief",
        icon: "checklist",
        summary: "A GitHub pull request → summarizes what to review and points at Files changed / Review.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let isGitHub = ctx.contextType.lowercased().contains("github")
                || ctx.screenText.lowercased().contains("github.com")
            guard isGitHub else { return nil }
            // A PR page specifically, not the repo home or an issue.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "files changed", "commits", "open a pull request", "pull request",
                "ready for review", "changes requested", "review changes", "conversation"
            ]), ctx.screenText.lowercased().contains("pull request")
                || ctx.windowTitle.lowercased().contains("pull request")
                || ctx.screenText.lowercased().contains("files changed")
            else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "pr-review|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I'm looking at a GitHub pull request. In two or three spoken sentences, tell me what this PR does and what to focus on when reviewing it, then point at the “Files changed” tab and the review button so I know where to start. Keep it brief and spoken."
        },
        makeTitle: { _ in "What to review" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 33. Doc Summarize (TEACH)

    static let docSummarize = Playbook(
        id: "doc-summarize",
        name: "Document Summary",
        icon: "doc.text.magnifyingglass",
        summary: "A long document or article on screen → offers a spoken summary and highlights key parts.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // A long reading surface: a browser article or a reader app.
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let readerApp = ["preview", "pages", "word", "notion", "notes", "books", "pdf"]
                .contains(where: { identity.contains($0) })
            guard DefaultPlaybooks.isBrowser(ctx) || readerApp else { return nil }
            // Genuinely long — enough text that a summary earns its place.
            guard ctx.screenText.count >= 2500 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "doc-summary|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a long document or article on my screen. Give me a spoken three-to-four sentence summary of what it's about and its key points, and highlight the section on screen that matters most. Keep the summary conversational — don't read the whole thing back to me."
        },
        makeTitle: { _ in "Summarize this" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 34. Spreadsheet Insight (TEACH)

    static let spreadsheetInsight = Playbook(
        id: "spreadsheet-insight",
        name: "Spreadsheet Insight",
        icon: "tablecells",
        summary: "A spreadsheet with data → speaks a quick insight and circles the notable cell or column.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isSpreadsheet(ctx) else { return nil }
            // Some actual tabular data visible (a scattering of numbers).
            let digitRuns = ctx.screenText.filter { $0.isNumber }.count
            guard digitRuns >= 12 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "sheet-insight|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a spreadsheet with data on my screen. In one or two spoken sentences, give me a quick insight about it — a trend, an outlier, or a total worth noticing — and circle the cell or column that stands out. Keep it short and spoken; don't edit anything."
        },
        makeTitle: { _ in "Spreadsheet insight" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 35. Shortcut Suggestion (TEACH)

    static let shortcutSuggestion = Playbook(
        id: "shortcut-suggestion",
        name: "Shortcut Suggestion",
        icon: "keyboard",
        summary: "When you work through menus by hand, speaks the keyboard shortcut and draws it.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // Simple heuristic: an open menu is visible (the user is clicking
            // through menus for something a shortcut would do faster). Menu bars
            // OCR as clusters of menu titles + the ⌘ glyph next to items.
            let hasMenu = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "file   edit", "edit   view", "format   view", "\u{2318}"
            ])
            let hasCommonMenuAction = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "copy", "paste", "save as", "find", "select all", "undo", "new tab"
            ])
            guard hasMenu, hasCommonMenuAction else { return nil }
            return "shortcut|" + ctx.appName
        },
        makeGoal: { _ in
            "The user is working through menus by hand to do something a keyboard shortcut would do faster. In one spoken sentence, name the exact keyboard shortcut for what they're about to do, and draw the key combo on screen. Keep it short and friendly; don't click anything for them."
        },
        makeTitle: { _ in "Try this shortcut" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )
}
