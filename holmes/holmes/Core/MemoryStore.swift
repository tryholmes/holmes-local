import Foundation
import SQLite3

// MARK: - MemoryStore
// Persistent, personalized learning memory backed by SQLite (built into macOS —
// no package dependency) at ~/Library/Application Support/Holmes/memory.db.
//
// Every important thing Holmes observes or does is recorded here as an event:
//   • "context"  — a deep screen-context snapshot (EXACTLY what the user was
//                  working on: the math problem, the code file/error, the email)
//   • "draft"    — a playbook produced a draft for review
//   • "playbook" — a playbook ran quietly (all-clear) or failed
//   • "action"   — a user-initiated /run agent goal completed
//
// The agent reads this memory back two ways: the read-only `recall_memory`
// tool (full-text search over summaries/details via FTS5), and a compact
// digest injected into the system prompt so every run knows what the user has
// been working on recently. An actor so SQLite access is serialized without
// blocking the main thread.
//
// Every row also carries the PROVENANCE of what it saw — source, confidence,
// url, site, entities — because a memory is only as assertable as the reading
// that produced it. OCR-derived context is never written here at all (see
// recordLiveContext); everything in this DB was read from a DOM or an
// Accessibility tree, so recall can be trusted rather than hedged twice.
// MemoryFeed mirrors this actor for SwiftUI, which cannot await it in a body.

struct MemoryEvent: Identifiable, Hashable {
    let id: Int64
    let date: Date
    let kind: String
    let app: String
    let windowTitle: String
    let activity: String
    let summary: String
    let detail: String

    // Provenance — populated for rows written from a LiveContext. Rows written
    // through the plain record()/recordContext() paths, and every row that
    // predates the provenance migration, carry "" here. The dashboard shows a
    // row as unattributed rather than guessing when these are empty.
    let source: String          // ContextSource.rawValue
    let confidence: String      // ContextConfidence.rawValue — "" or "exact"/"structural"
    let url: String
    let site: String            // normalized host, e.g. "x.com"
    let entitiesJSON: String

    // The provenance fields are defaulted so every existing call site that
    // builds a MemoryEvent keeps compiling unchanged.
    init(id: Int64, date: Date, kind: String, app: String, windowTitle: String,
         activity: String, summary: String, detail: String,
         source: String = "", confidence: String = "", url: String = "",
         site: String = "", entitiesJSON: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.app = app
        self.windowTitle = windowTitle
        self.activity = activity
        self.summary = summary
        self.detail = detail
        self.source = source
        self.confidence = confidence
        self.url = url
        self.site = site
        self.entitiesJSON = entitiesJSON
    }

    /// Decoded `entities_json`. Empty when the row predates provenance or the
    /// context carried no entities — never nil, so callers can't branch wrong.
    var entities: [String: String] {
        guard !entitiesJSON.isEmpty,
              let data = entitiesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    /// True only for rows captured from the browser DOM or a structured AX
    /// field. Gate any factual restatement of a remembered row on this — a
    /// `.structural` row is reliable but coarse and must be hedged.
    var isTrustworthy: Bool { confidence == ContextConfidence.exact.rawValue }
}

actor MemoryStore {
    static let shared = MemoryStore()

    private var db: OpaquePointer?
    private var opened = false

    // Context dedupe: the 3s perception loop re-observes the same screen many
    // times, and the two context sources (browser bridge / OCR) can alternate
    // fingerprints for one physical screen — so dedupe against EVERY
    // fingerprint seen in the window, not just the immediately previous one.
    private var recentContextFingerprints: [String: Date] = [:]
    private static let contextDedupeWindow: TimeInterval = 600

    // sqlite3_bind_text needs TRANSIENT so Swift string buffers are copied.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {}

    // MARK: - Open / schema

    private func openIfNeeded() -> Bool {
        if opened { return db != nil }
        opened = true

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holmes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.db").path

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            print("[Holmes] MemoryStore: failed to open \(path)")
            sqlite3_close(db)
            db = nil
            return false
        }

        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            app TEXT NOT NULL DEFAULT '',
            window_title TEXT NOT NULL DEFAULT '',
            activity TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            confidence TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            site TEXT NOT NULL DEFAULT '',
            entities_json TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind, ts DESC);
        \(Self.ftsSchema)
        """
        guard exec(schema) else {
            print("[Holmes] MemoryStore: schema setup failed — memory disabled")
            sqlite3_close(db)
            db = nil
            return false
        }
        migrate()
        prune()

        // This DB quotes TCC-gated screen content: keep it user-only on disk
        // (WAL sidecars included — prune() above forced their creation) and
        // out of backups.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: path + suffix)
        }
        var dbURL = dir.appendingPathComponent("memory.db")
        var backupExclusion = URLResourceValues()
        backupExclusion.isExcludedFromBackup = true
        try? dbURL.setResourceValues(backupExclusion)

        print("[Holmes] MemoryStore ready — \(path)")
        return true
    }

    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            if let err { print("[Holmes] MemoryStore SQL error: \(String(cString: err))"); sqlite3_free(err) }
            return false
        }
        return true
    }

    // MARK: - Migration

    /// The FTS5 index and the triggers that keep it in sync, defined once so
    /// the fresh-install path and the rebuild path can never drift apart.
    /// `site` is indexed alongside the text so "what did I read on x.com" is a
    /// single MATCH rather than a table scan.
    private static let ftsSchema = """
    CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        summary, detail, app, activity, site, content='events', content_rowid='id'
    );
    CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts(rowid, summary, detail, app, activity, site)
        VALUES (new.id, new.summary, new.detail, new.app, new.activity, new.site);
    END;
    CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, summary, detail, app, activity, site)
        VALUES ('delete', old.id, old.summary, old.detail, old.app, old.activity, old.site);
    END;
    """

    /// Provenance columns added after v1 shipped, with their ADD COLUMN bodies.
    private static let provenanceColumns: [(name: String, ddl: String)] = [
        ("source",        "source TEXT NOT NULL DEFAULT ''"),
        ("confidence",    "confidence TEXT NOT NULL DEFAULT ''"),
        ("url",           "url TEXT NOT NULL DEFAULT ''"),
        ("site",          "site TEXT NOT NULL DEFAULT ''"),
        ("entities_json", "entities_json TEXT NOT NULL DEFAULT ''")
    ]

    /// Brings an already-existing DB up to the current schema.
    ///
    /// `CREATE TABLE IF NOT EXISTS` above is a no-op on every machine that has
    /// run Holmes before, so it can never add a column — the new columns have
    /// to be ALTERed in, guarded by PRAGMA table_info so this is idempotent and
    /// runs harmlessly on every open.
    private func migrate() {
        let existing = tableColumns("events")
        // Empty means the table isn't there at all (schema exec would already
        // have failed); nothing to migrate and nothing safe to guess at.
        guard !existing.isEmpty else { return }

        var addedColumn = false
        for column in Self.provenanceColumns where !existing.contains(column.name) {
            // Names/DDL are compile-time literals from this file — no value is
            // ever interpolated into SQL.
            if exec("ALTER TABLE events ADD COLUMN \(column.ddl)") { addedColumn = true }
        }
        _ = exec("CREATE INDEX IF NOT EXISTS idx_events_site ON events(site, ts DESC)")

        // fts5 has no ALTER: a pre-provenance DB carries a 4-column index whose
        // triggers no longer match the table's column set. Drop the index and
        // both triggers, recreate them from the single definition above, then
        // 'rebuild' repopulates the entire index from the content table.
        if addedColumn || !tableColumns("events_fts").contains("site") {
            let rebuilt = exec("""
            DROP TRIGGER IF EXISTS events_ai;
            DROP TRIGGER IF EXISTS events_ad;
            DROP TABLE IF EXISTS events_fts;
            \(Self.ftsSchema)
            INSERT INTO events_fts(events_fts) VALUES('rebuild');
            """)
            print("[Holmes] MemoryStore: migrated to provenance schema — FTS rebuild \(rebuilt ? "ok" : "FAILED")")
        }
    }

    /// Column names of `table` via PRAGMA table_info. Works for the fts5
    /// virtual table too, which is how the index's column set is checked.
    private func tableColumns(_ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    /// Every read path selects this column set, in this order, so `rows()` has
    /// exactly one mapping to keep in sync. `prefix` qualifies the names for
    /// the JOIN queries ("e.").
    private static func columnList(_ prefix: String = "") -> String {
        ["id", "ts", "kind", "app", "window_title", "activity", "summary", "detail",
         "source", "confidence", "url", "site", "entities_json"]
            .map { prefix + $0 }
            .joined(separator: ", ")
    }

    /// Canonical host for the `site` column: lowercased, scheme/userinfo/port/
    /// path stripped, no leading "www.". Accepts either a bare host or a full
    /// URL. One spelling per site is what makes the findSimilar site boost and
    /// the dashboard's per-site grouping actually match.
    static func normalizedSite(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return String(s.prefix(120))
    }

    // MARK: - Record

    /// Records one event. Never throws — memory must never break the pipeline.
    /// The provenance arguments are all defaulted, so the pre-existing call
    /// sites (playbooks, actions, drafts) are unchanged and simply record "".
    func record(kind: String, app: String = "", windowTitle: String = "",
                activity: String = "", summary: String, detail: String = "",
                source: String = "", confidence: String = "", url: String = "",
                site: String = "", entitiesJSON: String = "") {
        guard openIfNeeded(), !summary.isEmpty else { return }
        // prune() otherwise runs only at open; an always-on agent up for weeks
        // would exceed the documented 45-day / 20k-row bound until relaunch.
        insertsSincePrune += 1
        if insertsSincePrune >= 500 { insertsSincePrune = 0; prune() }
        let sql = """
        INSERT INTO events(ts, kind, app, window_title, activity, summary, detail,
                           source, confidence, url, site, entities_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, String(app.prefix(80)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 4, String(windowTitle.prefix(200)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 5, String(activity.prefix(40)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 6, String(summary.prefix(300)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 7, String(detail.prefix(2000)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 8, String(source.prefix(40)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 9, String(confidence.prefix(20)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 10, String(url.prefix(500)), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 11, Self.normalizedSite(site), -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 12, String(entitiesJSON.prefix(2000)), -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("[Holmes] MemoryStore: insert failed — \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        // Nudge the SwiftUI mirror. markDirty() only flips a flag and schedules
        // a coalesced drain, so a busy writer costs one main-actor hop per row,
        // not one query per row.
        Task { @MainActor in MemoryFeed.shared.markDirty() }
    }

    /// Records a deep screen-context snapshot, deduping the 3s loop's
    /// re-observations: a row is written only when the substance (app +
    /// activity + summary) wasn't already recorded within the dedupe window —
    /// so a long work session leaves a ~10-minute trail rather than either a
    /// single row or a row per tick.
    func recordContext(activity: String, summary: String, details: String,
                       app: String, windowTitle: String) {
        let fingerprint = (app + "|" + activity + "|" + summary)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        let now = Date()
        recentContextFingerprints = recentContextFingerprints.filter {
            now.timeIntervalSince($0.value) < Self.contextDedupeWindow
        }
        guard recentContextFingerprints[fingerprint] == nil else { return }
        recentContextFingerprints[fingerprint] = now
        record(kind: "context", app: app, windowTitle: windowTitle,
               activity: activity, summary: summary, detail: details)
    }

    /// Records a LiveContext snapshot as a `context` row, carrying its
    /// provenance (source / confidence / url / site / entities) so anything
    /// that reads it back later knows how much it is allowed to assert.
    ///
    /// TRUST GATE: only `.exact` (browser DOM or a structured AX field) and
    /// `.structural` (the macOS Accessibility tree) contexts are persisted. An
    /// `.inferred` context is OCR of pixels and may be garbled — writing a
    /// guess into memory poisons every later recall, which reads rows back as
    /// fact. Those are dropped on the floor, silently and deliberately.
    func recordLiveContext(_ ctx: LiveContext) {
        guard ctx.confidence == .exact || ctx.confidence == .structural else { return }
        guard !ctx.headline.isEmpty else { return }

        // NOISE GATE: low-value screen churn is still shown as the live headline
        // (applyLiveContext) but must not enter memory — memory is for things
        // worth RECALLING, not a screen log. See isMemoryNoise.
        guard !Self.isMemoryNoise(ctx) else { return }

        // Same 10-minute dedupe as recordContext — the perception loop
        // re-observes one physical screen many times a minute — but keyed on
        // LiveContext's own stable fingerprint. The "live|" namespace keeps the
        // two pipelines from ever suppressing each other's writes by accident.
        let key = "live|" + ctx.fingerprint
        let now = Date()
        recentContextFingerprints = recentContextFingerprints.filter {
            now.timeIntervalSince($0.value) < Self.contextDedupeWindow
        }
        guard recentContextFingerprints[key] == nil else { return }
        recentContextFingerprints[key] = now

        // Prefer the explicit host; fall back to parsing the URL so a browser
        // context is never filed without a site to group and boost on.
        let site = Self.normalizedSite(ctx.site ?? ctx.url ?? "")
        record(kind: "context",
               app: ctx.app,
               windowTitle: ctx.title,
               activity: ctx.activity,
               summary: ctx.headline,
               detail: ctx.detail,
               source: ctx.source.rawValue,
               confidence: ctx.confidence.rawValue,
               url: ctx.url ?? "",
               site: site,
               entitiesJSON: Self.encodeEntities(ctx.entities))
    }

    /// The deterministic NOISE FILTER: screen churn that must NOT enter memory.
    ///
    /// Memory should hold things worth RECALLING later — a document, a thread, a
    /// repo, an email — not a running log of every window. These four categories
    /// were drowning the real rows. Each still shows as the live headline; this
    /// only gates the DB write. Kept small, literal and model-free on purpose:
    /// nothing fuzzy that could silently start dropping real work (emails, repos,
    /// docs, chats all produce "specific" headlines and sail straight through).
    static func isMemoryNoise(_ ctx: LiveContext) -> Bool {
        let app = ctx.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = ctx.title.lowercased()
        let summary = ctx.headline.lowercased()
        let surface = ctx.entities["surface"] ?? ""

        // 1 — A FALLBACK headline is an admission Holmes could not read the
        //     screen: "On github.com — the Holmes extension sent no readable
        //     content…", "In Finder — Holmes can read the window but can't
        //     identify a task", "Can't read this page…". An admission is never
        //     worth recalling, and this one check also covers the pure-navigation
        //     churn ("On <host> — …" with no identifying entity), which is
        //     produced by exactly this fallback path.
        if ctx.entities["headlineKind"] == "fallback" { return true }

        // 2 — Screenshot / screen-recording activity: the capture UI, or any row
        //     whose window/summary names a screenshot file ("Working on
        //     'Screenshot 2026-07-22 at 5.48…'"). A capture artifact, not work.
        if app == "screenshot" || app == "screencapture" || app == "screen capture" { return true }
        for needle in ["screenshot", "screen recording"] {
            if title.hasPrefix(needle) || summary.contains("\"\(needle)") { return true }
        }

        // 3 — Meta / self: anything about Holmes itself (its own windows, or the
        //     extension talking about itself). Never a memory of the user's work.
        if app == "holmes" { return true }
        if summary.contains("holmes extension") { return true }

        // 4 — Idle media autoplay: a feed with a muted autoplaying video is not
        //     "watching". Drop a media row sitting within a few seconds of the
        //     start UNLESS it is a real video page (a YouTube/Vimeo watch page),
        //     where opening at 0:00 is a genuine "about to watch". Only a KNOWN
        //     small position counts — an unknown position (-1) is left alone.
        if let media = ctx.media, media.positionSeconds >= 0, media.positionSeconds < 3 {
            let host = (ctx.site ?? "").lowercased()
            let videoHosts = ["youtube.com", "youtu.be", "vimeo.com"]
            let realVideoPage = surface == ContextSurface.video.rawValue
                && (videoHosts.contains { host.contains($0) }
                    || (ctx.url ?? "").lowercased().contains("watch"))
            if !realVideoPage { return true }
        }

        return false
    }

    /// Entities as compact JSON. Keys are sorted so an unchanged entity set
    /// always serializes to the identical string — stable rows, stable diffs.
    private static func encodeEntities(_ entities: [String: String]) -> String {
        guard !entities.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entities),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return String(json.prefix(2000))
    }

    // MARK: - Read back

    /// Sanitizes free text into an FTS5 MATCH expression, or nil when nothing
    /// searchable survives. Raw user/model text is NOT valid FTS5 syntax —
    /// "what's" or a stray AND or a lone `*` throws a query error and loses the
    /// whole result set — so every term is reduced to alphanumeric tokens and
    /// each token is quoted, which makes operators inert. Every FTS caller in
    /// this file goes through here; there is deliberately only one place where
    /// a MATCH expression is built.
    private static func ftsMatch(for terms: [String], maxTokens: Int = 8) -> String? {
        var seen = Set<String>()
        var tokens: [String] = []
        for term in terms {
            for token in term.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            where token.count > 1 && !seen.contains(token) {
                seen.insert(token)
                tokens.append(token)
                if tokens.count == maxTokens { break }
            }
            if tokens.count == maxTokens { break }
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Full-text search over memory (FTS5). Empty/unparseable query → recent().
    func search(_ query: String, limit: Int = 8) -> [MemoryEvent] {
        guard openIfNeeded() else { return [] }
        guard let match = Self.ftsMatch(for: [query]) else { return recent(limit: limit) }

        let sql = """
        SELECT \(Self.columnList("e."))
        FROM events_fts f JOIN events e ON e.id = f.rowid
        WHERE events_fts MATCH ? AND e.kind <> 'draft' ORDER BY rank LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 50))))
        return rows(from: stmt)
    }

    /// Generic words that must never, on their own, make two tasks "related".
    private static let similarityStopwords: Set<String> = [
        "this", "that", "from", "your", "have", "into", "about", "what", "when",
        "where", "which", "would", "could", "should", "using", "with", "then",
        "them", "they", "there", "their", "here", "just", "some", "more", "make",
        "page", "user", "text", "code", "file", "line", "open", "view", "work"
    ]

    /// Finds past points of interest similar to the CURRENT task, for
    /// reactivation: when the user returns to a task they've done before, the
    /// prior rows that genuinely match are pulled back up. Precision matters —
    /// "related" must mean "the same specific work", not "the same category":
    ///   • match tokens come from the task's identifying TERMS only, never the
    ///     bare activity word (that would match every same-activity row);
    ///   • the activity is pinned with an exact column predicate instead;
    ///   • the current work SESSION's own identical-summary rows are excluded
    ///     (an echo of the present, not a recurrence) — but the same task from
    ///     a PAST session, older than `echoWindow`, is kept, since re-landing
    ///     on the exact task you did yesterday is the strongest reactivation
    ///     signal there is; the immediate present (rows newer than
    ///     `notWithinSeconds`) is always excluded;
    ///   • a candidate must share ≥2 identifying tokens, or one distinctive
    ///     (≥6-char) token, so a single common word in common isn't enough;
    ///   • when the current context has a `site`, rows from that same host also
    ///     qualify (even under a different activity) and are BOOSTED to the
    ///     front — returning to the same site is a far stronger "same work"
    ///     signal than a token match from somewhere unrelated. They still have
    ///     to clear the token filter, so the site only ever reorders and widens
    ///     the candidate pool; it never admits an unrelated row on its own.
    func findSimilar(activity: String, terms: String, site: String = "",
                     excludingSummary: String = "",
                     notWithinSeconds: Double = 120, echoWindow: Double = 3600,
                     limit: Int = 3) -> [MemoryEvent] {
        guard openIfNeeded() else { return [] }
        var seen = Set<String>()
        var tokens: [String] = []
        for tok in terms.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        where tok.count > 3 && !Self.similarityStopwords.contains(tok) && !seen.contains(tok) {
            seen.insert(tok)
            tokens.append(tok)
        }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")

        // Exclude the immediate present (ts < now-notWithinSeconds) and the
        // current session's own identical-summary echoes (same summary AND
        // newer than now-echoWindow) — but keep the SAME task from a prior
        // session (same summary, older than echoWindow) as a real recurrence.
        // The site predicate is written so an empty `site` makes the OR branch
        // unconditionally false — callers that don't pass one get byte-for-byte
        // the original query and the original results.
        let host = Self.normalizedSite(site)
        let sql = """
        SELECT \(Self.columnList("e."))
        FROM events_fts f JOIN events e ON e.id = f.rowid
        WHERE events_fts MATCH ? AND (e.activity = ? OR (? <> '' AND e.site = ?)) AND e.ts < ?
              AND NOT (e.summary = ? AND e.ts > ?) AND e.kind <> 'draft'
        ORDER BY rank LIMIT ?
        """
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, activity, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, host, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 4, host, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 5, now - notWithinSeconds)
        sqlite3_bind_text(stmt, 6, excludingSummary, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 7, now - echoWindow)
        sqlite3_bind_int(stmt, 8, Int32(max(1, min(limit * 4, 40))))
        let candidates = rows(from: stmt)

        // Precision filter: FTS OR-match can qualify a row on one generic token.
        // Require real overlap so "related" is trustworthy.
        let filtered = candidates.filter { e in
            let hay = (e.summary + " " + e.detail + " " + e.windowTitle).lowercased()
            let hits = tokens.filter { hay.contains($0) }
            return hits.count >= 2 || hits.contains { $0.count >= 6 }
        }
        guard !host.isEmpty else { return Array(filtered.prefix(limit)) }

        // Site boost: same-host rows move to the front, FTS rank order preserved
        // inside each group (the enumerated offset is the tiebreak, which keeps
        // the sort stable — Swift's sort is not).
        let boosted = filtered.enumerated().sorted { a, b in
            let aSame = a.element.site == host
            let bSame = b.element.site == host
            if aSame != bSame { return aSame }
            return a.offset < b.offset
        }.map(\.element)
        return Array(boosted.prefix(limit))
    }

    // MARK: - Topic recall ("what do I know about X")
    //
    // findSimilar above answers "what past work resembles what the user is doing
    // RIGHT NOW" — it keys off the current activity and the current site. This
    // answers a different question entirely: someone else named a SUBJECT, and
    // Holmes has to produce everything memory holds about that subject, with the
    // reason each row matched attached to it.
    //
    // Why the reason is not optional: the draft that gets built on these rows is
    // shown to the user next to them. If a row surfaced because a repo entity
    // literally reads "tryholmes/holmes", the user can see that and trust it; if
    // it surfaced because the word appeared once in some body text, the user can
    // see THAT and throw it out. A recall that can't show its work is a recall
    // the user has to take on faith, which is the thing this whole design exists
    // to avoid.

    /// One recalled memory, with its score and the human reason it matched.
    /// `matchedOn` is rendered verbatim in the UI, so it is written as a short
    /// noun phrase ("repo entity", "site github.com", "summary text"), with the
    /// size of the collapsed duplicate cluster appended when there was one.
    struct RecallHit {
        let event: MemoryEvent
        let score: Double
        let matchedOn: String
    }

    /// Most topics one recall will use. Each becomes an OR branch, so past a
    /// handful this stops being a query and starts being a table scan.
    private static let maxRecallTopics = 6

    /// Rows pulled back for scoring before ranking and collapsing. Bounded so a
    /// generic topic ("code") can't drag the whole table into memory.
    private static let recallCandidateCap = 200

    /// Half-life-ish window for the recency term: a row 14 days old is worth
    /// ~37% of the same row from today. Long enough that last week's work still
    /// answers a question about it, short enough that today's wins.
    private static let recallDecayDays = 14.0

    /// Two summaries this similar are the same memory said twice.
    private static let duplicateThreshold = 0.7

    /// Everything memory holds about the given subjects, best evidence first.
    ///
    /// Matching runs on three surfaces, because the same fact is filed three
    /// different ways depending on which reader saw it:
    ///   • the FTS5 index (summary/detail/app/activity/site) — the phrasing,
    ///   • the `site` column — "holmes" should reach rows read on holmes.dev,
    ///   • the `entities_json` column — a row whose summary never says "holmes"
    ///     still carries `repo=tryholmes/holmes`, and that is the STRONGEST
    ///     evidence of all because an entity was read from a structured field
    ///     rather than from prose.
    ///
    /// Ranking, in order: exact entity value > site > title/summary > body text,
    /// each decayed by age, then nudged by how many near-identical rows collapsed
    /// into it. Near-duplicates are collapsed so fourteen rows about one PR can't
    /// crowd out a different, relevant memory — the newest row of each cluster
    /// represents it and the cluster size rides along in `matchedOn`.
    ///
    /// Every value is bound; nothing is interpolated into SQL.
    func recall(topics: [String], limit: Int = 12) -> [RecallHit] {
        guard openIfNeeded() else { return [] }

        // Normalize, preserving the caller's order (the extractor already ranked
        // its topics by how strongly the message named them).
        var seenTerms = Set<String>()
        var terms: [String] = []
        for topic in topics {
            let term = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard term.count >= 2, !seenTerms.contains(term) else { continue }
            seenTerms.insert(term)
            terms.append(term)
            if terms.count == Self.maxRecallTopics { break }
        }
        guard !terms.isEmpty else { return [] }

        let candidates = candidateRows(for: terms, cap: Self.recallCandidateCap)
        guard !candidates.isEmpty else { return [] }

        // Score. A row matching several topics is stronger than one matching a
        // single topic, but only mildly — the strongest single reason dominates,
        // so "repo entity" never loses to two weak body-text hits.
        let now = Date().timeIntervalSince1970
        var scored: [(event: MemoryEvent, score: Double, label: String)] = []
        for event in candidates {
            var strongest: (base: Double, label: String)?
            var total = 0.0
            for term in terms {
                guard let match = Self.matchStrength(event: event, topic: term) else { continue }
                total += match.base
                if strongest == nil || match.base > strongest!.base { strongest = match }
            }
            // No literal evidence in the row itself: it only cleared the FTS OR
            // on one token of a multi-word topic. Dropped rather than shown with
            // a reason Holmes can't actually name.
            guard let strongest else { continue }
            let breadth = strongest.base + 0.25 * (total - strongest.base)
            let ageDays = max(0, now - event.date.timeIntervalSince1970) / 86_400
            let decay = exp(-ageDays / Self.recallDecayDays)
            scored.append((event, breadth * (0.45 + 0.55 * decay), strongest.label))
        }
        guard !scored.isEmpty else { return [] }

        // Strongest first; ties broken by recency, then by id so the order is
        // deterministic for identical input (Swift's sort is not stable).
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.event.date != b.event.date { return a.event.date > b.event.date }
            return a.event.id > b.event.id
        }

        // Collapse near-duplicate summaries. The cluster keeps the NEWEST row —
        // "Reviewing PR #482" from ten minutes ago is the one worth showing — but
        // the score of the strongest member, which is the head of the sorted list.
        var clusters: [(event: MemoryEvent, score: Double, label: String, tokens: Set<String>, count: Int)] = []
        for item in scored {
            let tokens = Self.clusterTokens(item.event.summary)
            if let index = clusters.firstIndex(where: { Self.jaccard($0.tokens, tokens) >= Self.duplicateThreshold }) {
                clusters[index].count += 1
                if item.event.date > clusters[index].event.date {
                    clusters[index].event = item.event
                    // The reason has to describe the row actually being shown, so
                    // it is recomputed for the new representative.
                    if let match = terms.compactMap({ Self.matchStrength(event: item.event, topic: $0) })
                        .max(by: { $0.base < $1.base }) {
                        clusters[index].label = match.label
                    }
                }
                continue
            }
            clusters.append((item.event, item.score, item.label, tokens, 1))
        }

        // Frequency last, and additively: repeatedly recorded work is more likely
        // to be what they're asking about, but a cluster of fourteen weak rows
        // must not outrank one exact entity match.
        let hits = clusters
            .map { cluster -> RecallHit in
                let frequencyBonus = 2.0 * log2(Double(cluster.count) + 1)
                let reason = cluster.count > 1
                    ? "\(cluster.label) · \(cluster.count) similar rows"
                    : cluster.label
                return RecallHit(event: cluster.event,
                                 score: cluster.score + frequencyBonus,
                                 matchedOn: reason)
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.event.date > b.event.date
            }
            .prefix(max(1, min(limit, 50)))

        print("[Holmes] MemoryStore.recall(\(terms.joined(separator: ", "))) — \(candidates.count) candidate(s) → \(hits.count) hit(s)")
        return Array(hits)
    }

    /// Row counts and span for one subject — the "Holmes has 14 rows on this,
    /// from Jul 12 to today" line. Uses the same three matching surfaces as
    /// `recall`, so the number always describes the same set of rows the user is
    /// looking at rather than a second, differently-defined population.
    func topicSummary(_ topic: String) -> (rowCount: Int, firstSeen: Date?, lastSeen: Date?, apps: [String]) {
        let empty: (rowCount: Int, firstSeen: Date?, lastSeen: Date?, apps: [String]) = (0, nil, nil, [])
        guard openIfNeeded() else { return empty }
        let term = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard term.count >= 2 else { return empty }

        let matched = candidateRows(for: [term], cap: 2000)
            .filter { Self.matchStrength(event: $0, topic: term) != nil }
        guard !matched.isEmpty else { return empty }

        // Counted in Swift rather than SQL: the literal-evidence filter above is
        // the same one recall applies, and a COUNT(*) that ignored it would
        // report more rows than Holmes is willing to stand behind.
        var appCounts: [String: Int] = [:]
        for row in matched where !row.app.isEmpty { appCounts[row.app, default: 0] += 1 }
        let apps = appCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4)
            .map(\.key)

        let dates = matched.map(\.date)
        return (matched.count, dates.min(), dates.max(), apps)
    }

    /// The candidate pull shared by `recall` and `topicSummary`: FTS over the
    /// indexed text, plus LIKE against the two columns FTS does not cover.
    /// Placeholders are generated from the term COUNT — every term itself is
    /// bound, never interpolated.
    private func candidateRows(for terms: [String], cap: Int) -> [MemoryEvent] {
        var predicates: [String] = []
        let match = Self.ftsMatch(for: terms, maxTokens: 12)
        if match != nil {
            predicates.append("e.id IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)")
        }
        // entities_json is not in the FTS index (it is JSON, and tokenizing it
        // would index the key names too), and `site` is indexed but only as a
        // whole token — so "holmes" would miss "tryholmes/holmes" sitting in an
        // entity value. Both get a substring LIKE with the wildcards escaped.
        var likePatterns: [String] = []
        for term in terms {
            let pattern = Self.likePattern(term)
            predicates.append("e.site LIKE ? ESCAPE '\\'")
            likePatterns.append(pattern)
            predicates.append("e.entities_json LIKE ? ESCAPE '\\'")
            likePatterns.append(pattern)
        }
        guard !predicates.isEmpty else { return [] }

        let sql = """
        SELECT \(Self.columnList("e."))
        FROM events e
        WHERE (\(predicates.joined(separator: " OR ")))
              AND e.kind <> 'draft' -- Holmes's own drafts are not evidence: recalling one as "memory" makes the next reply parrot it
        ORDER BY e.ts DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[Holmes] MemoryStore.recall: prepare failed — \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        if let match {
            sqlite3_bind_text(stmt, index, match, -1, Self.sqliteTransient)
            index += 1
        }
        for pattern in likePatterns {
            sqlite3_bind_text(stmt, index, pattern, -1, Self.sqliteTransient)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(max(1, min(cap, 5000))))
        return rows(from: stmt)
    }

    /// `%term%` with LIKE's own wildcards neutralized, for use with ESCAPE '\'.
    /// Without this a topic containing `%` or `_` would silently match rows it
    /// has nothing to do with.
    private static func likePattern(_ value: String) -> String {
        var escaped = ""
        for character in value.lowercased() {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    /// How strongly one row matches one topic, and the human reason why.
    /// The ladder is evidence quality, not string length: an entity value was
    /// read from a structured field, a site is a normalized fact, a summary is
    /// deterministic prose Holmes wrote itself, and body text is the weakest
    /// because a word can appear in it by coincidence.
    private static func matchStrength(event: MemoryEvent, topic: String) -> (base: Double, label: String)? {
        let needle = topic.lowercased()
        var best: (base: Double, label: String)?
        func consider(_ base: Double, _ label: String) {
            if best == nil || base > best!.base { best = (base, label) }
        }

        // 1 — an entity VALUE that IS the topic, whole or as a slug component:
        //     repo=tryholmes/holmes answers "holmes" exactly.
        for (key, rawValue) in event.entities.sorted(by: { $0.key < $1.key }) {
            let value = rawValue.lowercased()
            if value == needle || pieces(value).contains(needle) {
                consider(100, "\(key) entity")
            } else if needle.count >= 3, textContains(value, needle) {
                consider(72, "\(key) entity")
            }
        }

        // 2 — the site the row was read on.
        let site = event.site.lowercased()
        if !site.isEmpty {
            if site == needle || pieces(site).contains(needle) {
                consider(60, "site \(event.site)")
            } else if needle.count >= 3, textContains(site, needle) {
                consider(52, "site \(event.site)")
            }
        }

        // 3 — the deterministic headline Holmes stored, then the window title.
        if textContains(event.summary.lowercased(), needle) { consider(40, "summary text") }
        if textContains(event.windowTitle.lowercased(), needle) { consider(34, "window title") }

        // 4 — everything else the row happens to contain.
        if textContains(event.detail.lowercased(), needle) { consider(22, "body text") }
        if textContains(event.url.lowercased(), needle) { consider(20, "url") }
        if !event.app.isEmpty, textContains(event.app.lowercased(), needle) { consider(15, "app \(event.app)") }
        if !event.activity.isEmpty, textContains(event.activity.lowercased(), needle) {
            consider(15, "activity \(event.activity)")
        }
        return best
    }

    /// Substring match, extended so a multi-word topic ("holmes repo") matches a
    /// row that contains all of its words in any order.
    private static func textContains(_ haystack: String, _ needle: String) -> Bool {
        guard !haystack.isEmpty, !needle.isEmpty else { return false }
        if haystack.contains(needle) { return true }
        let words = needle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count > 1 else { return false }
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Alphanumeric components of a value — "tryholmes/holmes" → {tryholmes, holmes},
    /// "github.com" → {github, com}. What makes a slug or a host answer a bare topic.
    private static func pieces(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Identifying words of a summary, for duplicate detection. Reuses the same
    /// stopword list findSimilar uses, so "related" means one thing in this file.
    private static func clusterTokens(_ summary: String) -> Set<String> {
        Set(summary.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !similarityStopwords.contains($0) })
    }

    /// Token-set overlap in [0, 1]. Two empty summaries count as identical,
    /// which is the right answer for the degenerate case.
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(union)
    }

    /// Recalled rows formatted for prompt injection — one line each, carrying
    /// the match reason so the model can weigh a repo-entity hit differently
    /// from a passing mention in body text.
    static func formatRecall(_ hits: [RecallHit]) -> String {
        guard !hits.isEmpty else { return "(nothing on file)" }
        return hits.map { hit in
            let time = timeFormatter.string(from: hit.event.date)
            let app = hit.event.app.isEmpty ? "" : " (\(hit.event.app))"
            let detail = hit.event.detail.isEmpty ? "" : "\n  \(String(hit.event.detail.prefix(300)))"
            return "· [\(time)] \(hit.event.summary)\(app) — matched on: \(hit.matchedOn)\(detail)"
        }.joined(separator: "\n")
    }

    /// Most recent events, optionally filtered by kind.
    func recent(limit: Int = 10, kind: String? = nil) -> [MemoryEvent] {
        guard openIfNeeded() else { return [] }
        let sql = kind == nil
            ? "SELECT \(Self.columnList()) FROM events ORDER BY ts DESC LIMIT ?"
            : "SELECT \(Self.columnList()) FROM events WHERE kind = ? ORDER BY ts DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let kind {
            sqlite3_bind_text(stmt, 1, kind, -1, Self.sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 50))))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(max(1, min(limit, 50))))
        }
        return rows(from: stmt)
    }

    /// The recent LiveContext trail, newest first — what the memory dashboard
    /// renders. `context` rows only: playbook/action/draft rows are Holmes's
    /// own output, not a record of what the user was looking at.
    func recentContexts(limit: Int = 20) -> [MemoryEvent] {
        recent(limit: limit, kind: "context")
    }

    /// Row counts for the dashboard header. `today` is counted from local
    /// midnight, not a rolling 24h, so it matches what the user would count.
    func stats() -> (total: Int, today: Int, oldestDate: Date?) {
        guard openIfNeeded() else { return (0, 0, nil) }
        let sql = "SELECT COUNT(*), SUM(CASE WHEN ts >= ? THEN 1 ELSE 0 END), MIN(ts) FROM events"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, nil) }
        // SUM() and MIN() are NULL on an empty table; column_type tells that
        // apart from a legitimate zero, which sqlite3_column_* would flatten.
        let total = Int(sqlite3_column_int64(stmt, 0))
        let today = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 1))
        let oldest = sqlite3_column_type(stmt, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        return (total, today, oldest)
    }

    /// Compact recent-activity digest for prompt injection — newest first,
    /// one line per event, capped so it never bloats the system prompt.
    func digest(hours: Double = 12, maxItems: Int = 6) -> String {
        guard openIfNeeded() else { return "" }
        let sql = """
        SELECT \(Self.columnList())
        FROM events WHERE ts > ? ORDER BY ts DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - hours * 3600)
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(maxItems, 20))))
        let events = rows(from: stmt)
        guard !events.isEmpty else { return "" }
        return events.map { e in
            let time = Self.timeFormatter.string(from: e.date)
            let app = e.app.isEmpty ? "" : " (\(e.app))"
            return "· [\(time)] \(e.kind): \(e.summary)\(app)"
        }.joined(separator: "\n")
    }

    /// Compact one-line-per-event format for prompt injection (summary only,
    /// no quoted detail) — keeps the reactivated-memory section small and the
    /// screen-derived-content injection surface minimal.
    static func formatCompact(_ events: [MemoryEvent]) -> String {
        guard !events.isEmpty else { return "(none)" }
        return events.map { e in
            let time = timeFormatter.string(from: e.date)
            let app = e.app.isEmpty ? "" : " (\(e.app))"
            return "· [\(time)] \(e.summary)\(app)"
        }.joined(separator: "\n")
    }

    /// Formats events for the recall_memory tool result.
    static func format(_ events: [MemoryEvent]) -> String {
        guard !events.isEmpty else { return "(no matching memories)" }
        return events.map { e in
            let time = timeFormatter.string(from: e.date)
            let app = e.app.isEmpty ? "" : " — app: \(e.app)"
            let detail = e.detail.isEmpty ? "" : "\n  \(String(e.detail.prefix(400)))"
            return "[\(time)] (\(e.kind)\(e.activity.isEmpty ? "" : "/\(e.activity)")) \(e.summary)\(app)\(detail)"
        }.joined(separator: "\n")
    }

    // MARK: - Maintenance

    /// Keeps the DB bounded for an always-on agent: drop events older than 45
    /// days, and hard-cap total rows so a runaway logger can't grow unchecked.
    private var insertsSincePrune = 0

    private func prune() {
        _ = exec("DELETE FROM events WHERE ts < \(Date().timeIntervalSince1970 - 45 * 86400)")
        _ = exec("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY ts DESC LIMIT 20000)")
    }

    // MARK: - Row mapping

    private func rows(from stmt: OpaquePointer?) -> [MemoryEvent] {
        var result: [MemoryEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(MemoryEvent(
                id: sqlite3_column_int64(stmt, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                kind: string(stmt, 2),
                app: string(stmt, 3),
                windowTitle: string(stmt, 4),
                activity: string(stmt, 5),
                summary: string(stmt, 6),
                detail: string(stmt, 7),
                source: string(stmt, 8),
                confidence: string(stmt, 9),
                url: string(stmt, 10),
                site: string(stmt, 11),
                entitiesJSON: string(stmt, 12)
            ))
        }
        return result
    }

    private func string(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}
