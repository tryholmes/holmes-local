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
        gitConflictHelp, terminalCommandFailed, codingErrorHelp, diffReviewHelp,

        // Autonomy — modal/dialog TEACH (specific system prompts explained, never clicked)
        captchaHelp, twoFactorHelp, appPermissionPromptHelp, genericErrorDialogHelp,
        passwordRequirementHelp, printDialogHelp,

        // Autonomy — web ACTION (one least-committal click each)
        youtubeSkipAd, translatePagePrompt, allowNotificationsDismiss,
        closeNewsletterPopup, softwareUpdateLater, joinZoomAudio,

        // Autonomy — web/reading TEACH
        paywallHelp, wifiTroubleshootHelp, videoCallControlsHelp,
        spreadsheetFormulaError, timezoneConvertHelp, dmgInstallDragHelp,

        // Autonomy — email ACTION (receipts archived after newsletters)
        archiveReceiptEmail,

        // Autonomy — Finder ACTION (special folders first, then generic organizers)
        emptyTrash, finderDownloadsSort, desktopDeclutter, organizeMessyFolder,

        // ═══ Autonomous task library (screen-triggered) — specific matchers
        // grouped by domain; the two general fallbacks stay LAST so a broad
        // matcher never steals a fire from a more specific one. ═══

        // Files · Finder · System
        cleanPartialDownloads, cleanDuplicateDownloads, installerCleanup,
        trashOldDownloads, downloadsMoveFinished, unzipArchives, ejectDMG,
        archiveOldScreenshots, screenshotsPileup, groupPhotosByDate,
        dedupeFiles, consolidateDuplicateFolders, batchRenamePattern,
        projectFolderFromFiles, archiveOldFiles, sortFolderByDate, sortFolderByKind,
        flagLargeFile, lowDiskCleanup, safeEjectReminder,

        // Email & Calendar
        unsubscribeBulkMail, deleteSpamEmail, declineOverlappingInvite,
        addCalendarEventFromEmail, draftMeetingDecline, forwardWithNote,
        followUpChaseStage, snoozeEmail, starImportantEmail, labelEmail,
        muteNoisyThread, clearPromotionsPileup, setOOOReply,
        summarizeEmailThread, extractActionItems, meetingOnePager,
        remindBeforeCall, doubleBookingFlag, blockFocusTime, inboxTriageSweep,

        // Browser · Web · Shopping · Research
        webCookieConsentDismiss, webGdprMinimal, webLoginAutofill,
        webShippingAddress, webFormRefill, webCouponApply, webAddToCart,
        webPriceCheck, webCompareProducts, webSmartBookmark, webReopenTab,
        webMuteAutoplay, webStaleTabCleanup, webDownloadSort, webTranslatePage,
        webReadAloud, webArticleToNotes, webThreadSummary, webResearchQuestion,

        // Coding · Terminal · GitHub (specific explainers before codingCopilot)
        mergeConflictResolve, stackTraceExplain, unhandledExceptionPoint,
        offByOnePoint, missingImportPoint, lintErrorPoint, failingTestExplain,
        terminalFailExplain, dependencyErrorExplain, apiErrorExplain,
        permissionDeniedExplain, dockerfileIssueExplain, ciFailureExplain,
        prFilesChangedBrief, todoFixmeSurface, regexExplain, gitignoreSuggest,
        menuShortcutSuggest, commitMessageDraft, unfamiliarRepoBrief,

        // Messaging · Docs · Media
        messageReplySend, linkedinMessageReply, linkedinWorkPost, tweetDraft,
        reviewReply, thankYouNote, statusUpdate, slackMentionsSummary,
        chatToTasks, callNotes, extractSteps, docProofreadFix, docFormatFix,
        docOutline, chartSuggest, formulaHelp, youtubeSummary,
        pauseMusicOnCall, lowerVolumeOnCall, musicResumeOnCallEnd,

        // General fallbacks — most permissive matchers, evaluated last
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

    // ═══════════════════════════════════════════════════════════════════════
    // 36+. EXPANDED AUTONOMY LIBRARY
    // A wider set of everyday scenarios Holmes recognizes. ACTION playbooks
    // (isTeachScenario:false) each perform ONE least-committal, reversible move;
    // TEACH playbooks (isTeachScenario:true) explain and draw on screen but never
    // mutate. All use kind:.aiAnswer, and every matcher is self-contained.
    // ═══════════════════════════════════════════════════════════════════════

    // MARK: - 36. YouTube Skip Ad (ACTION — AUTO, reversible)

    static let youtubeSkipAd = Playbook(
        id: "youtube-skip-ad",
        name: "Skip YouTube Ad",
        icon: "forward.end.alt",
        summary: "When a skippable YouTube ad is playing, clicks the Skip Ad button.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let hay = ctx.screenText.lowercased()
            guard identity.contains("youtube") || hay.contains("youtube") else { return nil }
            guard hay.contains("skip ad") || hay.contains("skip ads")
                || hay.contains("skip in") || (hay.contains("skip") && hay.contains("advertisement"))
            else { return nil }
            return "yt-skip|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "A skippable YouTube video ad is playing and a “Skip Ad” (or “Skip Ads” / “Skip”) button is visible, usually at the lower-right of the video. Click that Skip button once to skip the advertisement, and click nothing else on the page. This is reversible — it just resumes the video."
        },
        makeTitle: { _ in "Skip the ad" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 37. Translate Page (ACTION — AUTO, reversible)

    static let translatePagePrompt = Playbook(
        id: "translate-page-prompt",
        name: "Translate Page",
        icon: "character.bubble",
        summary: "When the browser offers to translate a foreign-language page, accepts it.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "translate this page", "translate to english", "translate page",
                "translate to your language", "this page is in", "would you like to translate"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "translate|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The browser is showing a “Translate this page?” prompt for a page in another language. Click the “Translate” button to translate the page into English. Click only that button. This is reversible — the browser offers “Show original” afterward."
        },
        makeTitle: { _ in "Translate the page" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 38. Allow-Notifications Dismiss (ACTION — AUTO, reversible)

    static let allowNotificationsDismiss = Playbook(
        id: "allow-notifications-dismiss",
        name: "Block Notification Prompt",
        icon: "bell.slash",
        summary: "When a website asks to send notifications, declines the request.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            let asksNotify = hay.contains("show notifications")
                || hay.contains("allow notifications")
                || hay.contains("wants to send you notifications")
                || (hay.contains("notifications") && (hay.contains("allow") || hay.contains("block")))
            guard asksNotify else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "notif-prompt|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A website is asking permission to send browser notifications (an “Allow / Block” prompt near the address bar). Decline it with the least-committal choice — click “Block”, “Don’t allow”, or the ✕. Click exactly one button and nothing else. This is reversible in the browser’s site settings."
        },
        makeTitle: { _ in "Block notifications" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 39. Close Newsletter Popup (ACTION — AUTO, reversible)

    static let closeNewsletterPopup = Playbook(
        id: "close-newsletter-popup",
        name: "Close Signup Popup",
        icon: "xmark.rectangle",
        summary: "When a newsletter / discount popup covers a page, closes it.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "subscribe to our newsletter", "sign up for our newsletter",
                "join our mailing list", "get 10% off", "10% off your first",
                "15% off your first", "sign up and save", "enter your email",
                "no thanks", "subscribe to get"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "signup-popup|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A newsletter-signup or discount popup/modal is covering this web page. Dismiss it without subscribing — click its close ✕, or a “No thanks” / “Maybe later” link. Click exactly one dismissal control; do NOT type an email address or click Subscribe. This is reversible."
        },
        makeTitle: { _ in "Close the popup" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 40. Software Update Later (ACTION — AUTO, defers only)

    static let softwareUpdateLater = Playbook(
        id: "software-update-later",
        name: "Defer Update Prompt",
        icon: "clock.arrow.circlepath",
        summary: "When an app nags to update now, defers it (Later / Not Now) — never installs.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText.lowercased()
            let isUpdatePrompt = hay.contains("update is available")
                || hay.contains("a new version")
                || hay.contains("update now")
                || hay.contains("software update is available")
                || hay.contains("would you like to update")
            // Must also offer a defer option, so this only ever clicks "Later".
            let hasDefer = hay.contains("later") || hay.contains("not now")
                || hay.contains("remind me") || hay.contains("skip this version")
            guard isUpdatePrompt, hasDefer else { return nil }
            return "update-later|" + ctx.appName
        },
        makeGoal: { _ in
            "An app is showing an “update available” dialog that interrupts the user. Defer it with the least-committal option — click “Later”, “Remind Me Later”, “Not Now”, or “Skip This Version”. NEVER click “Update Now”, “Install”, “Restart”, or “Download”; only dismiss the nag so the user can update on their own terms."
        },
        makeTitle: { _ in "Update later" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 41. Join Zoom Audio (ACTION — AUTO, reversible)

    static let joinZoomAudio = Playbook(
        id: "join-zoom-audio",
        name: "Join Meeting Audio",
        icon: "headphones",
        summary: "When a call shows the “Join with Computer Audio” prompt, joins the audio.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isCallApp = identity.contains("zoom") || identity.contains("meet")
                || identity.contains("teams") || identity.contains("webex")
            guard isCallApp else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "join with computer audio", "join audio", "join audio by computer",
                "connect audio", "use computer audio"
            ]) else { return nil }
            return "join-audio|" + ctx.appName
        },
        makeGoal: { _ in
            "A video-call app is showing a “Join with Computer Audio” (or “Join Audio” / “Use Computer Audio”) dialog before the user is fully in the call. Click that button once to connect the meeting audio. This is reversible — the user can mute or leave. Do not change any other call setting."
        },
        makeTitle: { _ in "Join meeting audio" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 42. Archive Receipt Email (ACTION — CONFIRM, reversible)

    static let archiveReceiptEmail = Playbook(
        id: "archive-receipt-email",
        name: "Archive Receipt",
        icon: "doc.badge.arrow.up",
        summary: "When you open an order receipt or confirmation email, archives it out of the inbox.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "order confirmation", "your receipt", "payment received",
                "thank you for your order", "your order has shipped", "order #",
                "order number", "invoice", "payment confirmation", "shipping confirmation"
            ]) else { return nil }
            // Don't grab a message that actually asks the user something.
            guard !ctx.screenText.contains("?") else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "archive-receipt|" + key
        },
        makeGoal: { _ in
            "The open email is a transactional receipt, order, or shipping confirmation — not a personal message that needs a reply. Archive it out of the inbox (click Archive, or press “e” in Gmail). Archiving is reversible: it stays in All Mail / Archive. Do NOT delete it and do NOT reply."
        },
        makeTitle: { _ in "Archive receipt" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - 43. CAPTCHA Help (TEACH)

    static let captchaHelp = Playbook(
        id: "captcha-help",
        name: "CAPTCHA Help",
        icon: "checkmark.shield",
        summary: "When a CAPTCHA appears, explains it and points at the checkbox (never solves it).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "i'm not a robot", "i am not a robot", "select all images",
                "verify you are human", "recaptcha", "hcaptcha", "press and hold",
                "confirm you are human", "security check"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "captcha|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A CAPTCHA / human-verification challenge is on screen. In one or two spoken sentences, tell the user it’s a check that they’re human and what to do (tick the checkbox, or select the matching images), then point an arrow at the checkbox or challenge. Do NOT solve it or click anything — the user must complete it themselves."
        },
        makeTitle: { _ in "It’s a CAPTCHA" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 44. Two-Factor Code Help (TEACH)

    static let twoFactorHelp = Playbook(
        id: "two-factor-help",
        name: "2FA Code Help",
        icon: "lock.rotation",
        summary: "When a site asks for a verification code, explains where to find it and points at the field.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "verification code", "two-factor", "2-step verification",
                "authentication code", "enter the code we sent", "one-time code",
                "6-digit code", "security code", "enter the 6-digit"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "2fa|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A two-factor / verification-code screen is asking for a code. In one or two spoken sentences, tell the user where to find it — their authenticator app, a text message, or an email — and point an arrow at the code input field. Do NOT type or guess a code; only guide them."
        },
        makeTitle: { _ in "Where’s the code" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 45. App Permission Prompt Help (TEACH)

    static let appPermissionPromptHelp = Playbook(
        id: "app-permission-prompt-help",
        name: "Permission Prompt Help",
        icon: "hand.raised",
        summary: "When an app asks for camera/mic/location access, explains the ask and points at the buttons.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "would like to access", "wants to use your", "would like to use your",
                "requesting access to", "wants to access your", "access your camera",
                "access your microphone", "access your location", "would like to access your"
            ]) else { return nil }
            return "perm-prompt|" + ctx.appName
        },
        makeGoal: { _ in
            "A privacy-permission prompt is asking to access something (camera, microphone, location, photos, or files). In one or two spoken sentences, explain plainly what is being requested and why an app might need it, then point at the “Allow” and “Don’t Allow” buttons. Do NOT click — granting access is the user’s decision."
        },
        makeTitle: { _ in "Permission request" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 46. Generic Error Dialog Help (TEACH)

    static let genericErrorDialogHelp = Playbook(
        id: "generic-error-dialog-help",
        name: "Error Dialog Help",
        icon: "exclamationmark.octagon",
        summary: "When a system error alert appears, explains what it likely means and points at the buttons.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "quit unexpectedly", "an error occurred", "could not be completed",
                "couldn’t be completed", "couldn't be completed", "something went wrong",
                "report to apple", "the application", "unexpected error", "operation failed"
            ]) else { return nil }
            // Needs an error tell, not just the word "application".
            let hay = ctx.screenText.lowercased()
            guard hay.contains("error") || hay.contains("quit") || hay.contains("failed")
                || hay.contains("went wrong") || hay.contains("could") else { return nil }
            return "error-dialog|" + ctx.appName
        },
        makeGoal: { _ in
            "A system error alert is on screen. In one or two spoken sentences, explain in plain language what it most likely means and whether it’s serious, then point at the dialog’s buttons (e.g. Reopen, OK, Report) so the user knows their options. Do NOT click anything for them."
        },
        makeTitle: { _ in "What this error means" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 47. Password Requirement Help (TEACH)

    static let passwordRequirementHelp = Playbook(
        id: "password-requirement-help",
        name: "Password Rules Help",
        icon: "key.horizontal",
        summary: "When a password field rejects a password, explains the requirement and points at the field.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText.lowercased()
            guard hay.contains("password") else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "password must", "must contain", "at least 8 characters",
                "at least one uppercase", "special character", "weak password",
                "strong password", "password is too", "must be at least",
                "one number", "one uppercase"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "pw-rules|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A password field is showing its strength rules (or rejecting a weak password). In one spoken sentence, summarize exactly what the password needs — length, an uppercase letter, a number, a symbol — then point an arrow at the password field. Do NOT type a password for the user."
        },
        makeTitle: { _ in "Password rules" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 48. Print Dialog Help (TEACH)

    static let printDialogHelp = Playbook(
        id: "print-dialog-help",
        name: "Print Dialog Help",
        icon: "printer",
        summary: "When the Print dialog is open, explains the key options and points at them.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText.lowercased()
            guard hay.contains("print") else { return nil }
            guard hay.contains("copies") && (hay.contains("pages") || hay.contains("printer")) else { return nil }
            return "print-dialog|" + ctx.appName
        },
        makeGoal: { _ in
            "The Print dialog is open. In one or two spoken sentences, walk the user through the important choices — which printer, number of copies, the page range, and double-sided if present — and point at those controls. Do NOT press Print; the user chooses when to print."
        },
        makeTitle: { _ in "Print options" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 49. Diff Review Help (TEACH)

    static let diffReviewHelp = Playbook(
        id: "diff-review-help",
        name: "Diff Review Help",
        icon: "plusminus",
        summary: "When a code diff is on screen, explains what changed and points at the added/removed lines.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let isCode = DefaultPlaybooks.isEditorOrIDE(ctx) || DefaultPlaybooks.isBrowser(ctx)
            guard isCode else { return nil }
            let text = ctx.screenText
            if text.contains("diff --git") || text.contains("@@ ") {
                return "diff|" + ctx.appName + "|" + ctx.windowTitle
            }
            // Otherwise require a genuine unified-diff feel: several added AND
            // several removed lines, so ordinary bullet lists don't qualify.
            var plus = 0, minus = 0
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("+") && !line.hasPrefix("++") { plus += 1 }
                else if line.hasPrefix("-") && !line.hasPrefix("--") { minus += 1 }
            }
            guard plus >= 3, minus >= 3 else { return nil }
            return "diff|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "A code diff is on my screen (added and removed lines). In two or three spoken sentences, summarize what this change does and anything worth double-checking, then draw around the most important added or removed region. Keep it brief and spoken; don’t edit anything."
        },
        makeTitle: { _ in "What changed" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 50. Wi-Fi Troubleshoot Help (TEACH)

    static let wifiTroubleshootHelp = Playbook(
        id: "wifi-troubleshoot-help",
        name: "Wi-Fi Troubleshoot",
        icon: "wifi.exclamationmark",
        summary: "When the Mac shows no connection, explains what to try and points at the Wi-Fi menu.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "no internet connection", "not connected to the internet",
                "you are not connected", "connect to a network", "no networks found",
                "wi-fi: not connected", "airplane mode", "you are offline",
                "no internet", "check your connection"
            ]) else { return nil }
            return "wifi|" + ctx.appName
        },
        makeGoal: { _ in
            "The screen shows a network / internet connection problem. In one or two spoken sentences, suggest the quick fixes — toggle Wi-Fi off and on, pick the right network, check the router — and point an arrow at the Wi-Fi icon in the menu bar (upper-right). Don’t change any settings yourself."
        },
        makeTitle: { _ in "Fix the connection" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 51. Video Call Controls Help (TEACH)

    static let videoCallControlsHelp = Playbook(
        id: "video-call-controls-help",
        name: "Call Controls Help",
        icon: "video.circle",
        summary: "During a video call, points out the mute, camera, and leave controls.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isCallApp = identity.contains("zoom") || identity.contains("meet")
                || identity.contains("teams") || identity.contains("webex")
            guard isCallApp else { return nil }
            // In-call controls, NOT the pre-join screen (that's join-zoom-audio).
            let hay = ctx.screenText.lowercased()
            let inCall = (hay.contains("mute") || hay.contains("unmute"))
                && (hay.contains("leave") || hay.contains("participants")
                    || hay.contains("stop video") || hay.contains("start video"))
            guard inCall else { return nil }
            return "call-controls|" + ctx.appName
        },
        makeGoal: { _ in
            "The user is in a video call. In one or two spoken sentences, orient them to the main controls, then point at the mute/unmute button, the camera (start/stop video) button, and the leave/end-call button. Keep it brief and spoken; do NOT click any of them."
        },
        makeTitle: { _ in "Call controls" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 52. Spreadsheet Formula Error (TEACH)

    static let spreadsheetFormulaError = Playbook(
        id: "spreadsheet-formula-error",
        name: "Formula Error Help",
        icon: "function",
        summary: "When a spreadsheet cell shows a formula error, explains the cause and circles the cell.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isSpreadsheet(ctx) else { return nil }
            let hay = ctx.screenText.uppercased()
            guard hay.contains("#REF!") || hay.contains("#DIV/0!") || hay.contains("#VALUE!")
                || hay.contains("#NAME?") || hay.contains("#N/A") || hay.contains("#NULL!")
                || hay.contains("#NUM!") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "formula-error|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A spreadsheet cell is showing a formula error (like #REF!, #DIV/0!, #VALUE!, or #NAME?). In one or two spoken sentences, explain what that specific error means and its likely cause, then circle the cell showing it. Keep it short and spoken; don’t edit the sheet."
        },
        makeTitle: { _ in "Formula error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 53. Timezone Convert Help (TEACH)

    static let timezoneConvertHelp = Playbook(
        id: "timezone-convert-help",
        name: "Timezone Helper",
        icon: "clock.badge.questionmark",
        summary: "When a time in another timezone is on screen, speaks it in your local time and circles it.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText.lowercased()
            let tzTokens = [" pst", " pdt", " est", " edt", " cst", " cdt",
                            " mst", " mdt", " utc", " gmt", " cet", " cest",
                            " ist", " jst", " bst"]
            guard tzTokens.contains(where: { hay.contains($0) }) else { return nil }
            // A real clock time (digit ":" digit) must be present too.
            let chars = Array(ctx.screenText)
            var hasClock = false
            if chars.count >= 3 {
                for i in 1..<(chars.count - 1) where chars[i] == ":" {
                    if chars[i - 1].isNumber && chars[i + 1].isNumber { hasClock = true; break }
                }
            }
            guard hasClock else { return nil }
            return "tz-convert|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There’s a time on screen given in another timezone (its abbreviation like PST, EST, UTC, or GMT is visible next to it). In one spoken sentence, convert that time into the user’s current local timezone and say it plainly, then circle the original time on screen. Don’t change anything."
        },
        makeTitle: { _ in "In your time" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 54. Paywall Help (TEACH)

    static let paywallHelp = Playbook(
        id: "paywall-help",
        name: "Paywall Help",
        icon: "newspaper",
        summary: "When an article hits a paywall, explains the options and points at reader/subscribe.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "subscribe to continue", "subscribers only", "to continue reading",
                "this article is for subscribers", "create a free account to read",
                "you've reached your", "you have reached your", "become a member to read",
                "subscribe now to keep reading"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "paywall|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This article has hit a subscription paywall. In one or two spoken sentences, explain the honest options — try the browser’s Reader view, subscribe if they value the source, or find the story elsewhere — and point at the Reader-view or Subscribe control. Do NOT attempt to bypass or defeat the paywall."
        },
        makeTitle: { _ in "Behind a paywall" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - 55. DMG Install Drag Help (TEACH)

    static let dmgInstallDragHelp = Playbook(
        id: "dmg-install-drag-help",
        name: "App Install Help",
        icon: "arrow.down.app",
        summary: "When a .dmg installer window is open, shows how to drag the app into Applications.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isInstallerWindow = ctx.appName.lowercased().contains("finder")
                || identity.contains(".dmg") || identity.contains("installer")
            guard isInstallerWindow else { return nil }
            let hay = ctx.screenText.lowercased()
            guard hay.contains("applications")
                && (hay.contains("drag") || hay.contains("to install")
                    || hay.contains("drop here")) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "dmg-install|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A disk-image (.dmg) installer window is open, showing an app icon and an Applications-folder shortcut. In one spoken sentence, tell the user to drag the app icon onto the Applications folder to install it, then draw an arrow from the app icon to the Applications folder. Do NOT drag it for them."
        },
        makeTitle: { _ in "Drag to install" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // ═══════════════════════════════════════════════════════════════════════
    // FILES · FINDER · SYSTEM — autonomous task library (ACTION + TEACH)
    // All kind:.aiAnswer, all autoTriggers:true. Matchers are self-contained and
    // reuse the existing private DefaultPlaybooks helpers (same enum scope).
    // ═══════════════════════════════════════════════════════════════════════

    // MARK: - Unzip Downloaded Archives (ACTION — AUTO, reversible)

    static let unzipArchives = Playbook(
        id: "unzip-archives",
        name: "Unzip Archives",
        icon: "archivebox",
        summary: "When downloaded archives are sitting in Finder, extracts each into its own folder.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let exts: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "tbz", "bz2"]
            let count = ctx.screenText
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .filter { tok in
                    guard let dot = tok.lastIndex(of: "."), dot != tok.startIndex else { return false }
                    let ext = String(tok[tok.index(after: dot)...]).lowercased()
                    return exts.contains(ext)
                }.count
            guard count >= 2 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "unzip|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "Several downloaded archives (zip, tar, rar, and similar) are sitting in the frontmost Finder window. Extract each archive into its own subfolder next to it, using the file system so each extraction can be undone. Leave the original archive files in place; do not delete anything and do not open the extracted contents."
        },
        makeTitle: { _ in "Unzip archives" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Eject Mounted DMG (ACTION — AUTO, reversible)

    static let ejectDMG = Playbook(
        id: "eject-dmg",
        name: "Eject Disk Image",
        icon: "eject",
        summary: "After an app is installed from a DMG, ejects the mounted disk image.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let low = ctx.screenText.lowercased()
            let looksLikeInstaller = low.contains("drag") && low.contains("applications")
            let mentionsDMG = low.contains(".dmg")
            guard looksLikeInstaller || mentionsDMG else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "dmg|" + (title.isEmpty ? "volume" : title)
        },
        makeGoal: { _ in
            "A mounted disk image (a DMG installer volume) is open in Finder — the drag-to-Applications window is showing. Eject the mounted disk image: select the volume in the Finder sidebar and click its eject button (or use File then Eject). This is fully reversible — double-clicking the .dmg remounts it. Do not delete the .dmg file itself."
        },
        makeTitle: { _ in "Eject the disk image" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Move Installers to Trash After Install (ACTION — CONFIRM, sensitive)

    static let installerCleanup = Playbook(
        id: "installer-cleanup",
        name: "Installer Cleanup",
        icon: "shippingbox",
        summary: "When leftover .dmg/.pkg installers pile up in Downloads, moves them to Trash.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            let exts: Set<String> = ["dmg", "pkg"]
            let count = ctx.screenText
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .filter { tok in
                    guard let dot = tok.lastIndex(of: "."), dot != tok.startIndex else { return false }
                    let ext = String(tok[tok.index(after: dot)...]).lowercased()
                    return exts.contains(ext)
                }.count
            guard count >= 2 else { return nil }
            return "installers"
        },
        makeGoal: { _ in
            "The Downloads folder has leftover installer files (.dmg and .pkg) that have already served their purpose. Move those installer files to the Trash so they stop cluttering Downloads. Move ONLY .dmg and .pkg installers — never documents, images, or archives. This is sensitive because it removes files; the runner keeps a real undo."
        },
        makeTitle: { _ in "Clear leftover installers" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Dedupe Files (ACTION — CONFIRM, sensitive)

    static let dedupeFiles = Playbook(
        id: "dedupe-files",
        name: "Dedupe Files",
        icon: "doc.on.doc",
        summary: "When a folder has obvious duplicate files, gathers the redundant copies for review.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let low = ctx.screenText.lowercased()
            let markers = [" copy", "copy.", "copy 2", "(1)", "(2)", "(3)"]
            let hits = markers.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard hits >= 3 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "dedupe|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder contains obvious duplicate files — the same base name repeated with 'copy' or numbered '(1)', '(2)' suffixes. Identify the redundant copies (keep the original of each set) and move the redundant duplicates into a new subfolder named '_Duplicates' with the file system, so nothing is deleted and every move can be undone. Do not permanently delete anything — the user reviews the _Duplicates folder afterward."
        },
        makeTitle: { _ in "Gather duplicate files" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Archive Old Files (ACTION — CONFIRM, sensitive)

    static let archiveOldFiles = Playbook(
        id: "archive-old-files",
        name: "Archive Old Files",
        icon: "archivebox.fill",
        summary: "When a folder is full of files from past years, files them into a dated Archive subfolder.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard !DefaultPlaybooks.isSpecialFinderFolder(ctx) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            let low = ctx.screenText.lowercased()
            let oldYears = ["2017", "2018", "2019", "2020", "2021", "2022"]
            guard oldYears.contains(where: { low.contains($0) }) else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "archive-old|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder holds a mix of files, several of them from past years (visible date-stamped names or years in the listing). Create an 'Archive' subfolder here, then inside it a folder per year, and move the clearly old files into their matching year folder using the file system so every move can be undone. Leave this year's files where they are. Do not delete anything."
        },
        makeTitle: { ctx in
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "Archive old files" : "Archive old files in \(folder)"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Batch Rename by Pattern (ACTION — CONFIRM, sensitive)

    static let batchRenamePattern = Playbook(
        id: "batch-rename-pattern",
        name: "Batch Rename",
        icon: "textformat.abc",
        summary: "When a folder is full of cryptic camera/auto-generated names, renames them to a clean pattern.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let low = ctx.screenText.lowercased()
            let prefixes = ["img_", "dsc_", "dscf", "dcim", "pxl_", "vid_", "mov_", "photo_", "image_", "untitled"]
            let hits = prefixes.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard hits >= 4 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "rename|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder is full of cryptically named files (camera dumps like IMG_XXXX, DSC_XXXX, or 'untitled' files). Rename them in place to a single clean, human-readable pattern with zero-padded sequence numbers — for example 'FolderName-001', 'FolderName-002' — preserving each file's extension and its listing order. Rename via the file system so the operation can be undone. Do not move or delete any file."
        },
        makeTitle: { _ in "Batch-rename these files" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Sort a Folder by Kind (ACTION — CONFIRM, sensitive)

    static let sortFolderByKind = Playbook(
        id: "sort-folder-by-kind",
        name: "Sort by Kind",
        icon: "square.grid.3x3",
        summary: "When a folder mixes many file types, sorts them into subfolders by kind.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard !DefaultPlaybooks.isSpecialFinderFolder(ctx) else { return nil }
            var exts = Set<String>()
            var files = 0
            for tok in ctx.screenText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                guard let dot = tok.lastIndex(of: "."), dot != tok.startIndex else { continue }
                let ext = String(tok[tok.index(after: dot)...]).lowercased()
                guard (1...5).contains(ext.count),
                      ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                      ext.contains(where: { $0.isLetter }) else { continue }
                files += 1
                exts.insert(ext)
            }
            guard files >= 8, exts.count >= 3 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "sortkind|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder mixes many different file kinds. Sort the loose files into subfolders by kind — for example Images, Documents, PDFs, Spreadsheets, Archives, Media, Code — creating each subfolder as needed and moving every loose file into its matching one with the file system so each move can be undone. Do not touch existing subfolders and do not delete anything."
        },
        makeTitle: { ctx in
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "Sort this folder by kind" : "Sort \(folder) by kind"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Consolidate Duplicate Folders (ACTION — CONFIRM, sensitive)

    static let consolidateDuplicateFolders = Playbook(
        id: "consolidate-duplicate-folders",
        name: "Merge Stray Folders",
        icon: "folder.badge.plus",
        summary: "When 'New Folder', 'untitled folder' clones pile up, merges them into one.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let low = ctx.screenText.lowercased()
            let markers = ["new folder", "untitled folder", "folder 2", "folder 3", "copy of"]
            let hits = markers.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard hits >= 2 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "mergefolders|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder window shows several stray or duplicated folders (names like 'New Folder', 'New Folder 2', 'untitled folder', 'Copy of …'). Merge their contents into a single well-named folder: move the files out of the redundant clones into one keeper folder with the file system, then remove the folders that are left empty. Do this move-by-move so it can be undone, and never overwrite a file that already exists at the destination — keep both."
        },
        makeTitle: { _ in "Merge stray folders" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Project Folder from Loose Related Files (ACTION — CONFIRM, sensitive)

    static let projectFolderFromFiles = Playbook(
        id: "project-folder-from-files",
        name: "Make Project Folder",
        icon: "folder.fill.badge.plus",
        summary: "When loose files clearly belong to one project, gathers them into a named folder.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads", "desktop"]) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 4 else { return nil }
            var freq: [String: Int] = [:]
            for raw in ctx.screenText.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                let w = raw.lowercased()
                guard w.count >= 4, w.contains(where: { $0.isLetter }) else { continue }
                freq[w, default: 0] += 1
            }
            let stop: Set<String> = ["screenshot", "screen", "final", "copy", "draft", "untitled",
                                     "image", "photo", "download", "downloads", "document", "version"]
            let top = freq.filter { !stop.contains($0.key) }.values.max() ?? 0
            guard top >= 3 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "project|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "Several loose files here share a common word in their names — they clearly belong to one project or topic. Create a new folder named after that shared topic and move the related files into it with the file system so each move can be undone. Only gather files whose names genuinely share the topic; leave unrelated files where they are and delete nothing."
        },
        makeTitle: { _ in "Gather into a project folder" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Group Photos by Date (ACTION — CONFIRM, sensitive)

    static let groupPhotosByDate = Playbook(
        id: "group-photos-by-date",
        name: "Group Photos by Date",
        icon: "photo.on.rectangle",
        summary: "When a folder is full of loose photos, files them into subfolders by capture date.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard !DefaultPlaybooks.finderWindowIs(ctx, ["trash", "bin"]) else { return nil }
            let imgExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "raw", "dng",
                                        "tiff", "tif", "gif", "webp", "cr2", "nef"]
            let count = ctx.screenText
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .filter { tok in
                    guard let dot = tok.lastIndex(of: "."), dot != tok.startIndex else { return false }
                    let ext = String(tok[tok.index(after: dot)...]).lowercased()
                    return imgExts.contains(ext)
                }.count
            guard count >= 8 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "photos-by-date|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder is full of loose photos. Group them into subfolders by capture date, one folder per month named 'YYYY-MM' (read each photo's date from its filename or file metadata), and move every image into its matching month folder with the file system so each move can be undone. Move only image files; leave anything non-photo in place and delete nothing."
        },
        makeTitle: { _ in "Group photos by date" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Screenshots Pileup (ACTION — CONFIRM, sensitive)

    static let screenshotsPileup = Playbook(
        id: "screenshots-pileup",
        name: "Screenshot Pileup",
        icon: "camera.viewfinder",
        summary: "When date-stamped screenshots pile up in a folder, files them into dated subfolders.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.hasDefaultScreenshotName(ctx.screenText) else { return nil }
            let low = ctx.screenText.lowercased()
            let markers = ["screenshot 20", "screen shot 20", "cleanshot"]
            let n = markers.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard n >= 4 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "shots-pileup|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder has piled up with default date-stamped screenshots. Create a 'Screenshots' subfolder here and, inside it, one folder per month named 'YYYY-MM' (read the date from each screenshot's filename), then move every screenshot into its matching month folder with the file system so each move can be undone. Move only screenshot images; leave other files in place and delete nothing."
        },
        makeTitle: { _ in "Tidy the screenshot pileup" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Move Finished Downloads Out (ACTION — CONFIRM, sensitive)

    static let downloadsMoveFinished = Playbook(
        id: "downloads-move-finished",
        name: "Clear Finished Downloads",
        icon: "arrow.up.forward.square",
        summary: "When Downloads is full of completed files, moves them to their proper home folders.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            // Only when nothing is still downloading — partial markers mean "wait".
            let low = ctx.screenText.lowercased()
            guard !low.contains(".crdownload"), !low.contains(".part") else { return nil }
            return "move-out"
        },
        makeGoal: { _ in
            "The Downloads folder is full of completed files and nothing is still downloading. Move each finished file OUT of Downloads to its natural home in the user's account — images to ~/Pictures, PDFs and documents to ~/Documents, videos/audio to ~/Movies or ~/Music — using the file system so each move can be undone. Skip any file that looks half-downloaded, and never overwrite an existing file at the destination (keep both). Delete nothing."
        },
        makeTitle: { _ in "Clear out finished downloads" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Flag a Huge File for Cleanup (TEACH — AUTO)

    static let flagLargeFile = Playbook(
        id: "flag-large-file",
        name: "Flag Large File",
        icon: "flag",
        summary: "When a very large file is visible in Finder, points it out as a cleanup candidate.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            let low = ctx.screenText.lowercased()
            // A size shown in gigabytes ("1.2 GB", "14 GB") — a genuine cleanup target.
            guard low.contains(" gb") else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "large-file|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "One or more files in this Finder window are gigabytes in size. Point at the largest file(s) on screen and briefly explain, out loud, that they are the top cleanup candidates and roughly how much space they take. Do NOT move, rename, or delete anything — only highlight and explain, so the user can decide."
        },
        makeTitle: { _ in "Large file spotted" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Surface Low-Disk Cleanup (TEACH — AUTO)

    static let lowDiskCleanup = Playbook(
        id: "low-disk-cleanup",
        name: "Low Disk Helper",
        icon: "internaldrive",
        summary: "When macOS warns the disk is almost full, explains where to free up space.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "disk is almost full", "startup disk is almost full", "your disk is full",
                "storage is full", "not enough disk space", "not enough space",
                "free up space", "manage storage", "optimize storage"
            ]) else { return nil }
            return "low-disk"
        },
        makeGoal: { _ in
            "A low-disk-space warning is on screen. Explain out loud what typically eats the most space (large downloads, old installers, caches, big media, full Trash) and point at where to act — the Storage section in System Settings and the Manage/Optimize options. Do NOT delete, move, or change anything yourself; this is guidance only, so the user stays in control of what gets removed."
        },
        makeTitle: { _ in "Free up disk space" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Safe-Eject Reminder (TEACH — AUTO)

    static let safeEjectReminder = Playbook(
        id: "safe-eject-reminder",
        name: "Safe Eject Reminder",
        icon: "eject.circle",
        summary: "After a 'Disk Not Ejected Properly' warning, shows how to eject drives safely.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let low = ctx.screenText.lowercased()
            guard low.contains("disk not ejected properly")
                || low.contains("was not ejected")
                || low.contains("not ejected before") else { return nil }
            return "safe-eject"
        },
        makeGoal: { _ in
            "A 'Disk Not Ejected Properly' warning just appeared — a drive was unplugged before macOS finished with it. Explain out loud why that risks data loss and point at how to eject safely next time: the eject button next to the drive in the Finder sidebar, or dragging the drive to the Trash/Eject. Do not change anything on screen — this is a short teaching moment only."
        },
        makeTitle: { _ in "Eject drives safely" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Trash Old Downloads (ACTION — CONFIRM, sensitive)

    static let trashOldDownloads = Playbook(
        id: "trash-old-downloads",
        name: "Trash Old Downloads",
        icon: "trash.slash",
        summary: "When Downloads holds files from past years, moves those stale ones to Trash.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            let low = ctx.screenText.lowercased()
            let oldYears = ["2017", "2018", "2019", "2020", "2021", "2022"]
            guard oldYears.contains(where: { low.contains($0) }) else { return nil }
            return "trash-old-dl"
        },
        makeGoal: { _ in
            "The Downloads folder holds stale files from past years that were never cleaned up. Move the clearly old files (date-stamped names or years in the listing) to the Trash so Downloads only holds recent items. Move only files that look genuinely old; leave this year's files alone. This goes to the Trash, not permanent deletion, and the runner keeps an undo."
        },
        makeTitle: { _ in "Trash stale downloads" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Archive Old Screenshots (ACTION — CONFIRM, sensitive)

    static let archiveOldScreenshots = Playbook(
        id: "archive-old-screenshots",
        name: "Archive Old Screenshots",
        icon: "photo.stack",
        summary: "In the Screenshots folder, files older screenshots into a yearly archive.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["screenshots"]) else { return nil }
            guard DefaultPlaybooks.hasDefaultScreenshotName(ctx.screenText) else { return nil }
            let low = ctx.screenText.lowercased()
            let oldYears = ["2017", "2018", "2019", "2020", "2021", "2022", "2023", "2024"]
            guard oldYears.contains(where: { low.contains($0) }) else { return nil }
            return "arch-old-shots"
        },
        makeGoal: { _ in
            "This is the Screenshots folder, and it holds screenshots from older years mixed with recent ones. Create an 'Archive' subfolder with a folder per past year inside it, then move the older screenshots into their matching year folder with the file system so each move can be undone. Leave the current year's screenshots in place and delete nothing."
        },
        makeTitle: { _ in "Archive old screenshots" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Clean Partial Downloads (ACTION — CONFIRM, sensitive)

    static let cleanPartialDownloads = Playbook(
        id: "clean-partial-downloads",
        name: "Clean Partial Downloads",
        icon: "xmark.bin",
        summary: "When failed/partial download files linger in Downloads, moves them to Trash.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            let low = ctx.screenText.lowercased()
            let markers = [".crdownload", ".download", ".part", ".partial"]
            let hits = markers.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard hits >= 1 else { return nil }
            return "partials"
        },
        makeGoal: { _ in
            "The Downloads folder contains failed or half-finished download files (extensions like .crdownload, .download, .part). These are dead partial transfers with no use. Move ONLY those partial-download files to the Trash — never a complete file — using the file system. This goes to the Trash, not permanent deletion, and the runner keeps an undo."
        },
        makeTitle: { _ in "Remove partial downloads" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Clean Duplicate Downloads (ACTION — CONFIRM, sensitive)

    static let cleanDuplicateDownloads = Playbook(
        id: "clean-duplicate-downloads",
        name: "Clean Duplicate Downloads",
        icon: "doc.on.doc.fill",
        summary: "When Downloads has numbered re-download copies, gathers the extras for review.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard DefaultPlaybooks.finderWindowIs(ctx, ["downloads"]) else { return nil }
            let low = ctx.screenText.lowercased()
            let markers = ["(1).", "(2).", "(3).", "(4).", " copy"]
            let hits = markers.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard hits >= 2 else { return nil }
            return "dupe-dl"
        },
        makeGoal: { _ in
            "The Downloads folder has the same file downloaded several times — copies suffixed '(1)', '(2)', or 'copy'. For each set, keep one copy and move the redundant numbered duplicates into a new '_Duplicates' subfolder with the file system so nothing is deleted and every move can be undone. The user reviews the _Duplicates folder before anything is removed for good."
        },
        makeTitle: { _ in "Clean duplicate downloads" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Sort a Folder by Date (ACTION — CONFIRM, sensitive)

    static let sortFolderByDate = Playbook(
        id: "sort-folder-by-date",
        name: "Sort by Date",
        icon: "calendar",
        summary: "When a folder is full of date-stamped files, files them into subfolders by date.",
        autoTriggers: true,
        cooldownSeconds: 2400,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard ctx.appName.lowercased().contains("finder") else { return nil }
            guard !DefaultPlaybooks.isSpecialFinderFolder(ctx) else { return nil }
            guard DefaultPlaybooks.countFileLikeTokens(in: ctx.screenText) >= 6 else { return nil }
            let low = ctx.screenText.lowercased()
            let years = ["2022-", "2023-", "2024-", "2025-", "2026-"]
            let dateHits = years.reduce(0) { $0 + max(0, low.components(separatedBy: $1).count - 1) }
            guard dateHits >= 4 else { return nil }
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "sortdate|" + (folder.isEmpty ? "finder" : folder)
        },
        makeGoal: { _ in
            "This Finder folder is full of date-stamped files (names carrying YYYY-MM-DD). Sort them into subfolders by date, one folder per month named 'YYYY-MM', creating each as needed and moving every date-stamped file into its matching month folder with the file system so each move can be undone. Leave files without a clear date in place and delete nothing."
        },
        makeTitle: { ctx in
            let folder = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return folder.isEmpty ? "Sort this folder by date" : "Sort \(folder) by date"
        },
        makeTarget: { _ in .clipboard }
    )

    // ═══════════════════════════════════════════════════════════════════════
    // EMAIL · CALENDAR — autonomous task library (ACTION + TEACH)
    // ═══════════════════════════════════════════════════════════════════════

    // MARK: - Email/Calendar autonomy — unsubscribe (ACTION — CONFIRM, sensitive)

    static let unsubscribeBulkMail = Playbook(
        id: "unsubscribe-bulk-mail",
        name: "Unsubscribe",
        icon: "envelope.badge.slash",
        summary: "When a bulk/marketing email is open, unsubscribes you from the list.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "unsubscribe", "manage preferences", "update your preferences",
                "no longer wish to receive", "opt out", "you are receiving this",
                "you're receiving this"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "unsubscribe|" + key
        },
        makeGoal: { _ in
            "The open email is bulk/marketing mail with an Unsubscribe affordance. Unsubscribe the user from this mailing list: click the visible \"Unsubscribe\" link (or the mail client's built-in Unsubscribe control) and complete the one-click confirmation if the list asks for it. Unsubscribing tells the sender to stop mailing this address, so do only this — do not delete other mail, and do not enter the user's credentials on any page."
        },
        makeTitle: { _ in "Unsubscribe" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Email triage sweep (READ-ONLY draft — AUTO)

    static let inboxTriageSweep = Playbook(
        id: "inbox-triage-sweep",
        name: "Inbox Triage",
        icon: "tray.full",
        summary: "A crowded inbox → a ranked triage of what needs action, replies, and noise.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            // An inbox LIST view, not a single open message: many sender/subject
            // rows plus an unread pileup signal.
            let hay = ctx.screenText.lowercased()
            guard hay.contains("inbox") else { return nil }
            let unreadTells = ["unread", "primary", "updates", "1 hour ago", "yesterday"]
            guard DefaultPlaybooks.screenTextContainsAny(ctx, unreadTells) else { return nil }
            let rowCount = ctx.screenText.split(separator: "\n").filter { $0.contains("@") || $0.contains("AM") || $0.contains("PM") }.count
            guard rowCount >= 8 else { return nil }
            return "triage|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "The inbox list is crowded. Read the visible messages and produce a short triage: group them into \"Needs a reply\", \"Needs an action / has a deadline\", \"Can wait\", and \"Noise (newsletters/promos)\", listing sender and subject under each. For anything time-sensitive, note the deadline. This is a read-only summary — do not open, archive, delete, label, or reply to anything; just report the triage."
        },
        makeTitle: { _ in "Triage my inbox" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Follow-up chase (ACTION — CONFIRM, drafts into compose)

    static let followUpChaseStage = Playbook(
        id: "follow-up-chase-stage",
        name: "Chase Follow-up",
        icon: "arrow.uturn.up.circle",
        summary: "A sent thread gone quiet for days → drafts a gentle nudge into the compose box.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            // Your own sent message with no reply since — a stale outgoing thread.
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "you sent", "3 days ago", "4 days ago", "5 days ago", "last week",
                "no reply", "sent \u{00b7}", "awaiting"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "chase|" + key
        },
        makeGoal: { _ in
            "This is a thread the user sent that has gone quiet for several days with no reply. Draft a brief, friendly follow-up that references the original ask and gently nudges for a response, in the user's voice. Click Reply and type the follow-up into the compose box, but do NOT press Send — leave it staged for the user to review and send. Keep the recipients exactly as on the existing thread; never add anyone new."
        },
        makeTitle: { _ in "Draft a follow-up" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Star important email (ACTION — AUTO, reversible)

    static let starImportantEmail = Playbook(
        id: "star-important-email",
        name: "Star Important",
        icon: "star",
        summary: "When an open email looks important/urgent, stars it so it's easy to find.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "urgent", "important", "action required", "please respond", "asap",
                "deadline", "due by", "time-sensitive", "high priority"
            ]) else { return nil }
            guard !DefaultPlaybooks.screenTextContainsAny(ctx, ["unsubscribe", "view in browser"]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "star|" + key
        },
        makeGoal: { _ in
            "The open email reads as important or time-sensitive. Star it (click the star, or press \"s\" in Gmail) so the user can find it quickly later. Starring is reversible and changes nothing about the message — do only this, do not reply, archive, or delete."
        },
        makeTitle: { _ in "Star this email" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Label email (ACTION — AUTO, reversible)

    static let labelEmail = Playbook(
        id: "label-email",
        name: "Label Email",
        icon: "tag",
        summary: "When an open email clearly belongs to a project/topic, applies a fitting label.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "invoice", "receipt", "order", "contract", "project", "proposal",
                "onboarding", "interview", "offer letter", "statement", "booking"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "label|" + key
        },
        makeGoal: { _ in
            "The open email clearly belongs to a recognizable topic (an invoice, an order/receipt, a specific project, an interview, etc.). Apply the matching existing label/folder to it — use the mail client's Label/Move-to control and pick the closest existing label; only create a new one if there is an obvious clean name and no existing match. Labeling is reversible and leaves the message in the inbox. Do not archive, delete, or reply."
        },
        makeTitle: { _ in "Label this email" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Snooze email (ACTION — AUTO, reversible)

    static let snoozeEmail = Playbook(
        id: "snooze-email",
        name: "Snooze Email",
        icon: "clock.arrow.circlepath",
        summary: "A not-now email that references a future date → snoozes it until then.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "next week", "tomorrow", "on monday", "on tuesday", "on wednesday",
                "on thursday", "on friday", "later this week", "follow up on", "circle back"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "snooze|" + key
        },
        makeGoal: { _ in
            "This email is not actionable right now but references a future time when it will be. Snooze it out of the inbox until that time using the mail client's Snooze control, picking the date/time the message implies (e.g. tomorrow morning, or the named weekday). Snoozing is reversible — it returns to the inbox at the chosen time. Do not delete, archive permanently, or reply."
        },
        makeTitle: { _ in "Snooze this email" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Decline overlapping invite (ACTION — CONFIRM, notifies organizer)

    static let declineOverlappingInvite = Playbook(
        id: "decline-overlapping-invite",
        name: "Decline Overlap",
        icon: "calendar.badge.minus",
        summary: "An invite that overlaps an existing event → declines it (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let onCalendar = identity.contains("calendar") || identity.contains("fantastical")
                || ctx.contextType.lowercased().contains("calendar")
                || DefaultPlaybooks.isEmailSurface(ctx)
            guard onCalendar else { return nil }
            let hasInvite = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "has invited you", "invitation", "rsvp", "accept", "decline", "maybe"
            ])
            let hasConflict = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "conflict", "overlaps", "double booked", "double-booked", "busy",
                "already have", "you have another event"
            ])
            guard hasInvite && hasConflict else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "decline-overlap|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A calendar invitation on screen overlaps an event the user already has (a conflict/double-book is indicated). Decline this invitation — click \"Decline\" (or \"No\") on the pending invite. Declining notifies the organizer and removes the tentative hold, so do only this one action and, if the client offers a note field, keep any note brief and polite."
        },
        makeTitle: { _ in "Decline the overlap" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Meeting one-pager (READ-ONLY draft — AUTO)

    static let meetingOnePager = Playbook(
        id: "meeting-one-pager",
        name: "Meeting One-Pager",
        icon: "doc.text.magnifyingglass",
        summary: "Just before a meeting → a one-page prep: attendees, agenda, context, questions.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let onCalendar = identity.contains("calendar") || identity.contains("fantastical")
                || ctx.contextType.lowercased().contains("calendar")
            guard onCalendar else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "in 10 minutes", "in 15 minutes", "in 5 minutes", "starting soon",
                "starts at", "agenda", "attendees", "guests", "organizer"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "one-pager|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "An upcoming meeting is open in the calendar. Produce a one-page prep brief from the event details and any context you can read: the meeting purpose, the attendee list (with who each person is if inferable), a proposed agenda or the stated one, the key background/decisions at stake, and 3-4 sharp questions the user could ask. This is read-only preparation — do not modify the event, reply to anyone, or send anything."
        },
        makeTitle: { _ in "Prep this meeting" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Double-booking flag (TEACH — AUTO, points at the clash)

    static let doubleBookingFlag = Playbook(
        id: "double-booking-flag",
        name: "Double-Booking Flag",
        icon: "exclamationmark.triangle",
        summary: "When two events overlap on the calendar, points out the clash and suggests a fix.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let onCalendar = identity.contains("calendar") || identity.contains("fantastical")
                || ctx.contextType.lowercased().contains("calendar")
            guard onCalendar else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "conflict", "overlaps", "double booked", "double-booked",
                "two events", "at the same time", "overlapping"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "double-book|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "Two events on the calendar overlap. Point at the clashing blocks on screen and explain the conflict: which two events, what times they collide, and which looks more important. Suggest a concrete fix (decline one, ask to move it, or shorten a block) but let the user decide. Do NOT change the calendar, decline, or message anyone — only explain and point."
        },
        makeTitle: { _ in "You're double-booked" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Add calendar event from email (ACTION — AUTO, personal event, reversible)

    static let addCalendarEventFromEmail = Playbook(
        id: "add-calendar-event-from-email",
        name: "Add to Calendar",
        icon: "calendar.badge.clock",
        summary: "An email that names a date/time → adds it as a personal event on your calendar.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            let hasDate = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "am on", "pm on", "at 9", "at 10", "at 11", "at 12", "at 1pm", "at 2pm",
                "on monday", "on tuesday", "on wednesday", "on thursday", "on friday",
                "january", "february", "march", "april", "june", "july", "august",
                "september", "october", "november", "december"
            ])
            let hasEventNoun = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "meeting", "call", "appointment", "reservation", "flight", "deadline",
                "webinar", "dinner", "interview", "demo", "sync"
            ])
            guard hasDate && hasEventNoun else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "add-event|" + key
        },
        makeGoal: { _ in
            "The open email describes a dated event (a meeting, appointment, reservation, flight, or deadline with a specific date/time). Add it to the user's calendar as a personal event: create a new event titled after the subject, with the date, time, and location exactly as stated, and paste a short note linking back to the email. Do NOT invite any guests to the event (keep it a private personal hold, which is reversible) and do not reply to the email."
        },
        makeTitle: { _ in "Add to calendar" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Remind before a call (READ-ONLY nudge — AUTO)

    static let remindBeforeCall = Playbook(
        id: "remind-before-call",
        name: "Call Reminder",
        icon: "bell.badge",
        summary: "A call starting soon → a heads-up with who, when, and what it's about.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: true,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let onCalendar = identity.contains("calendar") || identity.contains("fantastical")
                || ctx.contextType.lowercased().contains("calendar")
                || DefaultPlaybooks.isEmailSurface(ctx)
            guard onCalendar else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "call", "phone call", "1:1", "one-on-one", "catch up", "sync"
            ]) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "in 5 minutes", "in 10 minutes", "in 15 minutes", "starting soon",
                "starts at", "coming up"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "call-reminder|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A call is starting shortly. Give the user a concise heads-up: who the call is with, exactly when it starts and how long, the topic, and one line of context or the last thing that happened with this person if you can read it. This is a read-only reminder — do not join the call, open anything, or message anyone."
        },
        makeTitle: { _ in "Call coming up" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Forward with a note (ACTION — CONFIRM, sends to a new recipient)

    static let forwardWithNote = Playbook(
        id: "forward-with-note",
        name: "Forward + Note",
        icon: "arrowshape.turn.up.right",
        summary: "When an email should go to someone else, drafts a forward with a short note.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "can you forward", "please forward", "loop in", "cc ", "fyi",
                "send this to", "pass this along", "share with", "forward to"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "forward|" + key
        },
        makeGoal: { _ in
            "This email should be forwarded to someone else (the text asks to loop in / pass along / forward). Click Forward, add a brief one-line note at the top in the user's voice explaining why you're sending it, and set the recipient to the person clearly named in the email. Do NOT press Send — leave the forward staged in the compose box for the user to confirm the recipient and send, since forwarding introduces a new recipient."
        },
        makeTitle: { _ in "Draft a forward" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Draft a meeting-decline (ACTION — CONFIRM, drafts outgoing note)

    static let draftMeetingDecline = Playbook(
        id: "draft-meeting-decline",
        name: "Decline Note",
        icon: "hand.raised",
        summary: "A meeting you should decline → drafts a polite decline note (never sends).",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let onSurface = DefaultPlaybooks.isEmailSurface(ctx)
                || (ctx.appName + " " + ctx.windowTitle).lowercased().contains("calendar")
                || ctx.contextType.lowercased().contains("calendar")
            guard onSurface else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "invite", "invitation", "meeting request", "can you make", "are you free",
                "join us for", "would you like to attend"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "decline-note|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There is a meeting request the user is likely to decline. Draft a short, warm, professional decline message in the user's voice: thank them, decline clearly, and offer an alternative (a different time, or a colleague) if that fits. Open a reply/compose and type the note there, but do NOT press Send and do NOT click Decline on the invite — leave everything staged for the user to review."
        },
        makeTitle: { _ in "Draft a decline" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Extract action items (READ-ONLY draft — AUTO)

    static let extractActionItems = Playbook(
        id: "extract-action-items",
        name: "Action Items",
        icon: "checklist",
        summary: "From meeting notes or a recap email → a clean list of owners, tasks, and dates.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hasNotes = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "meeting notes", "notes", "recap", "minutes", "action items",
                "takeaways", "next steps", "follow-ups", "to do", "todo"
            ])
            guard hasNotes else { return nil }
            let hasOwnership = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "will", "to do", "assigned", "owner", "by friday", "by monday",
                "next week", "eod", "due", "@", "action"
            ])
            guard hasOwnership else { return nil }
            return "action-items|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "The screen shows meeting notes or a recap. Extract a clean action-item list: one line per task with the owner, the task in an imperative phrase, and the due date if stated (write \"no date\" otherwise). Group by owner if there are several. This is a read-only extraction — do not create tasks, send anything, or modify the notes; just produce the list."
        },
        makeTitle: { _ in "Pull action items" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Set an out-of-office reply (ACTION — CONFIRM, sends auto-replies)

    static let setOOOReply = Playbook(
        id: "set-ooo-reply",
        name: "Set Out-of-Office",
        icon: "airplane.departure",
        summary: "When you're heading out, sets a vacation auto-reply (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "out of office", "out-of-office", "vacation responder", "away message",
                "ooo", "auto-reply", "automatic reply", "on leave", "on vacation"
            ]) else { return nil }
            return "ooo|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "The user is setting up an out-of-office / vacation auto-reply. In the mail client's vacation-responder settings, draft a concise professional away message (dates out if known, who to contact for urgent matters, when they'll respond) and fill it into the responder field. Because an auto-reply is sent to everyone who emails during the window, do NOT toggle the responder ON or press Save — leave the dates and message staged for the user to confirm and enable."
        },
        makeTitle: { _ in "Set out-of-office" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Clear promotions pileup (ACTION — CONFIRM, bulk reversible archive)

    static let clearPromotionsPileup = Playbook(
        id: "clear-promotions-pileup",
        name: "Clear Promotions",
        icon: "archivebox.fill",
        summary: "A Promotions tab stuffed with marketing mail → archives the pile in one sweep.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "promotions", "promotion", "social", "updates tab", "% off", "sale",
                "deal", "limited time", "shop now", "unsubscribe"
            ]) else { return nil }
            let promoRows = ctx.screenText.lowercased().split(separator: "\n")
                .filter { $0.contains("off") || $0.contains("sale") || $0.contains("deal") || $0.contains("shop") }.count
            guard promoRows >= 4 else { return nil }
            return "promo-clear|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "The Promotions/marketing view is piled up with bulk mail. Select the promotional messages in the current view and Archive them together (select all in the Promotions category, then Archive) to clear the inbox. Archiving is reversible — the mail stays in All Mail. Because this is a bulk action, do NOT delete anything and do NOT touch messages that look personal or transactional (orders, receipts, tickets)."
        },
        makeTitle: { _ in "Clear promotions" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Summarize a long email thread (READ-ONLY draft — AUTO)

    static let summarizeEmailThread = Playbook(
        id: "summarize-email-thread",
        name: "Summarize Thread",
        icon: "text.append",
        summary: "A long back-and-forth email thread → a tight summary of the state and the ask.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            let hasThreadTells = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "wrote:", "on mon", "on tue", "on wed", "on thu", "on fri",
                "re: re:", "forwarded message", "-----original", "show trimmed content",
                "messages in this conversation"
            ])
            guard hasThreadTells else { return nil }
            guard ctx.screenText.count >= 1200 else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "thread-summary|" + key
        },
        makeGoal: { _ in
            "This is a long, multi-reply email thread. Summarize it tightly: the topic, who's involved, the key points and decisions in order, any open questions, and the single most important thing the user needs to do or answer next. This is read-only — do not reply, archive, or forward; just produce the summary."
        },
        makeTitle: { _ in "Summarize thread" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Delete spam / phishing (ACTION — CONFIRM, irreversible)

    static let deleteSpamEmail = Playbook(
        id: "delete-spam-email",
        name: "Delete Spam",
        icon: "trash.slash",
        summary: "When an open email is clear spam or phishing, moves it to trash (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "you have won", "verify your account", "suspended", "claim your prize",
                "act now", "wire transfer", "gift card", "confirm your password",
                "unusual sign-in", "your payment failed", "crypto", "nigerian prince"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "spam-delete|" + key
        },
        makeGoal: { _ in
            "The open email reads as spam or a phishing attempt (prize/verify/urgent-payment lures). Move it to Trash (or use \"Report spam\" if the client offers it). Do this one action only — do NOT click any link in the email, do NOT open attachments, and do NOT enter any information; deleting is the safe response and it stays recoverable in Trash for a while."
        },
        makeTitle: { _ in "Delete spam" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Mute a noisy thread (ACTION — AUTO, reversible)

    static let muteNoisyThread = Playbook(
        id: "mute-email-thread",
        name: "Mute Thread",
        icon: "bell.slash",
        summary: "A chatty reply-all thread that isn't for you → mutes it so it stops resurfacing.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEmailSurface(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "reply all", "replied to all", "+1", "thanks all", "me too",
                "congrats", "welcome to the team", "please stop reply all", "unsubscribe from thread"
            ]) else { return nil }
            guard let key = DefaultPlaybooks.emailKey(ctx) else { return nil }
            return "mute-thread|" + key
        },
        makeGoal: { _ in
            "This is a noisy reply-all thread that keeps resurfacing but doesn't need the user's attention. Mute it (Gmail: the Mute action, or press \"m\") so new replies skip the inbox and land in All Mail. Muting is fully reversible. Do not reply, archive individual messages, or leave the thread; just mute it."
        },
        makeTitle: { _ in "Mute this thread" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Block focus time (ACTION — AUTO, personal calendar hold, reversible)

    static let blockFocusTime = Playbook(
        id: "block-focus-time",
        name: "Block Focus Time",
        icon: "square.dashed.inset.filled",
        summary: "When the calendar shows a free stretch, blocks it as a personal focus hold.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let onCalendar = identity.contains("calendar") || identity.contains("fantastical")
                || ctx.contextType.lowercased().contains("calendar")
            guard onCalendar else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "no events", "free", "open block", "nothing scheduled", "focus time",
                "deep work", "heads down", "block time"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "focus-block|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The calendar shows an open stretch with no meetings. Create a personal \"Focus time\" event covering the largest free block visible (aim for 60-90 minutes), marked Busy so others don't book over it. Add no guests — this is a private hold for the user only, and it's reversible (they can delete or move it). Do not modify or delete any existing events."
        },
        makeTitle: { _ in "Block focus time" },
        makeTarget: { _ in .clipboard }
    )

    // ═══════════════════════════════════════════════════════════════════════
    // BROWSER · WEB · SHOPPING · RESEARCH — autonomous task library
    // (web-duplicate-tab-cleanup dropped: duplicate name/function of the existing
    //  closeDuplicateTabs playbook — see integrator note.)
    // ═══════════════════════════════════════════════════════════════════════

    static let webCookieConsentDismiss = Playbook(
        id: "web-cookie-consent",
        name: "Dismiss Consent Banner",
        icon: "hand.raised.slash.fill",
        summary: "Clears a cookie/consent banner covering a page using the least-committal option.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "accept all cookies", "we use cookies", "this website uses cookies",
                "cookie preferences", "manage cookies", "cookie settings",
                "we value your privacy", "your privacy choices", "reject all cookies"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-consent|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A cookie/consent banner is covering part of this web page. Dismiss it with the least-committal option: prefer a close/✕, then \"Reject all\", \"Decline\", or \"Only necessary\"; use \"Accept\" only if nothing else exists. Click exactly ONE control on the banner and nothing else on the page. This is reversible — the site can re-prompt later."
        },
        makeTitle: { _ in "Dismiss consent banner" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webStaleTabCleanup = Playbook(
        id: "web-stale-tab-cleanup",
        name: "Close Stale Tabs",
        icon: "clock.badge.xmark",
        summary: "When the browser flags inactive/sleeping tabs, closes the ones you haven't used.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "haven't viewed", "haven't used", "inactive tabs", "sleeping tab",
                "memory saver", "close tabs that", "tabs you haven't", "reloaded to save memory"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-stale|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The browser is surfacing inactive/sleeping tabs the user hasn't touched in a while. Close the clearly stale tabs, keeping any tab that is pinned, playing audio, or currently in focus. Reopening is possible via history, but be conservative and only close tabs the browser itself has marked inactive."
        },
        makeTitle: { _ in "Close stale tabs" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webFormRefill = Playbook(
        id: "web-form-refill",
        name: "Refill Known Form",
        icon: "square.and.pencil",
        summary: "A web form with fields you've filled before → offers to refill them (confirm).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            let labels = ["first name", "last name", "full name", "email", "phone number", "company", "job title"]
            let hits = labels.filter { hay.contains($0) }.count
            guard hits >= 3 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-refill|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This web page shows a form (name, email, phone, company, etc.) resembling ones the user has completed before. After confirmation, type the user's known details into the matching empty fields, leaving anything ambiguous blank. Do NOT submit the form or press any button that sends it — stop once the fields are filled so the user can review."
        },
        makeTitle: { _ in "Refill this form" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webArticleToNotes = Playbook(
        id: "web-article-to-notes",
        name: "Save Article to Notes",
        icon: "note.text.badge.plus",
        summary: "Reading a long article → saves a titled summary + link into your notes.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard ctx.screenText.count > 1400 else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "min read", "minute read", "min. read", "published", "written by", "by "
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-save-note|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is reading a long-form article. Create a note capturing the article's title, its source URL, and a 4-6 bullet summary of the key points, then save it into the Notes app (or the user's default notes surface). Preserve the original — this only adds a note, it does not modify the web page."
        },
        makeTitle: { _ in "Save article to notes" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webSmartBookmark = Playbook(
        id: "web-smart-bookmark",
        name: "Bookmark Into Folder",
        icon: "bookmark.fill",
        summary: "When a bookmark dialog is open, files it into the most fitting folder.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "add bookmark", "add to favorites", "bookmark added", "edit bookmark",
                "add this page to", "choose folder", "save bookmark"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-bookmark|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A bookmark dialog is open. Based on the page's topic and the existing bookmark folders, pick the most fitting destination folder in the dialog's folder selector and confirm the bookmark there. If no folder clearly fits, leave it in the default location. Bookmarks are trivially movable, so this is safe."
        },
        makeTitle: { _ in "Bookmark into folder" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webLoginAutofill = Playbook(
        id: "web-login-autofill",
        name: "Autofill Known Login",
        icon: "key.horizontal.fill",
        summary: "A login form for a known site → autofills your saved credentials (confirm, sensitive).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            let hasCredentialField = hay.contains("password")
            let hasIdentifier = hay.contains("username") || hay.contains("email")
            let hasAction = DefaultPlaybooks.screenTextContainsAny(ctx, ["sign in", "log in", "login", "continue"])
            guard hasCredentialField && hasIdentifier && hasAction else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-login|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This is a login form for a site the user has credentials for. After explicit confirmation, type the saved username/email and password into the matching fields. Do NOT click Sign In / Log In — leave the submit to the user so they can verify the entry. Treat credentials as sensitive: never echo the password anywhere but the password field."
        },
        makeTitle: { _ in "Autofill login" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webPriceCheck = Playbook(
        id: "web-price-check",
        name: "Price-Check Product",
        icon: "tag.fill",
        summary: "Viewing a product → researches its price elsewhere and reports the best deal.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: ["COMPOSIO_SEARCH"],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard ctx.screenText.contains("$") else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "add to cart", "add to bag", "buy now", "in stock", "free shipping", "add to basket"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-price|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is looking at a product page with a price. Identify the product name from the page, then use web search to find its price at other major retailers. Report a short comparison (this page's price vs. the cheapest alternative you found, with the retailer name). This is read-only research — do not add anything to a cart or change the page."
        },
        makeTitle: { _ in "Price-check this product" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webAddToCart = Playbook(
        id: "web-add-to-cart",
        name: "Add-to-Cart Assist",
        icon: "cart.badge.plus",
        summary: "On a product page → selects the right options and adds the item to the cart.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            guard hay.contains("add to cart") || hay.contains("add to bag") || hay.contains("add to basket") else { return nil }
            guard ctx.screenText.contains("$") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-cart|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is on a product page. Select the variant options they've indicated (size/color/quantity if already chosen, otherwise leave defaults), then click \"Add to Cart\". STOP there — do not proceed to checkout, enter payment, or place any order. Adding to a cart is reversible; buying is not, so never cross that line."
        },
        makeTitle: { _ in "Add to cart" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webCompareProducts = Playbook(
        id: "web-compare-products",
        name: "Compare Two Products",
        icon: "arrow.left.arrow.right.square",
        summary: "Two products on screen → explains the trade-offs and points out the differences.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let dollarCount = ctx.screenText.filter { $0 == "$" }.count
            guard dollarCount >= 2 else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "compare", " vs ", " vs.", "specifications", "which one", "side by side"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-compare|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "Two products are shown side by side. In a short spoken summary, explain the key trade-offs (price, standout specs, what each is better for) and point an arrow at the one that fits a typical buyer better, with a one-line reason. Only explain and point — do not click, add to cart, or change anything on the page."
        },
        makeTitle: { _ in "Compare these products" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let webResearchQuestion = Playbook(
        id: "web-research-question",
        name: "Research On-Screen Question",
        icon: "magnifyingglass.circle.fill",
        summary: "A question on screen → searches the web and summarizes a grounded answer.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: ["COMPOSIO_SEARCH"],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard ctx.screenText.contains("?") else { return nil }
            let hay = ctx.screenText.lowercased()
            let stems = ["how do i", "how to", "what is", "what are", "why does", "why is", "should i", "is it safe", "can i"]
            guard stems.contains(where: { hay.contains($0) }) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-research|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There is a clear question on screen the user is trying to answer. Extract the question, use web search to gather current, credible sources, and produce a concise grounded answer (3-5 sentences) with the one or two sources you relied on. This is read-only research — do not post, submit, or alter anything."
        },
        makeTitle: { _ in "Research this question" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webReadAloud = Playbook(
        id: "web-read-aloud",
        name: "Read Article Aloud",
        icon: "speaker.wave.2.fill",
        summary: "A long article → reads it aloud from where you are on the page.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard ctx.screenText.count > 2500 else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "min read", "minute read", "published", "written by", "read more", "continue reading"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-read-aloud|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is on a long article. Read the article's main body aloud in a natural voice, starting from the top of the visible content and scrolling as you go so the text keeps pace with the narration. Skip navigation, ads, and comments. Reading aloud changes nothing on the page and can be stopped at any time."
        },
        makeTitle: { _ in "Read article aloud" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webTranslatePage = Playbook(
        id: "web-translate-page",
        name: "Translate This Page",
        icon: "character.bubble.fill",
        summary: "A foreign-language page → translates it into your language in place.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "translate this page", "traducir esta", "traduire cette", "diese seite übersetzen",
                "política de privacidad", "données personnelles", "datenschutzerklärung", "questa pagina"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-translate|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This page is in a language other than the user's. Trigger the browser's built-in translation (use the address-bar Translate control or the right-click \"Translate to…\" menu) to render the page in the user's language. If no built-in translator is available, translate the visible text and speak a summary. This is a reversible view change."
        },
        makeTitle: { _ in "Translate this page" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webDownloadSort = Playbook(
        id: "web-download-sort",
        name: "File Download Into Folder",
        icon: "arrow.down.doc.fill",
        summary: "A just-downloaded file → moves it into the folder that fits its type/topic.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "show in finder", "keep file", "download complete", "downloaded", "1 download", "open file"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-download|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A file the browser just downloaded is sitting in Downloads. Based on its type and name (an invoice/PDF, an image, an installer, a dataset, etc.), move it into the matching destination folder in the user's Documents. Only move this one newly-downloaded file; moving a file is reversible."
        },
        makeTitle: { _ in "Sort downloaded file" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webReopenTab = Playbook(
        id: "web-reopen-tab",
        name: "Reopen Closed Tab",
        icon: "arrow.uturn.left.circle.fill",
        summary: "When the browser offers to restore closed tabs, reopens the ones you lost.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "restore previous session", "reopen closed tab", "restore pages",
                "didn't shut down correctly", "reopen last closed", "restore tabs"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-reopen|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The browser is offering to restore tabs the user lost (a crash-recovery bar, or the user just closed a tab by accident). Reopen the previously-closed tab(s) — click \"Restore\" if a bar is shown, otherwise use ⌘⇧T once. Reopening a tab is fully reversible; do not restore more than the session that was just lost."
        },
        makeTitle: { _ in "Reopen closed tab" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webMuteAutoplay = Playbook(
        id: "web-mute-autoplay",
        name: "Mute Autoplaying Tab",
        icon: "speaker.slash.fill",
        summary: "A tab that started playing audio/video on its own → mutes it.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "tab is playing audio", "mute tab", "now playing", "autoplay", "skip ad", "skip ads", "video will play"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-mute|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A browser tab has started playing audio/video on its own. Mute that tab — click the speaker/mute indicator on the offending tab (right-click the tab → \"Mute Tab\" if needed). Mute only the autoplaying tab, not the whole browser, and leave a tab the user deliberately started playing alone. Muting is instantly reversible."
        },
        makeTitle: { _ in "Mute autoplaying tab" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webGdprMinimal = Playbook(
        id: "web-gdpr-minimal",
        name: "Minimal GDPR Consent",
        icon: "checkmark.shield.fill",
        summary: "A GDPR/IAB consent wall → chooses only strictly-necessary and continues.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "legitimate interest", "our partners", "iab", "consent preferences",
                "manage preferences", "vendors", "gdpr", "purposes for which"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-gdpr|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A GDPR/IAB consent wall is blocking the page with granular tracking options. Choose the most privacy-preserving path: click \"Reject all\", \"Only necessary\", or open \"Manage preferences\" and disable every non-essential/vendor toggle, then Save/Confirm. Make exactly the minimal consent choice — never enable extra tracking. The site can re-ask, so this is reversible."
        },
        makeTitle: { _ in "Accept minimal consent" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webShippingAddress = Playbook(
        id: "web-shipping-address",
        name: "Fill Shipping Address",
        icon: "shippingbox.fill",
        summary: "A checkout shipping form → fills your saved address (confirm).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            let hasAddress = hay.contains("shipping address") || hay.contains("street address") || hay.contains("address line")
            let hasLocale = hay.contains("zip") || hay.contains("postal code") || hay.contains("city") || hay.contains("state")
            guard hasAddress && hasLocale else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-ship|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This checkout page has an empty shipping-address form. After confirmation, type the user's saved shipping address into the matching fields (street, apt/suite, city, state/region, ZIP/postal, country). Do NOT click \"Continue\", \"Place order\", or advance the checkout — stop after filling so the user reviews and proceeds themselves."
        },
        makeTitle: { _ in "Fill shipping address" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webCouponApply = Playbook(
        id: "web-coupon-apply",
        name: "Find & Apply Coupon",
        icon: "ticket.fill",
        summary: "A promo-code box at checkout → finds a working code and applies it (confirm).",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: ["COMPOSIO_SEARCH"],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "promo code", "coupon code", "discount code", "gift card or", "have a code", "add code"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-coupon|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This checkout page has a promo/coupon field. Identify the retailer, use web search to find current working discount codes, then after confirmation type the most promising code into the field and click \"Apply\" to test whether the total drops. Only apply codes into the coupon box — do NOT place the order or change payment. If a code fails, you may try one more, then stop."
        },
        makeTitle: { _ in "Find & apply coupon" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let webThreadSummary = Playbook(
        id: "web-thread-summary",
        name: "Summarize Web Thread",
        icon: "text.bubble.fill",
        summary: "A long forum/comment thread → summarizes the discussion and takeaways.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isBrowser(ctx) else { return nil }
            guard ctx.screenText.count > 1500 else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "replies", "comments", "upvote", "points ·", "posted by", "reply", "show more comments"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "web-thread|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is on a long forum/comment thread (Reddit, HN, a support forum, etc.). Read the visible discussion, scrolling to load more if needed, and produce a concise summary: the original question/topic, the top few positions or answers with their gist, and the overall consensus or best-supported takeaway. This is read-only — do not reply, vote, or post."
        },
        makeTitle: { _ in "Summarize this thread" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    // ═══════════════════════════════════════════════════════════════════════
    // CODING · TERMINAL · GITHUB — autonomy pack (mostly TEACH: draw + speak)
    // ═══════════════════════════════════════════════════════════════════════

    static let stackTraceExplain = Playbook(
        id: "stack-trace-explain",
        name: "Explain Stack Trace",
        icon: "list.bullet.indent",
        summary: "A multi-frame stack trace in your IDE → explains it aloud and arrows at the failing line.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            let hay = ctx.screenText.lowercased()
            let hasTraceWord = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "traceback (most recent call last)", "stack trace", "call stack",
                "at <anonymous>", "thread 1:", "backtrace:"
            ])
            // A real multi-frame trace, not a single "error" line: several
            // "at "/"file "/"line " frames stacked up.
            let frames = hay.components(separatedBy: "\n").filter {
                $0.contains(" at ") || $0.contains("  at") || $0.contains("line ") || $0.contains(".swift:") || $0.contains(".py\", line")
            }.count
            guard hasTraceWord || frames >= 3 else { return nil }
            return "stack-trace|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a multi-frame stack trace on my screen. In two spoken sentences, tell me which frame is my own code (not library code) and what actually threw, then draw an arrow at that line in the trace. Keep it short and spoken; don't edit anything."
        },
        makeTitle: { _ in "Explain the stack trace" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let mergeConflictResolve = Playbook(
        id: "merge-conflict-resolve",
        name: "Resolve Merge Conflict",
        icon: "arrow.triangle.merge",
        summary: "Conflict markers on screen → explains HEAD vs incoming and points at each marker.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText
            guard hay.contains("<<<<<<<") || (hay.contains(">>>>>>>") && hay.contains("=======")) else { return nil }
            return "merge-conflict|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There are Git merge-conflict markers on my screen. In two spoken sentences, explain which block is HEAD (my current branch) and which is the incoming change, and how to decide what to keep, then draw at the <<<<<<<, =======, and >>>>>>> markers so I can see the two sides. Don't edit the file for me."
        },
        makeTitle: { _ in "Resolve the conflict" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let prFilesChangedBrief = Playbook(
        id: "pr-files-changed-brief",
        name: "PR Files-Changed Brief",
        icon: "doc.on.doc",
        summary: "A GitHub PR → briefs what changed and points at the Files changed tab.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let onGitHub = ctx.contextType.lowercased().contains("github")
                || ctx.screenText.lowercased().contains("github.com")
            guard onGitHub else { return nil }
            let isPR = ctx.windowTitle.lowercased().contains("pull request")
                || ctx.screenText.lowercased().contains("files changed")
                || ctx.screenText.lowercased().contains("commits into")
            guard isPR else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "pr-files|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I'm on a GitHub pull request. In two or three spoken sentences, tell me what this PR changes and which files are worth looking at first, then point at the “Files changed” tab so I can jump straight there. Keep it brief and spoken; don't click anything."
        },
        makeTitle: { _ in "Brief this PR" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let terminalFailExplain = Playbook(
        id: "terminal-fail-explain",
        name: "Explain Command Failure",
        icon: "exclamationmark.triangle",
        summary: "A failed shell command → explains why and suggests the exact fix out loud.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "command not found", "no such file or directory", "non-zero exit",
                "exited with code", "returned exit code", "npm err", "fatal:",
                "not recognized", "cannot execute", "bad interpreter", "killed"
            ]) else { return nil }
            return "term-fail-x|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "My terminal shows a command that just failed. In one or two spoken sentences, explain why it failed and say the exact corrected command or flag to run, then point at the failing line. Keep it short and spoken; don't type or run anything."
        },
        makeTitle: { _ in "Explain the failure" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let failingTestExplain = Playbook(
        id: "failing-test-explain",
        name: "Explain Failing Test",
        icon: "xmark.seal",
        summary: "A failing test run → explains the assertion that broke and where to look.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            let hasAssertion = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "assertionerror", "assertion failed", "expected", "to equal",
                "to be", "received", "xctassert", "assert_eq"
            ])
            let hasTestFrame = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "tests failed", "test failed", "failing", "✕", "● ", "pytest",
                "jest", "npm test", "0 passed", "failures:", "run tests"
            ])
            guard hasAssertion, hasTestFrame else { return nil }
            return "test-fail|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "A test just failed on my screen. In one or two spoken sentences, tell me which assertion broke and what expected-versus-actual mismatch caused it, then point at the failing test line. Keep it short and spoken; don't change any code."
        },
        makeTitle: { _ in "Explain the failing test" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let lintErrorPoint = Playbook(
        id: "lint-error-point",
        name: "Point at Lint / Type Error",
        icon: "checkmark.shield",
        summary: "A lint or type-checker complaint → points at the flagged code and says the fix.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) || DefaultPlaybooks.isTerminal(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "eslint", "no-unused-vars", "prettier", "flake8", "mypy",
                "type error", "is declared but its value is never read",
                "cannot assign to", "swiftlint", "ts(", "does not conform to",
                "is not assignable to", "implicitly has an 'any'"
            ]) else { return nil }
            return "lint-error|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a lint or type-checker warning on my screen. In one spoken sentence, say what rule or type mismatch is being flagged and the smallest change that satisfies it, then point an arrow at the flagged code. Keep it short and spoken; don't edit it for me."
        },
        makeTitle: { _ in "Point at the lint error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let todoFixmeSurface = Playbook(
        id: "todo-fixme-surface",
        name: "Surface TODO / FIXME",
        icon: "flag",
        summary: "A TODO or FIXME note in your code → reads it back and points at it.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "todo:", "// todo", "# todo", "fixme:", "// fixme", "# fixme",
                "hack:", "xxx:", "@todo"
            ]) else { return nil }
            return "todo|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a TODO or FIXME comment visible in my code. In one spoken sentence, read back what it says needs doing and whether it looks quick or involved, then point at the comment. Keep it short and spoken; don't act on it."
        },
        makeTitle: { _ in "You left a TODO" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let dependencyErrorExplain = Playbook(
        id: "dependency-error-explain",
        name: "Explain Dependency Error",
        icon: "shippingbox",
        summary: "A package/version resolution error → explains the conflict and the fix.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "unable to resolve dependency", "could not find a version",
                "no matching version", "peer dependency", "version solving failed",
                "incompatible", "requires python", "eresolve", "conflicting",
                "cocoapods could not find", "unsatisfied dependency", "npm err! peer"
            ]) else { return nil }
            return "dep-error|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a dependency or version-resolution error on my screen. In two spoken sentences, explain which two packages or versions are in conflict and the usual way out (pin, bump, or a resolution override), then point at the offending line. Keep it short and spoken; don't run anything."
        },
        makeTitle: { _ in "Explain the dependency error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let commitMessageDraft = Playbook(
        id: "commit-message-draft",
        name: "Draft Commit Message",
        icon: "text.badge.checkmark",
        summary: "A visible git diff → drafts a Conventional-Commits message to the clipboard (you review).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            let hasDiff = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "diff --git", "changes to be committed", "changes not staged for commit",
                "please enter the commit message", "@@ -", "index "
            ])
            guard hasDiff else { return nil }
            return "commit-msg|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "Read the git diff of the staged changes shown on my screen and write a Conventional-Commits message: a summary line under 72 characters (type(scope): subject) plus a short body of one-line bullets describing the notable changes. Put the finished message on the clipboard so I can paste it into my own commit. Do NOT run git commit, do NOT press any button, and do NOT type into any window yourself."
        },
        makeTitle: { _ in "Draft commit message" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: false
    )

    static let ciFailureExplain = Playbook(
        id: "ci-failure-explain",
        name: "Explain CI Failure",
        icon: "bolt.trianglebadge.exclamationmark",
        summary: "A red CI / Actions run → explains which job failed and points at the logs.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = ctx.screenText.lowercased()
            let onCI = hay.contains("github.com") || hay.contains("/actions")
                || hay.contains("workflow") || DefaultPlaybooks.screenTextContainsAny(ctx, [
                    "gitlab ci", "circleci", "jenkins", "travis", "buildkite"
                ])
            guard onCI else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "failing check", "checks failed", "some checks were not successful",
                "workflow run failed", "job failed", "pipeline failed", "build failed",
                "1 failing", "this workflow run"
            ]) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "ci-fail|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A CI run failed on my screen. In two spoken sentences, tell me which job or step went red and the most likely reason from what's visible, then point at the failed job so I can open its logs. Keep it short and spoken; don't click anything."
        },
        makeTitle: { _ in "Explain the CI failure" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let unhandledExceptionPoint = Playbook(
        id: "unhandled-exception-point",
        name: "Point at Unhandled Exception",
        icon: "exclamationmark.octagon",
        summary: "An uncaught exception crash → explains it and points at where to add handling.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "unhandled exception", "uncaught exception", "uncaught (in promise)",
                "unhandledpromiserejection", "unhandled promise rejection",
                "terminating with uncaught", "fatal error:", "goroutine",
                "panic:", "thread 'main' panicked"
            ]) else { return nil }
            return "unhandled-exc|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "My program crashed with an unhandled exception on screen. In two spoken sentences, name the exception type and what triggered it, then point at the line where I should add a try/catch or guard. Keep it short and spoken; don't edit anything."
        },
        makeTitle: { _ in "Unhandled exception" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let menuShortcutSuggest = Playbook(
        id: "menu-shortcut-suggest",
        name: "Suggest Keyboard Shortcut",
        icon: "command",
        summary: "Repeated menu clicking → speaks the keyboard shortcut and draws the key combo.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) || DefaultPlaybooks.isTerminal(ctx) else { return nil }
            let hasMenu = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "file   edit", "edit   view", "\u{2318}", "selection   view", "run   terminal"
            ])
            let hasAction = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "comment", "rename symbol", "format document", "go to definition",
                "find in files", "toggle terminal", "command palette", "run build"
            ])
            guard hasMenu, hasAction else { return nil }
            return "menu-shortcut|" + ctx.appName
        },
        makeGoal: { _ in
            "I'm reaching through menus for something a keyboard shortcut would do instantly in this editor. In one spoken sentence, name the exact shortcut, and draw the key combo on screen. Keep it short and friendly; don't trigger it for me."
        },
        makeTitle: { _ in "Try this shortcut" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let regexExplain = Playbook(
        id: "regex-explain",
        name: "Explain Regex",
        icon: "textformat.abc.dottedunderline",
        summary: "A regular expression on screen → breaks it down in plain English out loud.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            let tokens = ["(?:", "(?=", "(?!", "\\d", "\\w", "\\s", "\\b",
                          "[a-z", "[0-9", "[^", "]+", ".*?", "\\/"]
            let hits = tokens.filter { ctx.screenText.lowercased().contains($0) }.count
            guard hits >= 2 else { return nil }
            return "regex|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a regular expression on my screen. In two or three spoken sentences, walk through what it matches, piece by piece, in plain English, and draw at the trickiest part of the pattern. Keep it conversational; don't change it."
        },
        makeTitle: { _ in "Explain this regex" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let offByOnePoint = Playbook(
        id: "off-by-one-point",
        name: "Point at Off-by-One",
        icon: "arrow.left.and.right",
        summary: "An index-out-of-range error → explains the off-by-one and points at the bound.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "index out of range", "list index out of range",
                "arrayindexoutofbounds", "index out of bounds",
                "string index out of range", "off by one", "off-by-one",
                "index is out of range", "range or index"
            ]) else { return nil }
            return "off-by-one|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "An index-out-of-range error is on my screen — the classic off-by-one. In one or two spoken sentences, explain that the loop or index is reaching one past the end and whether the fix is a <= that should be < (or a +1/-1), then point at the indexing line. Keep it short and spoken; don't edit it."
        },
        makeTitle: { _ in "Looks off-by-one" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let apiErrorExplain = Playbook(
        id: "api-error-explain",
        name: "Explain API Error",
        icon: "network.badge.shield.half.filled",
        summary: "An HTTP error response → explains the status code and likely cause.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) || DefaultPlaybooks.isBrowser(ctx) else { return nil }
            let hasStatus = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "400 bad request", "401 unauthorized", "403 forbidden",
                "404 not found", "409 conflict", "422 unprocessable",
                "429 too many requests", "500 internal server error",
                "502 bad gateway", "503 service unavailable"
            ])
            let hasErrBody = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "\"error\"", "\"message\"", "\"errors\"", "\"detail\"", "\"code\""
            ])
            guard hasStatus, hasErrBody else { return nil }
            return "api-error|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's an HTTP error response on my screen. In two spoken sentences, explain what the status code means here and the most likely cause given the error body (auth, a bad field, rate limit, or server-side), then point at the status line. Keep it short and spoken; don't retry anything."
        },
        makeTitle: { _ in "Explain the API error" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let gitignoreSuggest = Playbook(
        id: "gitignore-suggest",
        name: "Suggest .gitignore Entry",
        icon: "eye.slash",
        summary: "Untracked junk in git status → suggests the .gitignore lines to add.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) else { return nil }
            guard ctx.screenText.lowercased().contains("untracked files") else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "node_modules", ".env", "__pycache__", ".ds_store", "dist/",
                "build/", ".venv", "target/", ".idea", "*.log", "coverage/"
            ]) else { return nil }
            return "gitignore|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "Git status shows untracked files that clearly shouldn't be committed. In one or two spoken sentences, name the exact .gitignore lines to add for the junk I can see (build output, dependencies, env files), and point at those files in the status list. Keep it short and spoken; don't edit .gitignore for me."
        },
        makeTitle: { _ in "Add to .gitignore" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let dockerfileIssueExplain = Playbook(
        id: "dockerfile-issue-explain",
        name: "Explain Dockerfile Issue",
        icon: "cube.box",
        summary: "A Dockerfile or docker build error → explains the problem layer and the fix.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let identity = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isDockerfile = identity.contains("dockerfile")
                && (DefaultPlaybooks.isEditorOrIDE(ctx))
            let isBuildError = DefaultPlaybooks.isTerminal(ctx) && DefaultPlaybooks.screenTextContainsAny(ctx, [
                "failed to solve", "docker build", "returned a non-zero code",
                "executor failed running", "dockerfile:", "no such file or directory"
            ]) && ctx.screenText.lowercased().contains("docker")
            guard isDockerfile || isBuildError else { return nil }
            return "dockerfile|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "There's a Dockerfile problem or a docker build failure on my screen. In two spoken sentences, explain which instruction (FROM/COPY/RUN) is at fault and why — a missing file, wrong path, bad base image, or layer-cache issue — and how to fix it, then point at that line. Keep it short and spoken; don't run the build."
        },
        makeTitle: { _ in "Explain the Dockerfile issue" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let missingImportPoint = Playbook(
        id: "missing-import-point",
        name: "Point at Missing Import",
        icon: "arrow.down.doc",
        summary: "A not-defined / unresolved symbol → says which import is missing and points at it.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) || DefaultPlaybooks.isTerminal(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "is not defined", "cannot find name", "cannot find symbol",
                "use of unresolved identifier", "undefined name", "no module named",
                "modulenotfounderror", "importerror", "name error", "nameerror",
                "cannot find type", "unresolved reference"
            ]) else { return nil }
            return "missing-import|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "A symbol on my screen is unresolved because an import is missing. In one spoken sentence, name the module or file I need to import and the exact import line to add at the top, then point an arrow at the undefined symbol. Keep it short and spoken; don't add the import for me."
        },
        makeTitle: { _ in "Missing an import" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let permissionDeniedExplain = Playbook(
        id: "permission-denied-explain",
        name: "Explain Permission Denied",
        icon: "lock.trianglebadge.exclamationmark",
        summary: "A permission-denied error → explains why and the safe way to fix access.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isTerminal(ctx) || DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            guard DefaultPlaybooks.screenTextContainsAny(ctx, [
                "permission denied", "eacces", "operation not permitted",
                "access is denied", "not permitted", "insufficient permission",
                "you don't have permission", "eperm", "must be run as root"
            ]) else { return nil }
            return "perm-denied|" + ctx.appName + "|" + ctx.windowTitle
        },
        makeGoal: { _ in
            "A permission-denied error is on my screen. In one or two spoken sentences, explain what lacks access — a file mode, an owner, or a protected directory — and the safe fix (chmod/chown on my own file, or the right path) without blindly reaching for sudo, then point at the failing line. Keep it short and spoken; don't run anything."
        },
        makeTitle: { _ in "Explain permission denied" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    static let unfamiliarRepoBrief = Playbook(
        id: "unfamiliar-repo-brief",
        name: "Brief Unfamiliar Repo",
        icon: "folder.badge.questionmark",
        summary: "A repo just opened in your editor → gives a spoken orientation of what it is.",
        autoTriggers: true,
        cooldownSeconds: 3600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            guard DefaultPlaybooks.isEditorOrIDE(ctx) else { return nil }
            let hasReadme = ctx.screenText.lowercased().contains("readme")
            let hasProjectMarker = DefaultPlaybooks.screenTextContainsAny(ctx, [
                "package.json", "cargo.toml", "go.mod", "requirements.txt",
                "pom.xml", "build.gradle", "gemfile", "pyproject.toml",
                "getting started", "installation", "src/", "license"
            ])
            guard hasReadme, hasProjectMarker else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "repo-brief|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I just opened an unfamiliar repository in my editor. From the README and project files visible, give me a spoken three-sentence orientation: what the project is, the main language or framework, and where the entry point or interesting code lives. Point at the README or the key folder. Keep it conversational; don't open or change anything."
        },
        makeTitle: { _ in "Get oriented in this repo" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // ═══════════════════════════════════════════════════════════════════════
    // MESSAGING · DOCS · MEDIA — autonomous task library (ACTION + TEACH)
    // ═══════════════════════════════════════════════════════════════════════

    // MARK: - Message Reply & Send (ACT — CONFIRM, sends)

    static let messageReplySend = Playbook(
        id: "message-reply-send",
        name: "Message Reply",
        icon: "arrowshape.turn.up.left.circle",
        summary: "When a chat message is waiting, drafts a reply from recent context and sends it (after you confirm).",
        autoTriggers: true,
        cooldownSeconds: 240,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle + " " + ctx.contextType).lowercased()
            let isMessaging = hay.contains("messages") || hay.contains("imessage")
                || hay.contains("whatsapp") || hay.contains("slack") || hay.contains("discord")
            guard isMessaging else { return nil }
            let contact = (ctx.entities["contact"] ?? "").trimmingCharacters(in: .whitespaces)
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            guard !(contact.isEmpty && title.isEmpty) else { return nil }
            // Something must actually look like an incoming message awaiting a reply.
            guard !contact.isEmpty || ctx.screenText.contains("?") else { return nil }
            return "msg-send|" + (contact.isEmpty ? title : contact)
        },
        makeGoal: { ctx in
            let contact = ctx.entities["contact"] ?? "the contact"
            return "An incoming message from \(contact) in a chat app (iMessage, WhatsApp, Slack, or Discord) is waiting for a reply. Read the recent conversation on screen for context, click into the message input box, type a concise reply that matches the thread's existing tone and directly answers what was asked, and then send it (press Return or click the Send button). Sending is not reversible, so compose and send exactly ONE reply and touch nothing else."
        },
        makeTitle: { ctx in
            let contact = ctx.entities["contact"] ?? ""
            return contact.isEmpty ? "Reply and send" : "Reply to \(contact)"
        },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Document Outline (TEACH)

    static let docOutline = Playbook(
        id: "doc-outline",
        name: "Document Outline",
        icon: "list.bullet.indent",
        summary: "A long document on screen → speaks a suggested outline and marks the natural section breaks.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let id = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isDoc = ["microsoft word", "word", "pages", "google docs", "- docs",
                         "notion", "scrivener", "ulysses", "obsidian"].contains { id.contains($0) }
            guard isDoc, ctx.screenText.count >= 1500 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "doc-outline|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a long document on my screen. In a few spoken sentences, propose an outline for it — the main sections and their key sub-points, in the order that would read best — and draw brackets or markers next to the natural section breaks visible on screen. Don't edit the document; just talk me through the structure."
        },
        makeTitle: { _ in "Outline this doc" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Document Formatting Fix (ACT — AUTO, reversible)

    static let docFormatFix = Playbook(
        id: "doc-format-fix",
        name: "Fix Doc Formatting",
        icon: "textformat",
        summary: "A document with messy formatting → normalizes spacing, headings, and list styles in place.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let id = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isDoc = ["microsoft word", "word", "pages", "google docs", "- docs",
                         "notion", "scrivener", "ulysses", "obsidian"].contains { id.contains($0) }
            guard isDoc, ctx.screenText.count >= 1200 else { return nil }
            // A rough tell of uneven formatting: stray triple newlines or tab runs.
            guard ctx.screenText.contains("\n\n\n") || ctx.screenText.contains("\t") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "doc-format|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The document on screen has inconsistent formatting — mixed spacing, stray blank lines, or uneven heading and bullet styles. Clean it up in place: normalize the heading levels, make list and bullet styles consistent, and remove extra blank lines and trailing spaces. Keep every word of the actual text exactly as the author wrote it — change only formatting, delete no content. Every edit is undoable."
        },
        makeTitle: { _ in "Fix formatting" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Chart Suggestion (TEACH)

    static let chartSuggest = Playbook(
        id: "chart-suggest",
        name: "Chart Suggestion",
        icon: "chart.bar.xaxis",
        summary: "A table of data in a spreadsheet → suggests the best chart type and points at the range to select.",
        autoTriggers: true,
        cooldownSeconds: 1800,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let id = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isSheet = id.contains("numbers") || id.contains("excel")
                || id.contains("google sheets") || id.contains("- sheets")
            guard isSheet else { return nil }
            guard ctx.screenText.filter({ $0.isNumber }).count >= 15 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "chart-suggest|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a table of data in this spreadsheet. In one or two spoken sentences, suggest the single chart type that would show it best (bar, line, pie, scatter…) and which columns belong on each axis, then circle or point at the data range I should select first. Don't build the chart for me; just guide me."
        },
        makeTitle: { _ in "Suggest a chart" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Spreadsheet Formula Help (TEACH)

    static let formulaHelp = Playbook(
        id: "formula-help",
        name: "Formula Help",
        icon: "function",
        summary: "A formula or #REF!/#VALUE! error in a spreadsheet → explains the fix and points at the cell.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let id = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isSheet = id.contains("numbers") || id.contains("excel")
                || id.contains("google sheets") || id.contains("- sheets")
            guard isSheet else { return nil }
            let s = ctx.screenText.lowercased()
            let formulaCue = s.contains("#value!") || s.contains("#ref!") || s.contains("#name?")
                || s.contains("#div/0!") || s.contains("#n/a") || s.contains("=sum")
                || s.contains("=vlookup") || s.contains("=xlookup") || s.contains("=if(")
                || s.contains("=index") || s.contains("formula")
            guard formulaCue else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "formula-help|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I'm working on a spreadsheet formula and may be stuck — there's a formula or an error like #REF! / #VALUE! / #N/A on screen. In a spoken sentence or two, tell me the exact formula to use and why, or what's wrong with the current one, and point at the cell it belongs in. Don't type it for me; just explain it out loud."
        },
        makeTitle: { _ in "Fix the formula" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Tweet Draft (ACT — AUTO, stages, never posts)

    static let tweetDraft = Playbook(
        id: "tweet-draft",
        name: "Tweet Draft",
        icon: "bird",
        summary: "When the X compose box is open, drafts a tweet into it (never posts).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            let isX = hay.contains("twitter") || hay.contains("x.com")
                || s.contains("x.com") || s.contains("what is happening") || s.contains("what's happening")
            let composing = s.contains("post your reply") || s.contains("what is happening")
                || s.contains("what's happening") || s.contains("add another post") || hay.contains("compose")
            guard isX, composing else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "tweet-draft|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user is on X (Twitter) with the compose box open. Draft a single tweet, 280 characters or fewer, in the user's voice about what's relevant on screen — punchy, specific, no hashtag spam, no engagement-bait — and type it into the compose box. Do NOT post it: leave the draft in the box for the user to review and send themselves."
        },
        makeTitle: { _ in "Draft a tweet" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Call Notes (ACT — AUTO, captures notes)

    static let callNotes = Playbook(
        id: "call-notes",
        name: "Call Notes",
        icon: "note.text",
        summary: "During a call with captions on, captures running meeting notes to the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            let inCall = hay.contains("zoom") || hay.contains("meet") || hay.contains("teams")
                || hay.contains("webex") || hay.contains("facetime")
                || s.contains("leave meeting") || s.contains("leave call")
            let hasCaptions = s.contains("live caption") || s.contains("captions")
                || s.contains("transcript") || s.contains("turn on captions")
            guard inCall, hasCaptions else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "call-notes|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I'm in a video call and captions or a transcript are visible on screen. From what's being said, capture running meeting notes — key decisions, action items (with owners when named), and open questions — as a tight bulleted summary, and copy the notes to the clipboard so I can paste them afterward. Keep them factual; don't invent anything that wasn't said."
        },
        makeTitle: { _ in "Take call notes" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Pause Music on Call (ACT — AUTO, reversible)

    static let pauseMusicOnCall = Playbook(
        id: "pause-music-on-call",
        name: "Pause Music on Call",
        icon: "pause.circle",
        summary: "When a call starts, pauses any playing music so the call audio is clear.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            let callStart = s.contains("incoming call") || s.contains("is calling")
                || s.contains("join now") || s.contains("connecting") || s.contains("start video")
                || (hay.contains("facetime") && s.contains("accept"))
            guard callStart else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "pause-music|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "A call is starting or coming in. If music or video is playing in Spotify, Apple Music, or a browser tab, pause it so the call audio is clear — use the app's play/pause control or the media key. This is fully reversible; playback can be resumed after the call."
        },
        makeTitle: { _ in "Pause music for call" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Lower Volume on Call (ACT — AUTO, reversible)

    static let lowerVolumeOnCall = Playbook(
        id: "lower-volume-on-call",
        name: "Lower Volume on Call",
        icon: "speaker.wave.1",
        summary: "When you're unmuted and talking on a call, nudges the system volume down.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            let inCall = hay.contains("zoom") || hay.contains("meet") || hay.contains("teams")
                || hay.contains("webex") || hay.contains("facetime")
                || s.contains("leave meeting") || s.contains("leave call")
            guard inCall else { return nil }
            // A "Mute" button (not "Unmute") means the mic is live — the user is speaking.
            guard s.contains("mute") && !s.contains("unmute") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "lower-volume|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "I'm on a call and appear to be unmuted and speaking. Lower the system output volume a few notches so the other audio doesn't drown me out or cause echo — use the volume-down control. This is reversible; the volume can be raised again after."
        },
        makeTitle: { _ in "Lower call volume" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - LinkedIn Message Reply (ACT — AUTO, stages)

    static let linkedinMessageReply = Playbook(
        id: "linkedin-message-reply",
        name: "LinkedIn Message Reply",
        icon: "envelope.open",
        summary: "A LinkedIn message thread awaiting a reply → drafts one into the box (never sends).",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            guard hay.contains("linkedin") || s.contains("linkedin.com") else { return nil }
            guard s.contains("messaging") || s.contains("write a message")
                || s.contains("send a message") || (s.contains("message") && s.contains("reply")) else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "li-msg|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a LinkedIn message thread open that's waiting on a reply. Read the recent messages for context and type a concise, professional-but-warm reply in the user's voice into the message box. Do NOT press Send — leave the draft in the box for the user to review and send themselves."
        },
        makeTitle: { _ in "Reply on LinkedIn" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - YouTube Summary (TEACH)

    static let youtubeSummary = Playbook(
        id: "youtube-summary",
        name: "YouTube Summary",
        icon: "play.rectangle",
        summary: "A YouTube video on screen → speaks a quick summary from its title and description.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            guard hay.contains("youtube") || s.contains("youtube") || s.contains("youtu.be") else { return nil }
            guard s.contains("subscribe") || s.contains("subscribers")
                || s.contains("views") || s.contains("show more") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "yt-summary|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a YouTube video on screen. From its title and description (read whatever is visible, including under 'Show more'), give me a spoken two-or-three sentence summary of what the video covers and whether it's worth my time, and point at the description area. Don't play or change anything."
        },
        makeTitle: { _ in "Summarize this video" },
        makeTarget: { _ in .clipboard },
        isTeachScenario: true
    )

    // MARK: - Extract Steps / Recipe (ACT — AUTO, to clipboard)

    static let extractSteps = Playbook(
        id: "extract-steps",
        name: "Extract Steps",
        icon: "list.number",
        summary: "A recipe or how-to buried in prose → pulls the clean step list to the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let s = ctx.screenText.lowercased()
            let stepCue = s.contains("ingredients") || s.contains("instructions")
                || s.contains("directions") || s.contains("step 1") || s.contains("step 2")
                || s.contains("prep time") || s.contains("preheat") || s.contains("serves ")
                || s.contains("how to")
            guard stepCue, ctx.screenText.count >= 800 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "extract-steps|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This page contains a recipe or a how-to with the actual steps buried in prose and ads. Extract just the essentials — the ingredient or material list, then the numbered steps in order — into a clean, compact checklist, and copy it to the clipboard so I can follow it without the clutter. Keep quantities and details accurate to the page; don't invent steps."
        },
        makeTitle: { _ in "Extract the steps" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Chat Thread → Task List (ACT — AUTO, to clipboard)

    static let chatToTasks = Playbook(
        id: "chat-to-tasks",
        name: "Chat to Tasks",
        icon: "checklist",
        summary: "A chat thread full of asks → turns the commitments into a task list on the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle + " " + ctx.contextType).lowercased()
            let isChat = hay.contains("slack") || hay.contains("discord") || hay.contains("messages")
                || hay.contains("teams") || hay.contains("whatsapp")
            guard isChat else { return nil }
            let s = ctx.screenText.lowercased()
            let actionCue = s.contains("can you") || s.contains("todo") || s.contains("to-do")
                || s.contains("action item") || s.contains("let's") || s.contains("we need to")
                || s.contains("by friday") || s.contains("by monday") || s.contains("deadline")
                || s.contains("follow up") || s.contains("don't forget")
            guard actionCue else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "chat-tasks|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "This chat thread has commitments and requests scattered through the conversation. Pull out every actionable item into a clear task list — one line per task, with the owner and any due date when the thread names them — and copy the list to the clipboard. Only include real asks from the conversation; don't invent tasks."
        },
        makeTitle: { _ in "Chat → task list" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Thank-You Note (ACT — AUTO, drafts to clipboard)

    static let thankYouNote = Playbook(
        id: "thank-you-note",
        name: "Thank-You Note",
        icon: "heart.text.square",
        summary: "A thank-you-worthy moment on screen → drafts a warm, specific note to the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle + " " + ctx.contextType).lowercased()
            let isMsgSurface = hay.contains("mail") || hay.contains("gmail")
                || hay.contains("outlook") || hay.contains("messages") || hay.contains("email")
            guard isMsgSurface else { return nil }
            let s = ctx.screenText.lowercased()
            let cue = s.contains("interview") || s.contains("offer") || s.contains("congratulations")
                || s.contains("gift") || s.contains("recommendation") || s.contains("referral")
                || s.contains("thanks for having") || s.contains("introduction")
            guard cue else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "thank-you|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The message on screen is a moment that deserves a thank-you — an interview, an offer, an introduction, a gift, or a favor. Draft a short, warm, specific thank-you note in the user's voice that references the actual thing they're grateful for, keeping it genuine and non-templated, and copy it to the clipboard. Do not send anything."
        },
        makeTitle: { _ in "Draft a thank-you" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Slack Mentions Summary (ACT — AUTO, to clipboard)

    static let slackMentionsSummary = Playbook(
        id: "slack-mentions-summary",
        name: "Slack Mentions Summary",
        icon: "at.circle",
        summary: "Unread Slack mentions → summarizes who needs what, prioritized, to the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            guard hay.contains("slack") else { return nil }
            let s = ctx.screenText.lowercased()
            guard s.contains("mention") || s.contains("unread") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "slack-mentions|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "Slack is showing unread mentions or threads that need the user's attention. Summarize them into a short, prioritized list — who mentioned the user, in which channel, and what they're asking or need — most time-sensitive first, and copy the summary to the clipboard. Read only what's on screen; don't post or react to anything."
        },
        makeTitle: { _ in "Summarize mentions" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Review / Comment Reply (ACT — AUTO, stages)

    static let reviewReply = Playbook(
        id: "review-reply",
        name: "Review Reply",
        icon: "star.bubble",
        summary: "A customer review or comment with a reply box → drafts a professional response (never posts).",
        autoTriggers: true,
        cooldownSeconds: 600,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let s = ctx.screenText.lowercased()
            let reviewCue = (s.contains("review") && (s.contains("star") || s.contains("rating") || ctx.screenText.contains("★")))
                || s.contains("reply to review") || s.contains("respond to review") || s.contains("leave a reply")
            guard reviewCue else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "review-reply|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's a customer review or a comment on screen with a place to respond. Draft a reply in the user's voice — thank them, address their specific point, and stay professional and non-defensive even if the review is negative — and type it into the reply box. Do NOT submit it: leave the draft for the user to review and post themselves."
        },
        makeTitle: { _ in "Reply to review" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Status Update (ACT — AUTO, drafts to clipboard)

    static let statusUpdate = Playbook(
        id: "status-update",
        name: "Status Update",
        icon: "megaphone",
        summary: "A standup or status prompt → drafts a done/next/blockers update to the clipboard.",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            // Strong, explicit cues only. The earlier version also matched
            // "today i" / "yesterday i" / "what did you" / "blockers", which appear
            // in ordinary emails, chats, docs and articles — so it fired on nearly
            // any text screen. Those loose fragments are gone; require a real
            // standup/status phrase.
            let s = ctx.screenText.lowercased()
            let statusCue = s.contains("standup") || s.contains("stand-up")
                || s.contains("status update") || s.contains("daily update")
                || s.contains("daily standup") || s.contains("what did you get done")
            guard statusCue else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "status-update|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user needs to post a status or standup update. From what's visible about their recent work on screen (commits, tickets, docs, chat), draft a crisp update in the standard shape — what was done, what's next, and any blockers — in the user's voice, and copy it to the clipboard. Keep it factual to what's on screen; don't invent progress."
        },
        makeTitle: { _ in "Draft a status update" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Document Proofread Fix (ACT — AUTO, reversible)

    static let docProofreadFix = Playbook(
        id: "doc-proofread-fix",
        name: "Proofread Doc",
        icon: "text.badge.checkmark",
        summary: "Writing in a doc editor → fixes clear spelling and grammar mistakes in place.",
        autoTriggers: true,
        cooldownSeconds: 1200,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let id = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let isDoc = ["microsoft word", "word", "pages", "google docs", "- docs",
                         "notion", "scrivener", "ulysses", "obsidian"].contains { id.contains($0) }
            guard isDoc, ctx.screenText.count >= 800 else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "doc-proofread|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "There's writing in this document that could use a light proofread. Fix clear spelling and grammar mistakes and obvious typos in place, without changing the author's voice, meaning, or word choices beyond the corrections. Make only genuine corrections and leave stylistic choices alone. Every edit is undoable."
        },
        makeTitle: { _ in "Proofread this doc" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - LinkedIn Post from Your Work (ACT — AUTO, stages)

    static let linkedinWorkPost = Playbook(
        id: "linkedin-work-post",
        name: "LinkedIn Work Post",
        icon: "square.and.pencil",
        summary: "The LinkedIn post composer is open → drafts an authentic post about your work (never publishes).",
        autoTriggers: true,
        cooldownSeconds: 900,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let hay = (ctx.appName + " " + ctx.windowTitle).lowercased()
            let s = ctx.screenText.lowercased()
            guard hay.contains("linkedin") || s.contains("linkedin.com") else { return nil }
            guard s.contains("start a post") || s.contains("what do you want to talk about")
                || s.contains("share an update") || s.contains("create a post") else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "li-post|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The user has the LinkedIn post composer open. Draft an authentic, non-cringe LinkedIn post grounded in what they've been working on (visible on screen or recent context) — first person, one concrete idea, a real observation rather than a hook formula, no engagement-bait, at most two hashtags, 80-150 words — and type it into the composer. Do NOT post it: leave the draft for the user to review and publish."
        },
        makeTitle: { _ in "Draft a LinkedIn post" },
        makeTarget: { _ in .clipboard }
    )

    // MARK: - Resume Music on Call End (ACT — AUTO, reversible)

    static let musicResumeOnCallEnd = Playbook(
        id: "music-resume-on-call-end",
        name: "Resume Music After Call",
        icon: "play.circle",
        summary: "When a call ends, resumes the music that was paused for it.",
        autoTriggers: true,
        cooldownSeconds: 300,
        composioApps: [],
        usesDing: false,
        kind: .aiAnswer,
        matches: { ctx in
            let s = ctx.screenText.lowercased()
            let ended = s.contains("meeting has ended") || s.contains("call ended")
                || s.contains("you left the meeting") || s.contains("meeting ended")
                || s.contains("call has ended") || s.contains("the meeting is over") || s.contains("rejoin")
            guard ended else { return nil }
            let title = ctx.windowTitle.trimmingCharacters(in: .whitespaces)
            return "resume-music|" + (title.isEmpty ? ctx.appName : title)
        },
        makeGoal: { _ in
            "The call has just ended. If music or media was paused when the call started, resume playback in Spotify or Apple Music using the play control (or the media key) so the user's audio picks back up. This is reversible — it can be paused again."
        },
        makeTitle: { _ in "Resume music" },
        makeTarget: { _ in .clipboard }
    )
}
