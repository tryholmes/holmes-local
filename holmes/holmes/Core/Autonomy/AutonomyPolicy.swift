import Foundation
import Observation

// MARK: - AutonomyLevel
// The per-playbook autonomy dial. Conceptually replaces the old boolean
// enabled/disabled toggle: `.observe` is the old "off", everything above it is
// "on" at an increasing degree of independence.
//
//   observe — playbook never fires; Holmes only watches (the old toggle-off)
//   draft   — playbook may run read-only tools and produce a draft card the
//             user stages/copies themselves (the historical draft-never-send
//             posture; also the ceiling any unknown playbook starts at)
//   confirm — Holmes performs the work itself, but pauses for ONE confirmation
//             before anything irreversible/outward (send/delete/buy/post/⌘S-
//             class, per ComputerUseEngine.isIrreversible + ComposioCatalog)
//   auto    — reversible work happens with no prompt at all; the irreversible-
//             confirm gate above still applies on top, always
//
// Raw values are the persisted representation (UserDefaults strings) — renaming
// a case silently resets every user's stored preference for it, so don't.

enum AutonomyLevel: String, CaseIterable, Codable, Sendable {
    case observe
    case draft
    case confirm
    case auto

    /// Label for the Settings ▸ Automations level picker.
    var displayName: String {
        switch self {
        case .observe: return "Observe"
        case .draft:   return "Draft"
        case .confirm: return "Confirm"
        case .auto:    return "Auto"
        }
    }

    /// One-line explanation under the picker, so the choice is legible without
    /// reading docs. Kept here (not in the view) so every surface that renders
    /// a level says the same thing.
    var blurb: String {
        switch self {
        case .observe: return "Watch only — this playbook never runs."
        case .draft:   return "Prepare drafts for you to review. Never acts."
        case .confirm: return "Does the work, but asks before anything is sent or deleted."
        case .auto:    return "Acts on its own. Still pauses once for irreversible actions."
        }
    }
}

// Ordering: more autonomous compares greater (observe < draft < confirm < auto).
// This lets policy code clamp instead of branching — e.g. the routing seam
// applies the global master switch as `min(configured, .draft)`, and a future
// per-action gate can demand "at most .confirm" the same way. Declaration
// order in `allCases` IS the ordering, which is why the cases above are listed
// least-autonomous first.
extension AutonomyLevel: Comparable {
    static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
        // Both indices always exist: allCases contains every case by definition.
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}

// MARK: - AutonomyPolicy
// Single source of truth for HOW independently Holmes may act, split into two
// controls the user meets in Settings:
//
//   1. `masterEnabled` — the global "Autonomous actions" switch. DEFAULT OFF:
//      until the user flips it, every playbook behaves at most like the old
//      draft-only Holmes regardless of its per-playbook level (see
//      `effectiveLevel(for:)`), so shipping this file changes nothing by itself.
//   2. `level(for:)` — the per-playbook Observe/Draft/Confirm/Auto dial.
//
// The load-bearing invariant this replaces the draft-never-send rule with:
// irreversible/outward actions ALWAYS require one confirmation unless the user
// explicitly set that playbook to a level that allows them — and even `.auto`
// only auto-runs reversible work (ComputerUseEngine.isIrreversible re-confirms
// send/delete/⌘S-class actions independently of anything stored here).
//
// Persistence lives in UserDefaults under `com.grain.holmes.autonomy.*`. The
// old boolean toggle keys (`holmes.playbook.<id>.enabled`) are read once as a
// migration input and mirrored on every write, so PlaybookEngine.isEnabled and
// any not-yet-migrated reader of the legacy key stay agreed with the new dial.

@MainActor
@Observable
final class AutonomyPolicy {
    static let shared = AutonomyPolicy()

    // MARK: - Defaults keys

    /// Namespace for everything this type persists.
    private static let keyPrefix = "com.grain.holmes.autonomy."
    private static let masterKey = keyPrefix + "masterEnabled"

    private static func levelKey(_ playbookId: String) -> String {
        keyPrefix + playbookId
    }

    /// The key the OLD boolean per-playbook toggle wrote (see
    /// PlaybookEngine.isEnabled/setEnabled). Read for migration, written as a
    /// mirror so both models can never disagree while callers migrate.
    private static func legacyEnabledKey(_ playbookId: String) -> String {
        "holmes.playbook." + playbookId + ".enabled"
    }

    // MARK: - Master switch

    /// The global "Autonomous actions" switch (Settings ▸ Automations).
    /// DEFAULT false — `UserDefaults.bool(forKey:)` returns false for an unset
    /// key, so a fresh install can never act autonomously (same defensive
    /// pattern as ComputerUseEngine's master gate). didSet write-through keeps
    /// the stored value current; @Observable makes the toggle live in SwiftUI.
    var masterEnabled: Bool {
        didSet { UserDefaults.standard.set(masterEnabled, forKey: Self.masterKey) }
    }

    /// Convenience the action seams read: "is Holmes allowed to act at all?"
    var actsAutonomously: Bool { masterEnabled }

    // MARK: - Per-playbook levels

    /// In-memory mirror of the persisted levels. It is the @Observable surface:
    /// `setLevel` writes here first, so a Settings picker bound through
    /// `level(for:)`/`setLevel` re-renders on change. Only ever holds values
    /// the user explicitly set this session or that were persisted before —
    /// computed defaults are deliberately NOT cached here (caching them would
    /// mutate observable state during a SwiftUI render pass).
    private(set) var levels: [String: AutonomyLevel] = [:]

    private init() {
        masterEnabled = UserDefaults.standard.bool(forKey: Self.masterKey)
    }

    /// The user's configured level for a playbook. Resolution order:
    ///   1. a value set this session (observable dictionary)
    ///   2. a persisted `com.grain.holmes.autonomy.<id>` value
    ///   3. migration from the legacy boolean toggle: explicit false → .observe,
    ///      explicit true → the playbook's default active level
    ///   4. shipped defaults — blind/scheduled playbooks stay .observe (they
    ///      were default-OFF for safety and a data model change must not
    ///      silently turn them on); everything else gets its class default.
    ///
    /// NOTE: this is the CONFIGURED level. Anything that executes actions must
    /// go through `effectiveLevel(for:)`, which applies the master switch.
    func level(for playbookId: String) -> AutonomyLevel {
        if let set = levels[playbookId] { return set }
        if let raw = UserDefaults.standard.string(forKey: Self.levelKey(playbookId)),
           let stored = AutonomyLevel(rawValue: raw) {
            return stored
        }
        return Self.migratedOrDefaultLevel(playbookId)
    }

    /// Persists a level and mirrors the legacy boolean (`enabled` ⇔ level !=
    /// .observe) so PlaybookEngine.isEnabled — and any straggler reading the
    /// old key directly — agrees with the dial without waiting for callers to
    /// migrate.
    func setLevel(_ level: AutonomyLevel, for playbookId: String) {
        if playbookId == "email-compose", level == .observe {
            EmailDraftCoordinator.shared.cancelAutomaticDraft()
        }
        levels[playbookId] = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey(playbookId))
        UserDefaults.standard.set(level != .observe, forKey: Self.legacyEnabledKey(playbookId))
    }

    // MARK: - Effective level (what execution seams must consult)

    /// The level the routing seam is allowed to ACT on. The global master
    /// switch clamps every playbook to at most `.draft` while off — which is
    /// exactly the historical draft-never-send Holmes — without destroying the
    /// user's stored per-playbook choices. `.observe` stays `.observe` (min of
    /// the ordering), so a disabled playbook can never be resurrected by the
    /// master switch either way.
    func effectiveLevel(for playbookId: String) -> AutonomyLevel {
        let configured = level(for: playbookId)
        return masterEnabled ? configured : min(configured, .draft)
    }

    /// Back-compat shim: the old boolean model collapses to "level is not
    /// observe". PlaybookEngine.isEnabled delegates here (one line), keeping
    /// every existing fire-time gate — TriggerBrain, Autopilot, evaluate() —
    /// working unmodified. Deliberately reads the CONFIGURED level, not the
    /// effective one: with the master switch off an enabled playbook still
    /// fires in draft mode, matching today's behavior exactly.
    func isEnabled(_ playbookId: String) -> Bool {
        level(for: playbookId) != .observe
    }

    // MARK: - Shipped defaults

    /// Sending/outward playbooks: their whole point is a message that leaves
    /// the machine, so autonomy pauses for one confirm before the send even
    /// when the user opts them in. (Draft-mode behavior below .confirm is
    /// unchanged from today.)
    private static let confirmByDefault: Set<String> = [
        // Chat Reply drafts a message that would leave the machine if staged —
        // one confirm before anything is typed into the app.
        "chat-reply",
        // Downloads Sorter moves the user's files — significant, so it pauses
        // for one confirm (the runner still offers undo) even when opted in.
        "finder-downloads-sort",
    ]

    /// Read/prep playbooks: everything they produce stays on-device (briefs,
    /// prep sheets, research, radar summaries), so reversible auto-execution
    /// is safe once the master switch is on.
    private static let autoByDefault: Set<String> = [
        // Read-only brief — everything it produces stays on-device.
        "github-brief",
        // TEACH — explains + draws on screen, never mutates.
        "terminal-command-failed",
        // Reversible ACTION — joining a meeting is undoable (the user can leave).
        "meeting-join",
    ]

    /// The level a playbook lands at when the user turns it ON without picking
    /// a level (legacy toggle migration, or a future "enable" affordance).
    /// Unknown ids — user-defined playbooks that ship later — default to
    /// `.draft`: the safest ACTIVE level, per the spec's "unset → draft".
    static func defaultActiveLevel(for playbookId: String) -> AutonomyLevel {
        if confirmByDefault.contains(playbookId) { return .confirm }
        if autoByDefault.contains(playbookId) { return .auto }
        return .draft
    }

    /// Resolution steps 3–4 of `level(for:)` — everything below the new-key
    /// lookup. Split out so the precedence reads top-to-bottom above.
    private static func migratedOrDefaultLevel(_ playbookId: String) -> AutonomyLevel {
        // The legacy toggle stored an explicit choice — honor it. False maps to
        // .observe (off is off); true maps to the playbook's class default, the
        // closest new-model equivalent of "on".
        if let legacy = UserDefaults.standard.object(forKey: legacyEnabledKey(playbookId)) as? Bool {
            return legacy ? defaultActiveLevel(for: playbookId) : .observe
        }
        // Nothing stored anywhere. The blind/scheduled playbooks were shipped
        // default-OFF because they run with no screen context (see the comment
        // on PlaybookEngine.defaultDisabledPlaybooks) — that safety default
        // survives the model change verbatim as .observe.
        if PlaybookEngine.defaultDisabledPlaybooks.contains(playbookId) { return .observe }
        return defaultActiveLevel(for: playbookId)
    }
}
