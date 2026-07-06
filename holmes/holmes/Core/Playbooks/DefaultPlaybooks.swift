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
        followUpChaser, prRadar, scheduleGuard, eveningWrapup
    ]

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
        summary: "Builds a crisp project brief for the repo on screen — PRs, issues, next actions.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: ["GITHUB"],
        usesDing: false,
        kind: .repoBrief,
        matches: { ctx in
            // Prefer the exact owner/repo as the key. If extraction missed it but
            // we're clearly on a GitHub surface, still fire — keyed on the window —
            // so the brief works from the on-screen repo slug rather than silently
            // never firing.
            if let owner = ctx.entities["repoOwner"], !owner.isEmpty,
               let repo = ctx.entities["repoName"], !repo.isEmpty {
                return owner + "/" + repo
            }
            guard ctx.contextType.lowercased().contains("github") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : "gh|" + title
        },
        makeGoal: { ctx in
            let owner = ctx.entities["repoOwner"] ?? ""
            let repo = ctx.entities["repoName"] ?? ""
            let repoLabel = (!owner.isEmpty && !repo.isEmpty)
                ? "\(owner)/\(repo)"
                : "the repository shown on screen (read its owner/name from the screen text below — it usually appears as \"owner/repo\" in the tab title or page header)"
            return """
            Holmes noticed the user looking at a GitHub repository and wants to hand them an instant project brief.

            What Holmes saw on screen:
            \(scene(ctx, maxChars: 800))

            Your task: use GitHub read tools (get the repo, list open pull requests, list open issues) to produce a crisp brief of \(repoLabel). If only Composio meta tools are offered, first call COMPOSIO_SEARCH_TOOLS for GITHUB, then run read-only slugs (e.g. GITHUB_GET_A_REPOSITORY, GITHUB_LIST_ISSUES) via COMPOSIO_MULTI_EXECUTE_TOOL:
            1. WHAT IT IS — one or two sentences: purpose, language/stack, rough activity level.
            2. OPEN PRs — the most notable open pull requests (number, title, why each matters). Skip bots unless significant.
            3. OPEN ISSUES — highlights only: what's hot, recurring, or blocking.
            4. NEXT ACTIONS — exactly 3 concrete suggested next actions for someone working on this repo (e.g. "Review PR #42 — touches auth and has been waiting 5 days").

            Keep the whole brief under ~250 words, scannable, with those four section headers. If GitHub tools are unavailable, produce the best brief you can from the screen text and say which parts are unverified.

            Return ONLY the brief.

            \(safetyRule)
            """
        },
        makeTitle: { ctx in
            let owner = ctx.entities["repoOwner"] ?? "?"
            let repo = ctx.entities["repoName"] ?? "?"
            return "Brief — \(owner)/\(repo)"
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
}
