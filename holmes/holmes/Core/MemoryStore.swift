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

struct MemoryEvent {
    let id: Int64
    let date: Date
    let kind: String
    let app: String
    let windowTitle: String
    let activity: String
    let summary: String
    let detail: String
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
            detail TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind, ts DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
            summary, detail, app, activity, content='events', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
            INSERT INTO events_fts(rowid, summary, detail, app, activity)
            VALUES (new.id, new.summary, new.detail, new.app, new.activity);
        END;
        CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
            INSERT INTO events_fts(events_fts, rowid, summary, detail, app, activity)
            VALUES ('delete', old.id, old.summary, old.detail, old.app, old.activity);
        END;
        """
        guard exec(schema) else {
            print("[Holmes] MemoryStore: schema setup failed — memory disabled")
            sqlite3_close(db)
            db = nil
            return false
        }
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

    // MARK: - Record

    /// Records one event. Never throws — memory must never break the pipeline.
    func record(kind: String, app: String = "", windowTitle: String = "",
                activity: String = "", summary: String, detail: String = "") {
        guard openIfNeeded(), !summary.isEmpty else { return }
        let sql = "INSERT INTO events(ts, kind, app, window_title, activity, summary, detail) VALUES (?,?,?,?,?,?,?)"
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
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[Holmes] MemoryStore: insert failed — \(String(cString: sqlite3_errmsg(db)))")
        }
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

    // MARK: - Read back

    /// Full-text search over memory (FTS5). Empty/unparseable query → recent().
    func search(_ query: String, limit: Int = 8) -> [MemoryEvent] {
        guard openIfNeeded() else { return [] }
        // Sanitize into quoted tokens — raw user/model text is not valid FTS5
        // syntax ("what's" or a stray AND would throw a query error).
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
            .prefix(8)
        guard !tokens.isEmpty else { return recent(limit: limit) }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")

        let sql = """
        SELECT e.id, e.ts, e.kind, e.app, e.window_title, e.activity, e.summary, e.detail
        FROM events_fts f JOIN events e ON e.id = f.rowid
        WHERE events_fts MATCH ? ORDER BY rank LIMIT ?
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
    ///     (≥6-char) token, so a single common word in common isn't enough.
    func findSimilar(activity: String, terms: String, excludingSummary: String = "",
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
        let sql = """
        SELECT e.id, e.ts, e.kind, e.app, e.window_title, e.activity, e.summary, e.detail
        FROM events_fts f JOIN events e ON e.id = f.rowid
        WHERE events_fts MATCH ? AND e.activity = ? AND e.ts < ?
              AND NOT (e.summary = ? AND e.ts > ?)
        ORDER BY rank LIMIT ?
        """
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, activity, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 3, now - notWithinSeconds)
        sqlite3_bind_text(stmt, 4, excludingSummary, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 5, now - echoWindow)
        sqlite3_bind_int(stmt, 6, Int32(max(1, min(limit * 4, 40))))
        let candidates = rows(from: stmt)

        // Precision filter: FTS OR-match can qualify a row on one generic token.
        // Require real overlap so "related" is trustworthy.
        let filtered = candidates.filter { e in
            let hay = (e.summary + " " + e.detail + " " + e.windowTitle).lowercased()
            let hits = tokens.filter { hay.contains($0) }
            return hits.count >= 2 || hits.contains { $0.count >= 6 }
        }
        return Array(filtered.prefix(limit))
    }

    /// Most recent events, optionally filtered by kind.
    func recent(limit: Int = 10, kind: String? = nil) -> [MemoryEvent] {
        guard openIfNeeded() else { return [] }
        let sql = kind == nil
            ? "SELECT id, ts, kind, app, window_title, activity, summary, detail FROM events ORDER BY ts DESC LIMIT ?"
            : "SELECT id, ts, kind, app, window_title, activity, summary, detail FROM events WHERE kind = ? ORDER BY ts DESC LIMIT ?"
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

    /// Compact recent-activity digest for prompt injection — newest first,
    /// one line per event, capped so it never bloats the system prompt.
    func digest(hours: Double = 12, maxItems: Int = 6) -> String {
        guard openIfNeeded() else { return "" }
        let sql = """
        SELECT id, ts, kind, app, window_title, activity, summary, detail
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
                detail: string(stmt, 7)
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
