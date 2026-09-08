import Foundation

// MARK: - AutonomyGate
// The load-bearing safety layer for autonomous action. Holmes's autonomy policy is
// AUTO-REVERSIBLE, CONFIRM-SENDS: an opted-in playbook does reversible work on its
// own and pauses for ONE human confirm only when a step is irreversible or
// outward-facing (send/delete/buy/post/⌘S-class), or when it moves the user's
// files. This file does not invent new guards — it COMPOSES the ones that already
// ship and hold the line today:
//   • ComputerUseEngine.shared.isIrreversible(action:input:) — the AX-label +
//     commit-key-chord classifier for pixel steps (ComputerUseEngine.swift).
//   • ComposioCatalog — the draft-never-send token policy; its
//     recipientAddresses(of:) / innerArguments helpers ground send recipients
//     in fetched data (PlaybookModels.swift).
//   • The browser extension's SEND_RE verb list (holmes-extension/automation.js:61)
//     — mirrored into `sendVerbList` below so the DOM path, the pixel path
//     (ComputerUseEngine.sendVerbRegex), and the API path all draw the
//     "never commit on the user's behalf" line at the same words.
//   • PlaybookEngine.isEnabled(playbookId) — the existing per-playbook enable.
//   • AutonomyPolicy (AutonomyPolicy.swift) — the SINGLE source of truth for the
//     global "Autonomous actions" master switch (default OFF) and the
//     per-playbook Observe/Draft/Confirm/Auto level. AutonomyGate deliberately
//     stores neither: it reads AutonomyPolicy.shared so Settings and the gate can
//     never disagree.
// The draft-only guarantee EVOLVES here rather than breaking: the irreversible-
// confirm gate is the new invariant, and autonomy stays OFF by default — the user
// opts each playbook in by raising its level dial.

// The `PlannedStep` this gate classifies is the canonical shape declared in
// ActionPlanner.swift (action / input:[String:Any] / backend:String / reversible
// / summary). `reversible` is the PLANNER'S claim — AutonomyGate treats a `false`
// as authoritative (a planner that flags its own step irreversible is always
// believed) but never lets a `true` override the backend ground-truth checks
// below: a "reversible" click that lands on a Send button still confirms.

// MARK: - AutonomyGate

@MainActor
enum AutonomyGate {

    // MARK: - mayAct: the entry gate

    /// Whether autonomy may act AT ALL for this playbook right now. Checked by the
    /// executor before planning a single step. All four legs must hold:
    ///   1. the global "Autonomous actions" master switch is ON (default OFF —
    ///      AutonomyPolicy.shared.masterEnabled),
    ///   2. the playbook itself is enabled (PlaybookEngine.isEnabled — the same
    ///      switch every draft-path fire site honors; kept as an independent leg
    ///      so the legacy boolean and the new dial must BOTH say yes, fail closed
    ///      even mid-migration),
    ///   3. its EFFECTIVE level is at least .confirm — effectiveLevel(for:)
    ///      already clamps to ≤ .draft while the master switch is off, so legs 1
    ///      and 3 double-lock the same door on purpose,
    ///   4. it hasn't exhausted its rate budget (see recordAct).
    static func mayAct(playbookId: String) -> Bool {
        let policy = AutonomyPolicy.shared
        guard policy.masterEnabled else { return false }
        guard PlaybookEngine.isEnabled(playbookId) else { return false }
        guard policy.effectiveLevel(for: playbookId) >= .confirm else { return false }
        guard !isRateLimited(playbookId: playbookId) else { return false }
        return true
    }

    // MARK: - Rate limiting (in-memory sliding window)
    //
    // A runaway trigger loop must not turn into a runaway ACTION loop. Budgets are
    // deliberately small — autonomy is for occasional real work, not a firehose —
    // and in-memory only: a relaunch resets them, which errs on the side of the
    // user's own fresh start, while the PlaybookEngine cooldowns (per context)
    // remain the first line against re-fires.

    /// Max autonomous fires per playbook per hour.
    static let maxActsPerPlaybookPerHour = 6
    /// Max autonomous fires across ALL playbooks per hour.
    static let maxActsTotalPerHour = 20

    private static let rateWindow: TimeInterval = 3600
    private static var recentActs: [String: [Date]] = [:]

    /// True when either the per-playbook or the global hourly budget is spent.
    static func isRateLimited(playbookId: String) -> Bool {
        pruneActs()
        if (recentActs[playbookId]?.count ?? 0) >= maxActsPerPlaybookPerHour { return true }
        if recentActs.values.reduce(0, { $0 + $1.count }) >= maxActsTotalPerHour { return true }
        return false
    }

    /// The executor calls this once per autonomous run it actually starts (after
    /// mayAct cleared it), consuming budget. Not called for draft-only runs.
    static func recordAct(playbookId: String) {
        pruneActs()
        recentActs[playbookId, default: []].append(Date())
    }

    /// Drops timestamps older than the window so the dictionary can't grow;
    /// nil-for-empty also drops dead playbook keys.
    private static func pruneActs() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        recentActs = recentActs.compactMapValues { dates in
            let kept = dates.filter { $0 > cutoff }
            return kept.isEmpty ? nil : kept
        }
    }

    // MARK: - requiresConfirmation: the per-step gate

    /// Classifies whether a step needs a human confirm under the autonomy rules.
    ///
    /// Contract by level:
    ///   • .observe / .draft — always true. These levels never reach execution;
    ///     if a step gets here anyway, fail closed and demand a human.
    ///   • .confirm — always true, and the CALLER collapses it: the whole plan is
    ///     shown once (one card listing every step.summary) and a single approval
    ///     covers the run. This function stays per-step so the caller can also
    ///     highlight WHICH steps are the dangerous ones on that card.
    ///   • .auto — reversible steps run free; irreversible/outward steps confirm.
    ///     Irreversibility is decided by backend ground truth, never by trusting
    ///     the planner's `reversible: true` claim (a `false` IS trusted):
    ///       – computer steps → ComputerUseEngine.shared.isIrreversible(action:input:)
    ///         (commit key chords + AX-label send-verb match + nameless-control
    ///         fail-closed in messaging apps),
    ///       – API/Composio steps → token check on the action name mirroring
    ///         ComposioCatalog (SEND/DELETE/PUBLISH/POST/… → irreversible) plus
    ///         the extension SEND_RE verb list,
    ///       – file-move steps → irreversible BY POLICY (they touch the user's
    ///         files): default confirm, even when the plan claims reversible.
    ///         The only bypass is level == .auto AND the plan explicitly marking
    ///         the step trivially undoable (input["trivially_undoable"] == true)
    ///         AND reversible == true — a generic reversible claim is not enough.
    static func requiresConfirmation(_ step: PlannedStep, level: AutonomyLevel) -> Bool {
        switch level {
        case .observe, .draft:
            // Never executable at these levels — fail closed if asked anyway.
            return true
        case .confirm:
            // One plan-level confirm; caller shows a single card for the run.
            return true
        case .auto:
            // The planner's own NEGATIVE claim is always believed.
            if !step.reversible { return true }

            // File moves: irreversible-by-policy (locked decision — moving the
            // user's files is significant), checked BEFORE the backend lanes so
            // a Finder drag or an API move can't slip through as "reversible".
            if isFileMoveStep(step) {
                return !isTriviallyUndoable(step)
            }

            // AppleScript source can do anything ("do shell script", keystroke
            // return) and no token classifier can read it — always confirm.
            if step.action.lowercased() == "applescript" { return true }

            // Backend ground truth beats a reversible:true claim. BackendRouter
            // sends every backend string it does not recognise to the pixel
            // lane, so the gate must classify the same way: anything that is not
            // a known structured/API backend is treated as a computer step.
            if isComputerBackend(step.backend) || !isStructuredBackend(step.backend) {
                // Exact reuse of the shipping pixel-path classifier: commit key
                // chords (return/⌘S/⌘W/⌘Q/⌘⌫), AX send-verb labels under the
                // click point, and the nameless-control fail-closed rule in
                // native messaging apps.
                return ComputerUseEngine.shared.isIrreversible(action: step.action, input: step.input)
            }
            // API / Composio / EventKit / NSWorkspace / unknown backends: the
            // action NAME carries the verb (GMAIL_SEND_EMAIL, deleteEvent, …).
            return apiActionIsIrreversible(step.action)
        }
    }

    // MARK: - Backend classification

    /// Backends that mean "Clicky posts pixels" — everything else is the API lane.
    private static let computerBackends: Set<String> = [
        "computer", "computeruse", "computer_use", "computer-use", "clicky", "pixels", "screen"
    ]

    /// The computer primitives by NAME, so a mislabeled backend string on an
    /// actual pixel step still routes to the file-move drag check below.
    private static let computerPrimitives: Set<String> = [
        "screenshot", "cursor_position", "wait", "open_app",
        "mouse_move", "left_click", "right_click", "middle_click", "double_click",
        "triple_click", "left_mouse_down", "left_mouse_up", "left_click_drag",
        "scroll", "key", "hold_key", "type"
    ]

    /// Mirror of BackendRouter.lane(for:)'s app + composio cases. Keep in sync.
    private static let structuredBackends: Set<String> = [
        "app", "nsworkspace", "workspace", "file", "files", "fs", "finder", "filesystem",
        "applescript", "eventkit", "calendar", "ax", "composio", "mcp", "api"
    ]
    private static func isStructuredBackend(_ backend: String) -> Bool {
        structuredBackends.contains(backend.lowercased())
    }

    private static func isComputerBackend(_ backend: String) -> Bool {
        computerBackends.contains(backend.lowercased())
    }

    // MARK: - API irreversibility (token policy)
    //
    // Mirrors the two shipping verb lines, folded into one whole-token set:
    //   • the extension's SEND_RE (holmes-extension/automation.js:61) /
    //     ComputerUseEngine.sendVerbRegex verbs — the outward-commit words:
    //     send, submit, post, publish, tweet, reply, confirm, pay, buy, order,
    //     delete, archive;
    //   • ComposioCatalog.sendBlocklist's DESTRUCTIVE/OUTWARD subset — the tokens
    //     whose effect leaves the user's own account or can't be undone: REMOVE,
    //     DESTROY, TRASH, PURGE, FORWARD, SHARE, ACCEPT, DECLINE, CANCEL,
    //     APPROVE, REJECT, MERGE, TRANSFER, REVOKE, INVITE.
    // Deliberately NOT here (this is auto-reversible policy, not draft-only
    // read-gating, so account-local mutations the user can undo run free):
    //   • CREATE — a created draft/event is inert or deletable (the same
    //     rationale as ComposioCatalog rule 1 and metaDraftAllowlist);
    //   • UPDATE/EDIT/SET/MARK/… — reversible account-local mutations;
    //   • MOVE — an email/event move is reversible; FILE moves are caught by the
    //     dedicated file-move policy lane above, never by this token set.

    private static let sendVerbList: [String] = [
        // extension SEND_RE / ComputerUseEngine.sendVerbRegex, verbatim
        "SEND", "SUBMIT", "POST", "PUBLISH", "TWEET", "REPLY", "CONFIRM",
        "PAY", "BUY", "ORDER", "DELETE", "ARCHIVE"
    ]

    private static let destructiveAPITokens: [String] = [
        // ComposioCatalog.sendBlocklist subset: destructive or outward-facing
        "REMOVE", "DESTROY", "TRASH", "PURGE", "FORWARD", "SHARE",
        "ACCEPT", "DECLINE", "CANCEL", "APPROVE", "REJECT", "MERGE",
        "TRANSFER", "REVOKE", "INVITE"
    ]

    private static let irreversibleAPITokens: Set<String> =
        Set(sendVerbList).union(destructiveAPITokens)

    /// Whole-token check of an action name against the irreversible verb set.
    /// Tokenization splits on non-alphanumerics AND camelCase boundaries so
    /// "GMAIL_SEND_EMAIL", "gmail.send" and "sendMessage" all yield SEND, while
    /// "PLAYLIST" can never match "LIST"-style substrings (same whole-token
    /// principle as ComposioCatalog.tokenSet).
    private static func apiActionIsIrreversible(_ action: String) -> Bool {
        !actionTokens(action).isDisjoint(with: irreversibleAPITokens)
    }

    /// Splits an action name into uppercase whole tokens: non-alphanumeric
    /// separators and lower→upper camel boundaries both break tokens.
    private static func actionTokens(_ name: String) -> Set<String> {
        var spaced = ""
        var previous: Character?
        for character in name {
            if let p = previous, character.isUppercase, (p.isLowercase || p.isNumber) {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }
        return Set(
            spaced.uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    // MARK: - File-move policy
    //
    // Locked decision: moving the USER'S FILES is significant → confirm by
    // default (with undo), never silent. Two shapes of file move exist:
    //   1. structured — an API/shell step whose action names a move/rename/trash
    //      of file-ish things ("move_file", "renameItem", input with paths);
    //   2. pixel — a left_click_drag while Finder is frontmost (the canonical
    //      "no API for this" Finder example; ComputerUseEngine's classifier has
    //      no drag rule, so this lane must catch it here).

    private static let fileBackends: Set<String> = [
        "file", "files", "fs", "finder", "filesystem", "nsworkspace", "shell", "app"
    ]

    private static let fileMoveVerbs: Set<String> = ["MOVE", "RENAME", "TRASH"]
    private static let fileNouns: Set<String> = [
        "FILE", "FILES", "FOLDER", "FOLDERS", "DIRECTORY", "ITEM", "ITEMS", "PATH"
    ]

    /// True when the step relocates/renames the user's files, by either shape.
    static func isFileMoveStep(_ step: PlannedStep) -> Bool {
        // Shape 2: pixel drag in Finder. ScreenEngine.latestActiveApp is the same
        // frontmost-app source ComputerUseEngine's AX classifier uses.
        if isComputerBackend(step.backend) || computerPrimitives.contains(step.action) {
            if step.action == "left_click_drag",
               ScreenEngine.shared.latestActiveApp.lowercased().contains("finder") {
                return true
            }
            return false
        }
        // Shape 1: structured move. A move verb in the action name plus either a
        // file-ish backend, a file noun in the name, or a filesystem path among
        // the inputs ("/Users/…", "~/…").
        let tokens = actionTokens(step.action)
        guard !tokens.isDisjoint(with: fileMoveVerbs) else { return false }
        if fileBackends.contains(step.backend.lowercased()) { return true }
        if !tokens.isDisjoint(with: fileNouns) { return true }
        return inputContainsFilesystemPath(step.input)
    }

    /// Any string value in the input that looks like a filesystem path.
    private static func inputContainsFilesystemPath(_ input: [String: Any]) -> Bool {
        for value in input.values {
            if let s = value as? String, s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("file://") {
                return true
            }
            if let array = value as? [String],
               array.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~/") || $0.hasPrefix("file://") }) {
                return true
            }
        }
        return false
    }

    /// The plan's EXPLICIT trivially-undoable marking for a file move. The generic
    /// `reversible: true` flag is deliberately NOT enough — every planner claims
    /// that; bypassing the file-move confirm requires the plan to spell out
    /// `input["trivially_undoable"] = true` (i.e. it prepared a real undo, e.g. it
    /// recorded the source path to move back). Combined with `reversible` so a
    /// contradictory step (irreversible but "trivially undoable") still confirms.
    private static func isTriviallyUndoable(_ step: PlannedStep) -> Bool {
        guard step.reversible else { return false }
        if let flag = step.input["trivially_undoable"] as? Bool { return flag }
        if let flag = step.input["trivially_undoable"] as? NSNumber { return flag.boolValue }
        return false
    }

    // MARK: - Recipient grounding
    //
    // The same invariant HolmesBrain enforces for GMAIL_CREATE_EMAIL_DRAFT
    // (ComposioCatalog.validateDraftRecipients): a send-class step may only be
    // addressed to people who APPEARED in data fetched earlier in this run — a
    // prompt-injected "send this to attacker@evil.com" dies here because that
    // address grounds in nothing the tools returned.

    /// Recipient grounding for send-class steps: false when any to/cc/bcc address
    /// in the step's input was NOT present in `knownAddresses` (the addresses
    /// harvested from this run's fetched tool results). Steps with no recipient
    /// fields are trivially grounded — there is nothing to check (a computer-lane
    /// send has no address argument; its safety comes from the confirm card).
    static func recipientGrounded(_ step: PlannedStep, knownAddresses: Set<String>) -> Bool {
        // Reuse ComposioCatalog's extraction wholesale: recipientAddresses reads
        // the to/cc/bcc/recipient_email… keys (case-insensitive) via
        // innerArguments, which unwraps an "arguments" envelope — so wrapping the
        // step input in one reproduces the exact meta-execute item shape.
        let recipients = ComposioCatalog.recipientAddresses(of: ["arguments": step.input])
        guard !recipients.isEmpty else { return true }
        // ComposioCatalog lowercases every extracted address; normalize the known
        // set the same way so a caller passing mixed-case fetched text can't
        // accidentally fail a legitimate recipient.
        let known = Set(knownAddresses.map { $0.lowercased() })
        return recipients.subtracting(known).isEmpty
    }
}
