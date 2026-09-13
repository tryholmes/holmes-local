import Foundation

// MARK: - Playbook Models
// Shared types for Holmes's proactive-automation playbooks. A playbook watches the
// user's screen context and, when it matches, runs a DRAFT-ONLY agent pass that can
// read/fetch/search but is deterministically incapable of sending anything.
// These types are the single source of truth — referenced by PlaybookEngine,
// HolmesBrain (runPlaybook), ScreenGlow, and the ConfirmationBus draft cards.

// MARK: - PlaybookContext
// A normalized snapshot of what Holmes currently sees, fed to playbook matchers.

struct PlaybookContext {
    let appName: String
    let windowTitle: String
    let contextType: String          // raw value of ContextEngine's context type
    let screenText: String           // OCR/AX text
    let entities: [String: String]   // canonical keys below
}

// Canonical entity keys used in PlaybookContext.entities:
//   "sender", "subject", "recipient", "contact", "promptText",
//   "repoOwner", "repoName", "platform", "eventTitle", "eventId"

// MARK: - DraftKind

enum DraftKind: String {
    case emailCompose, emailReply, promptSuggestion, repoBrief, linkedInPost, meetingPrep, chatReply, aiAnswer
    case briefing, triage
    case followUp, prRadar, scheduleAlert, wrapup
}

// MARK: - DraftTarget
// Where an approved draft should land. Staging text into an app still goes through
// ActionExecutor, which never presses Send/Return.

enum DraftTarget {
    case emailCompose(EmailComposeSnapshot) // exact body-only target, revalidated after review
    case typeIntoApp(appName: String)     // stage via ActionExecutor after user approval
    case remoteDraft(urlString: String?)  // e.g. a Gmail draft was created; offer Open
    case clipboard
}

// MARK: - ProactiveDraft
// The output of a playbook run — shown in the review card, editable before use.

struct ProactiveDraft: Identifiable {
    let id: UUID
    let playbookId: String
    let kind: DraftKind
    let title: String
    var body: String                 // editable in the review card
    let contextSummary: String
    let target: DraftTarget
    // Ground-truth facts about server-side writes this run performed (e.g.
    // "to ada@x.com — “Re: Lunch”"), built from the TOOL-CALL INPUT, never from
    // model prose — so the review card/notification always show where a staged
    // Gmail draft is actually addressed, even if the model's summary lies.
    let stagedNote: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        playbookId: String,
        kind: DraftKind,
        title: String,
        body: String,
        contextSummary: String,
        target: DraftTarget,
        stagedNote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.playbookId = playbookId
        self.kind = kind
        self.title = title
        self.body = body
        self.contextSummary = contextSummary
        self.target = target
        self.stagedNote = stagedNote
        self.createdAt = createdAt
    }
}

// MARK: - Playbook
// A declarative proactive automation. `matches` returns nil for no match, or a stable
// context key used for cooldown + debounce (same key on two consecutive evaluations fires).

struct Playbook: Identifiable {
    let id: String
    let name: String
    let icon: String                 // SF Symbol name
    let summary: String              // one-line, shown in Settings
    let autoTriggers: Bool           // false = manual only
    let cooldownSeconds: Double
    let composioApps: [String]       // e.g. ["GMAIL"]; [] = no MCP needed
    let usesDing: Bool
    let kind: DraftKind
    let matches: (PlaybookContext) -> String?    // nil = no match; else stable context key for cooldown
    let makeGoal: (PlaybookContext) -> String    // agent goal prompt
    let makeTitle: (PlaybookContext) -> String
    let makeTarget: (PlaybookContext) -> DraftTarget
    /// TEACH vs ACT dispatch for the autonomy path. When true (confirm/auto with
    /// the master switch on), PlaybookEngine.fire routes to the draw-on-screen +
    /// speak guidance path (VisualGuidance) instead of the AutonomousActionRunner
    /// — the playbook explains/points rather than mutating anything. Defaults to
    /// false so every existing playbook keeps its behavior unchanged.
    var isTeachScenario: Bool = false
    /// SDK (manifest) playbooks only. A custom draft-only persona; PlaybookEngine
    /// wraps it in a fixed safety preamble so the author's text can narrow the
    /// voice and shape of the deliverable but never widen what the model may do.
    var persona: String? = nil
    /// SDK playbooks only. Names of servers in mcp.json whose tools may be
    /// offered — still filtered to readOnlyHint + ComposioCatalog.isPlaybookSafe,
    /// exactly like Composio tools. Built-ins leave this empty.
    var mcpServers: [String] = []
    /// SDK playbooks only: the manifest file name, shown as a badge in Settings.
    var source: String? = nil
}

// MARK: - ComposioCatalog
// The draft-never-send tool policy. Playbook mode filters the tool list BEFORE the
// model ever sees it — anything that could send/mutate simply isn't offered, so no
// approval flow is needed (or possible) inside a playbook run.
//
// Policy, applied to the UPPERCASED tool name, matched on WHOLE tokens (split on
// non-alphanumerics) so "PLAYLIST" can never match "LIST" and "GETTR" can never
// match "GET":
//   1. draft tools: SEND -> BLOCKED; CREATE -> ALLOWED (a created draft is inert,
//      e.g. GMAIL_CREATE_EMAIL_DRAFT); anything else falls through to rules 2-5
//      (so GMAIL_LIST_DRAFTS is allowed but GMAIL_DELETE_DRAFT /
//      OUTLOOK_UPDATE_EMAIL_DRAFT are blocked)
//   2. contains any sendBlocklist token         -> BLOCKED
//   3. contains a conjunction (AND/OR)          -> BLOCKED (compound action —
//      the half after the conjunction may be a mutation verb we don't know)
//   4. contains any readAllowlist token         -> ALLOWED
//   5. anything else                            -> BLOCKED (default deny)
//
// NOTE (integrator): rule 1 is deliberately TIGHTER than the original design
// contract, whose "contains DRAFT and not SEND -> ALLOWED" would have allowlisted
// destructive draft-mutation tools like GMAIL_DELETE_DRAFT with no approval gate.
//
// NOTE (hardening): rule 1's CREATE carve-out applies ONLY to tools offered
// directly in the playbook tool list — NEVER to tool_slugs routed through
// COMPOSIO_MULTI_EXECUTE_TOOL, which are held to the stricter
// isMetaSlugReadOnly policy below (a server-side draft is still a server-side
// write, and playbook mode has no approval gate) — with exactly ONE sanctioned
// exception: the EXACT-match metaDraftAllowlist (GMAIL_CREATE_EMAIL_DRAFT),
// checked in validateMetaExecute. See metaDraftAllowlist's doc for why.

enum ComposioCatalog {

    /// Tokens that mark a tool as side-effecting. Any match (after the draft
    /// exception) blocks the tool in playbook mode.
    static let sendBlocklist: [String] = [
        "SEND", "DELETE", "REMOVE", "DESTROY", "UPDATE", "PATCH", "PUBLISH",
        "UPLOAD", "EXECUTE", "CREATE", "POST", "WRITE", "ARCHIVE", "TRASH",
        "MOVE", "MARK", "REPLY", "FORWARD",
        "ADD", "INSERT", "APPEND", "MERGE", "SAVE", "SHARE", "SUBMIT", "ACCEPT",
        // Hardening pass: mutation verbs the original list missed. Without
        // these, any slug pairing one with a read token (GMAIL_LIST_AND_STAR)
        // slipped past the "any read token allows" step. Whole-token matching
        // keeps reads like GMAIL_LIST_STARRED (STARRED != STAR) unaffected;
        // blocking the occasional read-only noun collision (e.g.
        // GITHUB_GET_A_WORKFLOW_RUN) is the accepted default-deny trade-off.
        "STAR", "UNSTAR", "PIN", "UNPIN", "ENABLE", "DISABLE", "SET", "MODIFY",
        "ASSIGN", "CLOSE", "LOCK", "UNLOCK", "CANCEL", "TRIGGER", "RUN",
        "DISPATCH", "SYNC", "REVOKE", "GRANT", "RENAME", "IMPORT", "EXPORT",
        "RESTORE", "EDIT", "CHANGE", "APPLY", "TOGGLE", "RESET", "CLEAR",
        "PURGE", "COPY", "CLONE", "FORK", "TRANSFER", "INVITE", "JOIN",
        "LEAVE", "MUTE", "UNMUTE", "SNOOZE", "SUBSCRIBE", "UNSUBSCRIBE",
        "APPROVE", "REJECT", "DECLINE", "DISMISS", "REOPEN",
        "START", "STOP", "PAUSE", "RESUME"
    ]

    /// Tokens that mark a tool as read-only. Only checked after the blocklist,
    /// so e.g. "SEND_AND_FETCH" stays blocked.
    static let readAllowlist: [String] = [
        "GET", "LIST", "FETCH", "SEARCH", "FIND", "READ", "RETRIEVE",
        "LOOKUP", "QUERY", "HISTORY", "PROFILE"
    ]

    /// Conjunction tokens. A slug like GMAIL_LIST_AND_<verb> names a compound
    /// action, and the half after the conjunction may be a mutation verb the
    /// blocklist doesn't know. Read-only tools don't need conjunctions, so any
    /// slug containing one is denied outright.
    private static let compoundTokens: Set<String> = ["AND", "OR"]

    private static let blockTokens = Set(sendBlocklist)
    private static let readTokens = Set(readAllowlist)

    /// Whole-token split of an UPPERCASED tool name (non-alphanumerics are
    /// separators), so "PLAYLIST" can never match "LIST".
    private static func tokenSet(_ toolName: String) -> Set<String> {
        Set(
            toolName.uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    /// The 5-step default-deny policy. `true` means the tool may be offered to the
    /// model in playbook (draft-only) mode. Callers must pass the BARE tool name
    /// (no "server__" prefix, untruncated) so a user-chosen MCP server name can
    /// never contaminate the decision.
    static func isPlaybookSafe(toolName: String) -> Bool {
        let tokens = tokenSet(toolName)

        // 1. Draft tools: creation is the one sanctioned "write" — a draft is inert.
        //    Everything else that touches drafts (DELETE, UPDATE, TRASH, ...) falls
        //    through to the blocklist below. This carve-out does NOT apply to
        //    slugs routed through the meta executor — see isMetaSlugReadOnly.
        if tokens.contains("DRAFT") || tokens.contains("DRAFTS") {
            if tokens.contains("SEND") { return false }
            if tokens.contains("CREATE") { return true }
        }

        // 2. Anything that sends, mutates, or publishes is out.
        if !tokens.isDisjoint(with: blockTokens) { return false }

        // 3. Compound-action names are out: a conjunction means the slug does
        //    more than one thing, and only the first half may be a read.
        if !tokens.isDisjoint(with: compoundTokens) { return false }

        // 4. Pure reads are in.
        if !tokens.isDisjoint(with: readTokens) { return true }

        // 5. Unknown verbs: default deny.
        return false
    }

    /// True when a bare tool name is a draft-CREATE write — i.e. it would pass
    /// isPlaybookSafe ONLY via rule 1's creation carve-out. Used by HolmesBrain
    /// to hold DIRECTLY-offered draft-create tools (from any non-Composio MCP
    /// server) to the same `allowDraftWrite` kind gate and recipient-grounding
    /// guard as the meta-executor path: a server-side draft is the same write
    /// no matter which server exposes it, and a read-only playbook must never
    /// be offered one regardless of the server's self-declared annotations.
    static func isDraftCreateTool(_ toolName: String) -> Bool {
        let tokens = tokenSet(toolName)
        return (tokens.contains("DRAFT") || tokens.contains("DRAFTS"))
            && tokens.contains("CREATE")
            && !tokens.contains("SEND")
    }

    // MARK: Composio meta-tool surface
    // The hosted Composio MCP server exposes only META tools; every real action
    // (GITHUB_GET_A_REPOSITORY, GMAIL_FETCH_EMAILS, ...) runs THROUGH
    // COMPOSIO_MULTI_EXECUTE_TOOL. Playbook mode may offer the two read-only meta
    // tools plus the executor, but the executor's INNER tool_slugs are validated
    // per-call by validateMetaExecute — a STRICTER policy than isPlaybookSafe
    // (see isMetaSlugReadOnly), applied at dispatch time instead of tool-list time.

    /// Read-only meta tools (readOnlyHint on the server): safe to offer as-is.
    static let metaReadTools: Set<String> = ["COMPOSIO_SEARCH_TOOLS", "COMPOSIO_GET_TOOL_SCHEMAS"]

    /// The meta executor. Offered in playbook mode ONLY behind validateMetaExecute.
    static let metaExecuteTool = "COMPOSIO_MULTI_EXECUTE_TOOL"

    /// The single sanctioned autonomous write. A draft created in the user's own
    /// Gmail Drafts folder cannot send itself — the user reviews it in Gmail
    /// before anything leaves their account — so GMAIL_CREATE_EMAIL_DRAFT is
    /// allowed through the meta-execute guard by EXACT slug match even though
    /// the name contains CREATE. Reviewers previously REJECTED a generic
    /// CREATE+DRAFT token carve-out here (it would wholesale-allowlist unknown
    /// server-side draft writes across every app): exact match only — never
    /// widen this to token matching, and never add a slug that can send, share,
    /// or publish. validateMetaExecute's app-scope check still applies, so the
    /// slug only clears for playbooks whose composioApps include GMAIL.
    static let metaDraftAllowlist: Set<String> = ["GMAIL_CREATE_EMAIL_DRAFT"]

    /// Every meta tool on the hosted Composio MCP server, exact-match denied as
    /// inner tool_slugs (no meta-in-meta). An exact set rather than a
    /// "COMPOSIO_" prefix test because Composio's own search app's REAL action
    /// slugs (COMPOSIO_SEARCH_SEARCH, COMPOSIO_SEARCH_NEWS_SEARCH, ...) share
    /// the prefix and must stay executable — the ai-research playbook declares
    /// COMPOSIO_SEARCH in its composioApps. Non-meta COMPOSIO_* slugs fall
    /// through to isMetaSlugReadOnly's default deny like any other slug.
    static let metaToolNames: Set<String> = [
        "COMPOSIO_SEARCH_TOOLS", "COMPOSIO_GET_TOOL_SCHEMAS",
        "COMPOSIO_WAIT_FOR_CONNECTIONS", "COMPOSIO_MULTI_EXECUTE_TOOL",
        "COMPOSIO_REMOTE_BASH_TOOL", "COMPOSIO_REMOTE_WORKBENCH",
        "COMPOSIO_MANAGE_CONNECTIONS"
    ]

    /// STRICT read-only policy for inner tool_slugs routed through the meta
    /// executor. Deliberately tighter than isPlaybookSafe: there is NO
    /// draft-creation carve-out IN THIS FUNCTION — CREATE blocks like every
    /// other mutation token, so this predicate stays honestly read-only. The
    /// one sanctioned exception (GMAIL_CREATE_EMAIL_DRAFT) is applied by
    /// validateMetaExecute via the EXACT-match metaDraftAllowlist, never here,
    /// so token-based matching can never widen the write surface.
    static func isMetaSlugReadOnly(_ slug: String) -> Bool {
        let tokens = tokenSet(slug)
        if !tokens.isDisjoint(with: blockTokens) { return false }
        if !tokens.isDisjoint(with: compoundTokens) { return false }
        return !tokens.isDisjoint(with: readTokens)
    }

    /// Validates a COMPOSIO_MULTI_EXECUTE_TOOL call for playbook (draft-only) mode.
    /// Default deny: the call is allowed only when `arguments["tools"]` is a
    /// non-empty array of objects and EVERY item's `tool_slug`:
    ///   1. is a non-empty String (uppercased before all checks),
    ///   2. is not one of the seven Composio meta tools (no meta-in-meta),
    ///   3. is an EXACT match in metaDraftAllowlist (the single sanctioned
    ///      autonomous write — an inert Gmail draft, and ONLY when the caller
    ///      passes `allowDraftWrite: true`) OR passes isMetaSlugReadOnly
    ///      (strictly read-only — no draft-creation carve-out, no
    ///      compound-action names), and
    ///   4. when `composioApps` is non-empty, contains one of those app slugs
    ///      (case-insensitive) — so a GITHUB playbook can't read Gmail, and
    ///      GMAIL_CREATE_EMAIL_DRAFT only clears for playbooks declaring GMAIL.
    /// One bad slug blocks the whole call; anything unexpected blocks the call.
    ///
    /// `allowDraftWrite` gates the allowlist on INTENT, not just app scope:
    /// playbooks documented as strictly read-only (morning-brief, meeting-prep,
    /// evening-wrapup) declare GMAIL for fetching, and must not be able to
    /// silently create drafts. Only draft-disclosing kinds (email-reply,
    /// email-triage, follow-up-chaser) pass true. Defaults to false so any
    /// caller that forgets stays read-only.
    static func validateMetaExecute(arguments: [String: Any], composioApps: [String], allowDraftWrite: Bool = false) -> (allowed: Bool, reason: String) {
        guard let rawTools = arguments["tools"] else {
            return (false, "the required 'tools' array is missing")
        }
        guard let items = rawTools as? [[String: Any]] else {
            return (false, "'tools' is not an array of objects")
        }
        guard !items.isEmpty else {
            return (false, "the 'tools' array is empty")
        }
        let apps = composioApps.map { $0.uppercased() }
        for item in items {
            guard let rawSlug = item["tool_slug"] as? String, !rawSlug.isEmpty else {
                return (false, "a tools item has no String 'tool_slug'")
            }
            let slug = rawSlug.uppercased()
            if metaToolNames.contains(slug) {
                return (false, "meta tool '\(slug)' cannot be nested inside an execute call")
            }
            // Exact-match draft allowlist first: the one sanctioned autonomous
            // write (see metaDraftAllowlist). Everything else must be read-only.
            if !metaDraftAllowlist.contains(slug) {
                guard isMetaSlugReadOnly(slug) else {
                    return (false, "tool_slug '\(slug)' is not a read-only tool")
                }
            } else if !allowDraftWrite {
                return (false, "tool_slug '\(slug)' (draft creation) is not permitted for this playbook — it is read-only")
            }
            if !apps.isEmpty, !apps.contains(where: { slug.contains($0) }) {
                return (false, "tool_slug '\(slug)' is outside this playbook's apps (\(apps.joined(separator: ", ")))")
            }
        }
        return (true, "all tool_slugs are read-only")
    }

    // MARK: Sanctioned-draft argument guard (GMAIL_CREATE_EMAIL_DRAFT)
    // The slug allowlist alone leaves the CREATE call's ARGUMENTS fully
    // model-controlled — a prompt-injected email could stage an exfiltration
    // draft addressed to an attacker. Two mitigations, enforced by HolmesBrain
    // at dispatch time:
    //   1. every recipient address in the draft-create arguments must already
    //      have appeared in data FETCHED by an earlier tool call in the same
    //      run (no out-of-band recipients the model invented or was injected
    //      with — the draft can only be addressed to observed participants);
    //   2. the true recipient/subject are captured from the tool-call input
    //      (never from model prose) and surfaced on the review card and
    //      notification via ProactiveDraft.stagedNote.

    /// The name of the MCP server that hosts the Composio meta tools. Meta
    /// tools are honored ONLY from this server (see HolmesBrain) so another
    /// configured server cannot impersonate the guarded executor.
    static let composioServerName = "composio"

    /// Argument keys that address a draft. Checked case-insensitively.
    private static let recipientKeys: Set<String> = [
        "recipient_email", "recipient", "to", "to_email", "to_emails",
        "cc", "cc_email", "cc_emails", "bcc", "bcc_email", "bcc_emails"
    ]

    private static let emailRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    )

    /// Every email address in a blob of text (tool results, argument values),
    /// lowercased for stable comparison.
    static func emailAddresses(in text: String) -> Set<String> {
        guard let regex = emailRegex, !text.isEmpty else { return [] }
        var found: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            if let match, let r = Range(match.range, in: text) {
                found.insert(text[r].lowercased())
            }
        }
        return found
    }

    /// Items of a meta-execute call whose tool_slug is a sanctioned draft-create.
    static func draftCreateItems(in arguments: [String: Any]) -> [[String: Any]] {
        guard let items = arguments["tools"] as? [[String: Any]] else { return [] }
        return items.filter { item in
            guard let slug = item["tool_slug"] as? String else { return false }
            return metaDraftAllowlist.contains(slug.uppercased())
        }
    }

    /// The inner arguments of a meta-execute item. Composio uses "arguments";
    /// tolerate the common variants so a renamed key can't dodge the guard.
    static func innerArguments(of item: [String: Any]) -> [String: Any] {
        for key in ["arguments", "input", "params", "tool_input"] {
            if let dict = item[key] as? [String: Any] { return dict }
        }
        return [:]
    }

    /// Recipient addresses (to/cc/bcc/recipient_email…) of a draft-create item.
    static func recipientAddresses(of item: [String: Any]) -> Set<String> {
        var addresses: Set<String> = []
        for (key, value) in innerArguments(of: item)
        where recipientKeys.contains(key.lowercased()) {
            if let string = value as? String {
                addresses.formUnion(emailAddresses(in: string))
            } else if let array = value as? [String] {
                for entry in array { addresses.formUnion(emailAddresses(in: entry)) }
            }
        }
        return addresses
    }

    /// Grounding check for the one sanctioned autonomous write: every recipient
    /// of the draft must already have been seen in this run's fetched data.
    static func validateDraftRecipients(item: [String: Any], knownAddresses: Set<String>) -> (allowed: Bool, reason: String) {
        let unknown = recipientAddresses(of: item).subtracting(knownAddresses)
        guard unknown.isEmpty else {
            return (false, "draft recipient(s) \(unknown.sorted().joined(separator: ", ")) did not appear in any data fetched earlier in this run — fetch the thread first and address the draft to its actual participants")
        }
        return (true, "recipients grounded in fetched data")
    }

    /// Human-readable fact line for a staged draft, built from the tool-call
    /// INPUT so the review card shows the true recipient, not model prose.
    static func describeDraftCreate(_ item: [String: Any]) -> String {
        let recipients = recipientAddresses(of: item)
        let to = recipients.isEmpty ? "(no recipient)" : recipients.sorted().joined(separator: ", ")
        let args = innerArguments(of: item)
        if let subject = args["subject"] as? String, !subject.isEmpty {
            return "to \(to) — “\(String(subject.prefix(60)))”"
        }
        return "to \(to)"
    }

    /// Extracts Composio app slugs from namespaced MCP tool names.
    /// Names are "server__TOOL_NAME"; the slug is the segment after the first "__"
    /// up to the first "_", e.g. "composio__GMAIL_FETCH_EMAILS" -> "GMAIL".
    static func connectedApps(toolNames: [String]) -> Set<String> {
        var apps: Set<String> = []
        for name in toolNames {
            guard let separator = name.range(of: "__") else { continue }
            let remainder = name[separator.upperBound...]
            guard !remainder.isEmpty else { continue }
            let slug = remainder.prefix(while: { $0 != "_" })
            guard !slug.isEmpty else { continue }
            apps.insert(String(slug).uppercased())
        }
        return apps
    }
}
