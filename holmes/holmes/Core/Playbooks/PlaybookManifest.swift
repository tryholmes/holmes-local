import Foundation

// MARK: - PlaybookManifest
// The Holmes SDK's first surface: a DECLARATIVE playbook. A manifest is a JSON
// file the user (or a community author) drops into
//
//     ~/Library/Application Support/Holmes/playbooks/<id>.json
//
// and Holmes compiles into the same `Playbook` struct the five built-ins use.
// Nothing about the safety model changes for a manifest playbook:
//
//   • it runs on the draft-only path (HolmesBrain.runPlaybook) behind the same
//     ComposioCatalog tool filter as every built-in — a manifest cannot name a
//     tool, a backend, or a coordinate; it can only describe WHEN to fire and
//     WHAT to prepare,
//   • the draft-never-send safety sentence is appended to every goal by the
//     loader, not by the author, so it cannot be left out,
//   • it never sees pixels — matching runs on app identity, window title,
//     context type, and the extracted entities; screen-text needles are
//     available but are the least precise gate and should be a last resort,
//   • the `target` is limited to the clipboard or staging text into the app
//     through ActionExecutor (which never presses Return).
//
// Why JSON and not a code plugin: the whole draft-never-send guarantee is that
// the tool filter and AutonomyGate are code third parties cannot reach. A dylib
// could call ActionExecutor directly and the guarantee would be gone.
//
// Schema version 1. Unknown keys are ignored so older builds tolerate newer
// manifests; a manifest with `version` above what this build knows is skipped
// with a clear error instead of half-working.

struct PlaybookManifest: Decodable {
    static let supportedVersion = 1

    let version: Int
    let id: String
    let name: String
    let icon: String?
    let summary: String
    let kind: String?
    let autoTriggers: Bool?
    let cooldownSeconds: Double?
    let composioApps: [String]?
    let usesDing: Bool?
    let match: Match
    /// Cooldown key template. Same rendered key → same "situation" → one fire
    /// per cooldown window. Defaults to "{windowTitle}".
    let key: String?
    let goal: String
    let title: String?
    /// "clipboard" (default) or "typeIntoApp".
    let target: String?
    /// Optional draft-only persona. Wrapped by PlaybookEngine.communityPersona
    /// in a fixed safety preamble/epilogue; max 1500 chars.
    let persona: String?
    /// Names of servers in mcp.json whose READ-ONLY tools may be offered.
    let mcpServers: [String]?

    struct Match: Decodable {
        /// Any of these, case-insensitive substring of the active app's name.
        /// Required — a playbook with no app identity would fire everywhere.
        let apps: [String]
        /// Any of these, case-insensitive substring of ContextEngine's type.
        let contextTypes: [String]?
        /// A regular expression the window title must match (case-insensitive).
        let windowTitle: String?
        /// Any of these substrings in the window title vetoes the match.
        let windowTitleNot: [String]?
        /// Entity keys that must be present and non-empty
        /// (sender, subject, recipient, contact, promptText, repoOwner,
        /// repoName, platform, eventTitle, eventId).
        let requiredEntities: [String]?
        /// Any of these substrings in the screen text (case-insensitive). The
        /// least structural gate — use only when no title/entity signal exists.
        let screenTextAny: [String]?
        /// All of these substrings in the screen text.
        let screenTextAll: [String]?
    }

    // MARK: - Validation and compilation

    enum ManifestError: LocalizedError {
        case unsupportedVersion(Int)
        case badID(String)
        case reservedID(String)
        case badKind(String)
        case emptyApps
        case badRegex(String, String)
        case badTarget(String)
        case emptyGoal
        case cooldownTooShort(Double)
        case badServerName(String)
        case personaTooLong(Int)
        case reservedServerName(String)
        case emptyName

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "manifest version \(v) is newer than this build supports (\(PlaybookManifest.supportedVersion))"
            case .badID(let id):             return "id \"\(id)\" must be 3–48 chars of a–z, 0–9 and '-'"
            case .reservedID(let id):        return "id \"\(id)\" is already used by a built-in playbook"
            case .badKind(let k):            return "kind \"\(k)\" is not one of \(PlaybookManifest.allowedKinds.map(\.rawValue).sorted().joined(separator: ", "))"
            case .emptyApps:                 return "match.apps must name at least one app"
            case .badRegex(let r, let why):  return "match.windowTitle regex \"\(r)\" is invalid: \(why)"
            case .badTarget(let t):          return "target \"\(t)\" must be \"clipboard\" or \"typeIntoApp\""
            case .emptyGoal:                 return "goal must not be empty"
            case .cooldownTooShort(let s):   return "cooldownSeconds \(Int(s)) is below the 60 s minimum"
            case .badServerName(let n):      return "mcpServers entry \"\(n)\" must be 1–64 chars of a–z, 0–9, '_' and '-' (a server name from mcp.json)"
            case .personaTooLong(let n):     return "persona is \(n) chars; the limit is 1500"
            case .reservedServerName(let n): return "mcpServers may not name \"\(n)\" (use composioApps for Composio)"
            case .emptyName:                 return "name must not be empty"
            }
        }
    }

    /// Kinds a manifest may use. Each maps to a draft-only or read-only persona
    /// in PlaybookEngine.systemHint. The scheduled "blind" kinds (briefing,
    /// triage, followUp, prRadar, scheduleAlert, wrapup) are excluded: they
    /// were purged for firing without screen context.
    static let allowedKinds: Set<DraftKind> = [
        .chatReply, .repoBrief, .aiAnswer, .meetingPrep, .linkedInPost, .promptSuggestion
    ]
    // `.emailReply` is also excluded: PlaybookEngine unlocks the sanctioned
    // GMAIL_CREATE_EMAIL_DRAFT server-side write for that kind, and an SDK
    // manifest must never be able to stage anything outside the user's screen.

    static let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{2,47}$")

    /// Compiles the manifest into a `Playbook`. `reservedIDs` are the built-in
    /// ids a manifest may not shadow.
    static let serverNamePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")

    func compile(reservedIDs: Set<String>, source: String? = nil) throws -> Playbook {
        guard version <= Self.supportedVersion else { throw ManifestError.unsupportedVersion(version) }
        let idRange = NSRange(id.startIndex..., in: id)
        guard Self.idPattern.firstMatch(in: id, range: idRange) != nil else { throw ManifestError.badID(id) }
        guard !reservedIDs.contains(id) else { throw ManifestError.reservedID(id) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ManifestError.emptyName }

        let draftKind: DraftKind
        if let raw = kind {
            guard let k = DraftKind(rawValue: raw), Self.allowedKinds.contains(k) else { throw ManifestError.badKind(raw) }
            draftKind = k
        } else {
            draftKind = .aiAnswer
        }

        let apps = match.apps.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !apps.isEmpty else { throw ManifestError.emptyApps }
        let contextTypes = (match.contextTypes ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        let titleVetoes = (match.windowTitleNot ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        let requiredEntities = (match.requiredEntities ?? []).filter { !$0.isEmpty }
        let textAny = (match.screenTextAny ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        let textAll = (match.screenTextAll ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }

        var titleRegex: NSRegularExpression? = nil
        if let pattern = match.windowTitle, !pattern.isEmpty {
            do { titleRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
            catch { throw ManifestError.badRegex(pattern, "not a valid ICU regular expression") }
        }

        let goalTemplate = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalTemplate.isEmpty else { throw ManifestError.emptyGoal }

        let cooldown = cooldownSeconds ?? 600
        guard cooldown >= 60 else { throw ManifestError.cooldownTooShort(cooldown) }

        let targetName = (target ?? "clipboard").lowercased()
        guard targetName == "clipboard" || targetName == "typeintoapp" else { throw ManifestError.badTarget(target ?? "") }

        let servers = (mcpServers ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        for s in servers {
            let r = NSRange(s.startIndex..., in: s)
            guard Self.serverNamePattern.firstMatch(in: s, range: r) != nil else { throw ManifestError.badServerName(s) }
            if s == ComposioCatalog.composioServerName { throw ManifestError.reservedServerName(s) }
        }
        let personaText = (persona ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if personaText.count > 1500 { throw ManifestError.personaTooLong(personaText.count) }

        let keyTemplate = (key ?? "").isEmpty ? "{windowTitle}" : key!
        let titleTemplate = (title ?? "").isEmpty ? name : title!
        let composio = (composioApps ?? []).map { $0.uppercased() }.filter { !$0.isEmpty }

        var playbook = Playbook(
            id: id,
            name: name,
            icon: (icon ?? "").isEmpty ? "sparkles" : icon!,
            summary: summary,
            autoTriggers: autoTriggers ?? true,
            cooldownSeconds: cooldown,
            composioApps: composio,
            usesDing: usesDing ?? false,
            kind: draftKind,
            matches: { ctx in
                let app = ctx.appName.lowercased()
                guard apps.contains(where: { app.contains($0) }) else { return nil }
                if !contextTypes.isEmpty {
                    let type = ctx.contextType.lowercased()
                    guard contextTypes.contains(where: { type.contains($0) }) else { return nil }
                }
                let titleL = ctx.windowTitle.lowercased()
                if titleVetoes.contains(where: { titleL.contains($0) }) { return nil }
                if let re = titleRegex {
                    let r = NSRange(ctx.windowTitle.startIndex..., in: ctx.windowTitle)
                    guard re.firstMatch(in: ctx.windowTitle, range: r) != nil else { return nil }
                }
                for entity in requiredEntities {
                    guard let v = ctx.entities[entity], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                }
                if !textAny.isEmpty || !textAll.isEmpty {
                    let text = ctx.screenText.lowercased()
                    if !textAny.isEmpty, !textAny.contains(where: { text.contains($0) }) { return nil }
                    if textAll.contains(where: { !text.contains($0) }) { return nil }
                }
                let rendered = Self.render(keyTemplate, ctx).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rendered.isEmpty { return rendered }
                return ctx.windowTitle.isEmpty ? ctx.appName : ctx.windowTitle
            },
            makeGoal: { ctx in
                // The safety sentence is appended HERE, unconditionally. A
                // manifest author cannot opt out of it.
                Self.render(goalTemplate, ctx) + "\n\n" + DefaultPlaybooks.safetyRule
            },
            makeTitle: { ctx in
                let t = Self.render(titleTemplate, ctx).trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? name : t
            },
            makeTarget: { ctx in
                targetName == "typeintoapp" ? .typeIntoApp(appName: ctx.appName) : .clipboard
            }
        )
        playbook.persona = personaText.isEmpty ? nil : personaText
        playbook.mcpServers = servers
        playbook.source = source
        return playbook
    }

    // MARK: - Templates
    //
    // Placeholders, all optional:
    //   {app} {windowTitle} {contextType} {screenText} {scene}
    //   {<entityKey>} for any canonical entity key, e.g. {contact} {repoOwner}
    // Unknown placeholders render as empty strings so a typo cannot leak
    // literal braces into the prompt.

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")

    static func render(_ template: String, _ ctx: PlaybookContext) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for m in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1))
            out += value(for: name, ctx)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func value(for name: String, _ ctx: PlaybookContext) -> String {
        switch name {
        case "app":         return ctx.appName
        case "windowTitle": return ctx.windowTitle
        case "contextType": return ctx.contextType
        case "screenText":  return String(ctx.screenText.prefix(1500))
        case "scene":       return DefaultPlaybooks.scene(ctx)
        default:            return ctx.entities[name] ?? ""
        }
    }
}

// MARK: - PlaybookRegistry
// The single list every consumer reads: built-ins first (evaluation order is
// priority order), then manifests from the playbooks folder in filename order.

enum PlaybookRegistry {
    struct LoadError: Identifiable {
        var id: String { file }
        let file: String
        let message: String
    }

    private static let lock = NSLock()
    private static var community: [Playbook] = []
    private static var loaded = false
    private static var _loadErrors: [LoadError] = []
    /// Read from the main thread by Settings while the watcher may be
    /// reloading on a utility queue — hence the lock.
    static var loadErrors: [LoadError] {
        lock.lock(); defer { lock.unlock() }
        return _loadErrors
    }

    /// Built-ins plus community manifests. Loads the folder on first access.
    static var all: [Playbook] {
        lock.lock(); defer { lock.unlock() }
        if !loaded { loadLocked() }
        return DefaultPlaybooks.all + community
    }

    static var communityCount: Int {
        lock.lock(); defer { lock.unlock() }
        if !loaded { loadLocked() }
        return community.count
    }

    /// Posted on the main queue after every (re)load so Settings can refresh.
    static let didReload = Notification.Name("holmes.playbookRegistry.didReload")

    /// Re-reads the folder (Settings ▸ "Reload", or the folder watcher).
    static func reload() {
        lock.lock(); loadLocked(); lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didReload, object: nil) }
    }

    // MARK: - Hot reload
    //
    // A DispatchSource on the directory fd fires on any create/rename/delete
    // inside it. Edits to an existing file are saved atomically by most editors
    // (write temp + rename), which the directory sees as a rename. Reloads are
    // debounced so a multi-file paste triggers one pass.

    private static var watchSource: DispatchSourceFileSystemObject?
    private static var fileSources: [DispatchSourceFileSystemObject] = []
    private static var pendingReload: DispatchWorkItem?
    private static var watching = false

    private static func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { reload() }
        pendingReload = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    static func startWatching() {
        lock.lock(); defer { lock.unlock() }
        watching = true
        watchDirectoryLocked()
        // Files loaded before the watcher started need their own sources too.
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
        watchFilesLocked(files)
    }

    /// Directory-entry events: files created, renamed (atomic saves), deleted.
    /// Re-armed on every reload so a deleted-and-recreated folder is re-watched.
    private static func watchDirectoryLocked() {
        watchSource?.cancel()
        watchSource = makeSource(path: directory.path, mask: [.write, .rename, .delete])
        if watchSource == nil { print("[Holmes] PlaybookRegistry: cannot watch \(directory.path)") }
    }

    /// Per-file events: IN-PLACE saves (VS Code default, `>>`) change the file,
    /// not the directory, so each manifest gets its own source.
    private static func watchFilesLocked(_ files: [URL]) {
        guard watching else { return }
        fileSources.forEach { $0.cancel() }
        fileSources = files.compactMap { makeSource(path: $0.path, mask: [.write, .extend, .delete, .rename, .attrib]) }
        if watchSource == nil || !FileManager.default.fileExists(atPath: directory.path) { watchDirectoryLocked() }
    }

    /// ~/Library/Application Support/Holmes/playbooks — created on first use so
    /// "Open folder" always lands somewhere.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Holmes/playbooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadLocked() {
        loaded = true
        var result: [Playbook] = []
        var errors: [LoadError] = []
        var seen = Set(DefaultPlaybooks.all.map(\.id))
        let builtin = seen

        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let manifest = try JSONDecoder().decode(PlaybookManifest.self, from: data)
                let playbook = try manifest.compile(reservedIDs: builtin, source: file.lastPathComponent)
                guard !seen.contains(playbook.id) else {
                    errors.append(LoadError(file: file.lastPathComponent, message: "id \"\(playbook.id)\" is already defined by an earlier file"))
                    continue
                }
                seen.insert(playbook.id)
                result.append(playbook)
            } catch let e as DecodingError {
                errors.append(LoadError(file: file.lastPathComponent, message: Self.describe(e)))
            } catch {
                errors.append(LoadError(file: file.lastPathComponent, message: error.localizedDescription))
            }
        }

        community = result
        _loadErrors = errors
        watchFilesLocked(files)
        print("[Holmes] PlaybookRegistry: \(result.count) community playbook(s) from \(directory.path)"
              + (errors.isEmpty ? "" : "; \(errors.count) skipped"))
        for e in errors { print("[Holmes] PlaybookRegistry: skipped \(e.file) — \(e.message)") }
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String { c.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c):   return "missing required field \"\(path(c.codingPath + [k]))\""
        case .typeMismatch(_, let c):      return "wrong type at \"\(path(c.codingPath))\""
        case .valueNotFound(_, let c):     return "null at \"\(path(c.codingPath))\""
        case .dataCorrupted(let c):        return c.debugDescription.isEmpty ? "not valid JSON" : c.debugDescription
        @unknown default:                  return "could not decode"
        }
    }
}
