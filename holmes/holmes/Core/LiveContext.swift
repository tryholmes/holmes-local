import Foundation

// MARK: - LiveContext
// The anti-hallucination core of Holmes.
//
// Every sentence Holmes says about "what you are doing right now" is built HERE,
// deterministically, from structured data — never by a language model. A model may
// only ENRICH an already-correct headline (adding a goal, extra entities); it may
// never author one. That single rule is what stopped Holmes from confidently
// describing screens it could not actually read.
//
// Three ladders of truth, in descending order of trust:
//   .exact      — the browser extension read the DOM, or a structured AX field.
//                 Facts are literal. Holmes may quote them.
//   .structural — the macOS Accessibility tree. Reliable but coarse: we know the
//                 app, the window, the focused control, often the text — but not
//                 the page's semantics.
//   .inferred   — OCR of pixels. Garbled by definition. Holmes NEVER asserts a
//                 specific from this tier; it says what it cannot read instead.

// MARK: - ContextSource

/// How the context was obtained. Drives whether Holmes may state facts.
enum ContextSource: String, Codable {
    case browserExtension
    case accessibility
    case ocr
    case none

    /// Short human label for the UI's provenance badge.
    var label: String {
        switch self {
        case .browserExtension: return "Extension"
        case .accessibility:    return "Accessibility"
        case .ocr:              return "OCR"
        case .none:             return "None"
        }
    }
}

// MARK: - ContextConfidence

/// EXACT      = read from the browser DOM or a structured AX field. Facts are literal.
/// STRUCTURAL = read from the macOS Accessibility tree. Reliable but coarse.
/// INFERRED   = OCR of pixels. May be garbled. Holmes must NEVER assert specifics
///              from .inferred data — it hedges or says it cannot read the screen.
enum ContextConfidence: String, Codable {
    case exact
    case structural
    case inferred

    /// Ordering so callers can prefer the better of two candidate contexts.
    var rank: Int {
        switch self {
        case .exact:      return 3
        case .structural: return 2
        case .inferred:   return 1
        }
    }

    /// Label for the provenance chip in the UI. Deliberately blunt — the user
    /// should always be able to see how much Holmes actually knows.
    var label: String {
        switch self {
        case .exact:      return "Exact"
        case .structural: return "Structural"
        case .inferred:   return "Guessing"
        }
    }

    /// How a block of extracted screen text must be introduced TO A MODEL.
    /// The card is honest about OCR; the model's INPUT has to be too, or Claude
    /// will quote garbled pixels back as names, numbers and code. Every consumer
    /// that hands `HolmesAgent.lastOCRText` to a model prints this above it.
    var textReliabilityNote: String {
        switch self {
        case .exact, .structural:
            return "read from the DOM/Accessibility tree — literal"
        case .inferred:
            return "UNRELIABLE OCR of pixels — may be garbled. Do NOT quote names, numbers, code, or addresses from it as fact; say you cannot read the screen instead."
        }
    }
}

// MARK: - FocusedField

/// The control the caret is in. When this is editable it OUTRANKS everything
/// else on screen: what someone is composing beats what they are reading.
struct FocusedField: Codable, Equatable {
    let role: String
    let label: String
    let value: String
    let isEditable: Bool

    init(role: String, label: String, value: String, isEditable: Bool) {
        self.role = role
        self.label = label
        self.value = value
        self.isEditable = isEditable
    }

    /// Words typed so far — a live number the headline can quote truthfully.
    var wordCount: Int {
        value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// A real composition, not an empty box or a stray focus ring.
    var isComposing: Bool {
        isEditable && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - MediaState

/// A playing video/track, with its live position. Timestamps are the cheapest
/// possible proof that Holmes is actually looking at the same screen the user is.
struct MediaState: Codable, Equatable {
    let title: String
    let positionSeconds: Double
    let durationSeconds: Double
    let isPlaying: Bool

    init(title: String, positionSeconds: Double, durationSeconds: Double, isPlaying: Bool) {
        self.title = title
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isPlaying = isPlaying
    }

    /// "2:14" / "1:02:03". Empty when the position is unknown.
    var positionLabel: String { LiveContextFormat.timecode(positionSeconds) }
    var durationLabel: String { LiveContextFormat.timecode(durationSeconds) }

    /// "2:14 of 8:03" — only when both numbers are real.
    var progressLabel: String? {
        guard positionSeconds >= 0, durationSeconds > 1 else { return nil }
        return "\(positionLabel) of \(durationLabel)"
    }
}

// MARK: - ContextSurface

/// WHAT KIND of screen this is. The headline formatter switches on this, so every
/// surface gets a sentence written for it rather than a generic template.
/// Carried inside `LiveContext.entities["surface"]` so downstream code can read it.
enum ContextSurface: String, Codable {
    case emailRead
    case emailCompose
    case emailInbox
    case socialPost
    case socialFeed
    case video
    case githubPR
    case githubIssue
    case githubFile
    case githubRepo
    case directMessage
    case teamChannel
    case aiChat
    case document
    case article
    case search
    case shopping
    case code
    case terminal
    case unknown
}

// MARK: - LiveContext

/// The single source of truth for "what is the user doing RIGHT NOW".
struct LiveContext: Codable, Equatable {
    let source: ContextSource
    let confidence: ContextConfidence
    let app: String              // real app name — "Comet", "Xcode", "Messages"
    let site: String?            // host, e.g. "x.com" — nil when not a browser
    let url: String?
    let title: String
    let activity: String         // reading | composing | watching | coding | chatting | searching | shopping | browsing | other
    let headline: String         // THE exact one-line answer. Deterministic. No model.
    let detail: String           // deterministic multi-line specifics
    let entities: [String: String]
    let selection: String?
    let focusedField: FocusedField?
    let media: MediaState?
    let bodyText: String         // clean extracted text (DOM or AX), NOT OCR mush
    let capturedAt: Date

    // Defaults let callers construct partial contexts without repeating nils; the
    // argument labels and order match the canonical memberwise initializer.
    init(source: ContextSource,
         confidence: ContextConfidence,
         app: String,
         site: String? = nil,
         url: String? = nil,
         title: String = "",
         activity: String = "other",
         headline: String,
         detail: String = "",
         entities: [String: String] = [:],
         selection: String? = nil,
         focusedField: FocusedField? = nil,
         media: MediaState? = nil,
         bodyText: String = "",
         capturedAt: Date = Date()) {
        self.source = source
        self.confidence = confidence
        self.app = app
        self.site = site
        self.url = url
        self.title = title
        self.activity = activity
        self.headline = headline
        self.detail = detail
        self.entities = entities
        self.selection = selection
        self.focusedField = focusedField
        self.media = media
        self.bodyText = bodyText
        self.capturedAt = capturedAt
    }

    /// Stable identity of this screen — used for dedupe + enrichment gating.
    /// Deliberately EXCLUDES anything that churns on its own (media position,
    /// word counts, capture time) so a video playing or a draft growing by one
    /// word doesn't look like a brand-new screen and re-trigger enrichment.
    var fingerprint: String {
        var parts: [String] = [
            source.rawValue,
            app.lowercased(),
            site?.lowercased() ?? "",
            LiveContextFormat.canonicalURL(url) ?? "",
            title.lowercased()
        ]
        for key in Self.fingerprintKeys {
            if let value = entities[key], !value.isEmpty {
                parts.append("\(key)=\(value.lowercased())")
            }
        }
        // Composing vs reading the same page are genuinely different situations.
        if focusedField?.isEditable == true { parts.append("composing") }
        return LiveContextFormat.stableHash(parts.joined(separator: "|"))
    }

    /// Entity keys that IDENTIFY a screen (vs ones that merely decorate it).
    private static let fingerprintKeys = [
        "surface", "sender", "recipient", "subject", "author", "contact",
        "channel", "repo", "prNumber", "issueNumber", "file", "docTitle",
        "articleTitle", "query", "assistant", "videoID", "product"
    ]

    /// True only when confidence == .exact. Gate every factual assertion on this.
    var isTrustworthy: Bool { confidence == .exact }

    /// The user is typing into something — the strongest possible signal of intent.
    var isComposing: Bool { focusedField?.isEditable == true }

    /// How old this reading is. The UI shows it so a frozen context can't be
    /// mistaken for a live one.
    var age: TimeInterval { Date().timeIntervalSince(capturedAt) }

    /// One-line provenance the user can check the headline against.
    var provenance: String {
        switch source {
        case .browserExtension: return "Read from the page itself (\(confidence.rawValue))"
        case .accessibility:    return "Read from macOS Accessibility (\(confidence.rawValue))"
        case .ocr:              return "Guessed from pixels — OCR only, unreliable"
        case .none:             return "No context available"
        }
    }

    static let unknown = LiveContext(
        source: .none,
        confidence: .inferred,
        app: "",
        site: nil,
        url: nil,
        title: "",
        activity: "other",
        headline: "Holmes can't see your screen right now — no extension, no Accessibility data.",
        detail: "No context source has reported yet. Grant Accessibility + Screen Recording in System Settings, or install the Holmes browser extension for exact page context.",
        // The headline above is an admission, not a reading — see the
        // headlineKind contract in LiveContextBuilder.finish.
        entities: ["headlineKind": "fallback"],
        selection: nil,
        focusedField: nil,
        media: nil,
        bodyText: "",
        capturedAt: .distantPast
    )
}

// MARK: - ContextDraft
// The raw structured material a builder gathers BEFORE the formatter runs.
// Keeping this separate is what lets all three sources (extension, AX, OCR) share
// one headline formatter — and one validator.

struct ContextDraft {
    var source: ContextSource
    var confidence: ContextConfidence
    var app: String
    var site: String?
    var url: String?
    var title: String = ""
    var surface: ContextSurface = .unknown
    var entities: [String: String] = [:]
    var selection: String?
    var focusedField: FocusedField?
    var media: MediaState?
    var bodyText: String = ""

    /// Entity lookup that treats empty strings as missing — extension payloads are
    /// full of `""` for fields the page simply didn't have.
    func entity(_ keys: String...) -> String? {
        for key in keys {
            if let value = entities[key]?.trimmed, !value.isEmpty { return value }
        }
        return nil
    }

    func number(_ keys: String...) -> Int? {
        for key in keys {
            if let raw = entities[key]?.trimmed, let n = Int(raw) { return n }
        }
        return nil
    }

    var flagIsReply: Bool {
        (entities["isReply"] ?? "").lowercased() == "true"
            || (entity("subject")?.lowercased().hasPrefix("re:") ?? false)
    }
}

// MARK: - LiveContextBuilder

enum LiveContextBuilder {

    // MARK: Browser extension (EXACT)
    //
    // Payload contract with the extension (all fields optional except one of
    // url/title/bodyText). Unknown keys are ignored; several aliases are accepted
    // so an older extension build keeps working.
    //
    //   {
    //     "app":     "Comet",
    //     "url":     "https://x.com/sama/status/123",
    //     "site":    "x.com",                       // derived from url when absent
    //     "title":   "sama on X: …",
    //     "surface": "socialPost",                  // see ContextSurface
    //     "activity":"reading",
    //     "entities":{ "author":"@sama", "topic":"GPT-5 pricing" },
    //     "selection":"…",
    //     "focusedField":{"role":"textbox","label":"Post your reply",
    //                     "value":"…","isEditable":true},
    //     "media":{"title":"Rust in 100 Seconds","creator":"Fireship",
    //              "position":134,"duration":483,"playing":true},
    //     "bodyText":"clean DOM text"
    //   }
    //
    // Canonical entity keys the formatter understands:
    //   sender, senderEmail, recipient, subject, threadCount, isReply, unreadCount,
    //   author, topic, creator, videoID,
    //   repo, prNumber, prTitle, issueNumber, issueTitle, additions, deletions, file,
    //   contact, lastMessage, lastMessageGist, lastSender, channel,
    //   assistant, prompt, docTitle, section, articleTitle, byline,
    //   query, product, price

    /// Builds an EXACT LiveContext from the browser extension payload.
    /// Returns nil when the payload carries nothing identifying — an honest nil is
    /// always better than a headline invented from an empty page.
    static func fromBrowser(_ payload: [String: Any]) -> LiveContext? {
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let value = payload[key] as? String {
                    let t = value.trimmed
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }

        // Heartbeats and pings carry no page content — the bridge handles those.
        let kind = (str("type", "kind") ?? "").lowercased()
        if kind == "heartbeat" || kind == "ping" { return nil }

        let url = str("url", "href")
        let site = str("site", "host", "domain") ?? LiveContextFormat.host(of: url)
        let title = str("title", "pageTitle", "documentTitle") ?? ""
        let bodyText = String((str("bodyText", "text", "content") ?? "").prefix(24_000))

        // Nothing identifying at all → say nothing. This is the honest nil.
        guard url != nil || !title.isEmpty || !bodyText.isEmpty else { return nil }

        var entities: [String: String] = [:]
        if let raw = payload["entities"] as? [String: Any] {
            for (key, value) in raw {
                let s = (value as? String) ?? String(describing: value)
                let t = s.trimmed
                if !t.isEmpty { entities[key] = String(t.prefix(400)) }
            }
        }
        // Legacy/flat payloads put these at the top level (the v1 Gmail script did).
        for key in ["sender", "senderEmail", "recipient", "subject", "author", "topic",
                    "contact", "channel", "repo", "file", "query", "assistant",
                    "prompt", "docTitle", "section", "articleTitle", "lastMessage",
                    "lastSender", "product", "price", "creator"] {
            if entities[key] == nil, let value = str(key) { entities[key] = String(value.prefix(400)) }
        }
        // v1 extension shape: {type:"gmail_compose", recipient, subject, body}.
        if entities["draft"] == nil, kind == "gmail_compose", let body = str("body") {
            entities["draft"] = String(body.prefix(2000))
        }

        let focused = focusedField(from: payload["focusedField"] ?? payload["focused"])
        let media = mediaState(from: payload["media"])
        // The creator/channel lives in the media object but reads as an entity
        // ("… by Fireship"), so promote it before the formatter runs.
        if entities["creator"] == nil,
           let mediaDict = payload["media"] as? [String: Any],
           let creator = (mediaDict["creator"] as? String ?? mediaDict["channel"] as? String)?.trimmed,
           !creator.isEmpty {
            entities["creator"] = creator
        }

        var draft = ContextDraft(
            source: .browserExtension,
            confidence: .exact,
            app: str("app", "browser") ?? "your browser",
            site: site,
            url: url,
            title: title,
            surface: .unknown,
            entities: entities,
            selection: str("selection", "selectedText"),
            focusedField: focused,
            media: media,
            bodyText: bodyText
        )
        draft.surface = ContextSurface.infer(hint: str("surface") ?? kind,
                                             site: site, url: url, title: title,
                                             entities: entities, media: media,
                                             focusedField: focused)
        draft.entities["surface"] = draft.surface.rawValue
        if let creator = draft.entity("creator", "channelName") { draft.entities["creator"] = creator }

        return finish(draft, activityOverride: str("activity"))
    }

    // MARK: Accessibility (STRUCTURAL)

    /// Builds a STRUCTURAL LiveContext from a structured Accessibility reading.
    ///
    /// For editors and terminals the identifying facts (file, workspace, caret
    /// line, enclosing symbol; cwd, command) were read from TARGETED AX attributes
    /// — not scraped from text — so they drive the surface directly and the
    /// headline is a real reading ("Editing ScreenEngine.swift in holmes — struct
    /// FocusedContext", "Running `npm test` in ~/dev/holmes"). Generic apps fall to
    /// the same battle-tested classifier the OCR path once shared.
    static func fromAccessibility(reading: ScreenReading, focused: FocusedField?) -> LiveContext {
        let cleanText = String(reading.bodyText.prefix(16_000))
        var draft = ContextDraft(
            source: .accessibility,
            confidence: .structural,
            app: reading.appName,
            site: nil,
            url: reading.url,
            title: reading.windowTitle.trimmed,
            surface: .unknown,
            entities: [:],
            selection: nil,
            focusedField: focused,
            media: nil,
            bodyText: cleanText
        )

        switch reading.kind {
        case .editor:
            // Structural editor facts — read, not guessed. These OUTRANK any
            // filename the classifier might scrape from the window title.
            draft.surface = .code
            if let file = reading.fileName ?? LiveContextFormat.fileName(inWindowTitle: reading.windowTitle) {
                draft.entities["file"] = file
            }
            if let workspace = reading.workspace { draft.entities["workspace"] = workspace }
            if let symbol = reading.symbol       { draft.entities["symbol"] = symbol }
            if let line = reading.lineNumber     { draft.entities["line"] = "\(line)" }
            if let path = reading.documentPath   { draft.entities["docPath"] = path }
            if let selection = reading.selectedText, !selection.trimmed.isEmpty {
                draft.selection = String(selection.prefix(300))
            }

        case .terminal:
            draft.surface = .terminal
            if let command = reading.command     { draft.entities["command"] = command }
            if let cwd = reading.workingDir      { draft.entities["cwd"] = cwd }

        case .chat:
            // Native chat app (WhatsApp / Messages / Discord / …). The contact
            // and last bubble were read from the transcript, not guessed — so
            // this drives the directMessage headline directly at .structural.
            draft.surface = .directMessage
            if let contact = reading.contact     { draft.entities["contact"] = contact }
            if let last = reading.lastMessage    { draft.entities["lastMessage"] = String(last.prefix(200)) }

        case .generic:
            classifyGeneric(&draft, app: reading.appName, window: reading.windowTitle,
                            cleanText: cleanText, focused: focused)
        }

        draft.entities["surface"] = draft.surface.rawValue
        return finish(draft, activityOverride: nil)
    }

    /// String-only shim for any caller that still hands us a flat AX blob: wraps it
    /// as a generic reading and routes through the primary builder above.
    static func fromAccessibility(app: String, window: String,
                                  axText: String, focused: FocusedField?) -> LiveContext {
        fromAccessibility(reading: ScreenReading(appName: app, windowTitle: window,
                                                 bodyText: axText, kind: .generic),
                          focused: focused)
    }

    /// The classifier path for generic native apps (Mail, Messages, Slack, Notes,
    /// Finder…): reuse ContextEngine's extractors — they were written for OCR mush,
    /// so on clean AX text they are strictly more reliable.
    private static func classifyGeneric(_ draft: inout ContextDraft, app: String,
                                        window: String, cleanText: String,
                                        focused: FocusedField?) {
        let engine = ContextEngine.shared
        let snapshot = ContextSnapshot(appName: app, windowTitle: window,
                                       ocrText: cleanText, timestamp: Date())
        let classified = engine.classify(snapshot: snapshot)

        for (key, value) in classified.entities where !value.trimmed.isEmpty {
            switch key {
            case "repoOwner", "repoName": continue     // merged into "repo" below
            case "promptText":            draft.entities["prompt"] = value
            case "platform":              draft.entities["platform"] = value
            default:                      draft.entities[key] = value
            }
        }
        if let owner = classified.entities["repoOwner"], let name = classified.entities["repoName"] {
            draft.entities["repo"] = "\(owner)/\(name)"
        }

        draft.surface = surfaceFromClassification(classified.type, app: app,
                                                  window: window, entities: draft.entities)

        // Per-surface structural detail the classifier doesn't produce.
        switch draft.surface {
        case .aiChat:
            let platform = classified.entities["platform"] ?? engine.detectAIPlatform(app: app, title: window)
            draft.entities["assistant"] = assistantDisplayName(platform)
            if draft.entities["prompt"] == nil, let prompt = engine.extractPromptText(from: cleanText) {
                draft.entities["prompt"] = prompt
            }
        case .directMessage:
            if draft.entities["contact"] == nil,
               let contact = engine.extractIMessageSenderPublic(from: cleanText) {
                draft.entities["contact"] = contact
            }
            if let last = engine.extractLastMessagePublic(from: cleanText) {
                draft.entities["lastMessage"] = String(last.prefix(200))
            }
        case .teamChannel:
            if let channel = draft.entities["contact"], draft.entities["channel"] == nil {
                draft.entities["channel"] = channel
            }
        case .code:
            if let file = LiveContextFormat.fileName(inWindowTitle: window) {
                draft.entities["file"] = file
            }
        case .terminal:
            if let command = LiveContextFormat.lastShellCommand(in: cleanText) {
                draft.entities["command"] = command
            }
        case .githubPR, .githubRepo, .githubFile:
            if draft.entities["repo"] == nil,
               let repo = engine.extractGitHubRepo(fromTitle: window) {
                draft.entities["repo"] = "\(repo.owner)/\(repo.name)"
            }
        default:
            break
        }

        // A live selection is the sharpest structural signal there is.
        if let field = focused, !field.value.isEmpty, !field.isEditable {
            draft.selection = String(field.value.prefix(300))
        }
    }

    // MARK: OCR (INFERRED)

    /// Builds an INFERRED LiveContext from OCR.
    ///
    /// The headline is hedged and asserts NOTHING from the pixels — OCR garbling is
    /// exactly what produced Holmes's old confident-and-wrong descriptions. The OCR
    /// text is deliberately NOT stored in `bodyText` (which is contractually clean
    /// DOM/AX text): only its length is kept, so nothing downstream can quote it.
    static func fromOCR(app: String, window: String, ocrText: String) -> LiveContext {
        let trimmedWindow = window.trimmed
        let characters = ocrText.trimmed.count

        var entities: [String: String] = [
            "surface": ContextSurface.unknown.rawValue,
            "ocrCharacters": "\(characters)"
        ]
        if !trimmedWindow.isEmpty { entities["window"] = trimmedWindow }

        let draft = ContextDraft(
            source: .ocr,
            confidence: .inferred,
            app: app,
            site: nil,
            url: nil,
            title: trimmedWindow,
            surface: .unknown,
            entities: entities,
            selection: nil,
            focusedField: nil,
            media: nil,
            bodyText: ""    // never OCR mush — see doc comment
        )
        return finish(draft, activityOverride: nil)
    }

    // MARK: Honest "no data" contexts

    /// The context to show when the user is in a browser Holmes cannot read.
    /// This is the sanctioned alternative to guessing: name the missing piece.
    static func extensionUnavailable(app: String, window: String = "") -> LiveContext {
        let headline = "Can't read this page — the Holmes extension isn't running in \(app)."
        return LiveContext(
            source: .none,
            confidence: .inferred,
            app: app,
            site: nil,
            url: nil,
            title: window.trimmed,
            activity: "other",
            headline: headline,
            detail: """
            Source: none — no page data reached Holmes.
            App: \(app)\(window.trimmed.isEmpty ? "" : "\nWindow: \"\(window.trimmed)\"")
            Fix: install/enable the Holmes extension in \(app), then paste the bridge token from Settings so it can connect.
            Until then Holmes will not describe this page — it has nothing literal to describe.
            """,
            // This headline states what Holmes COULDN'T read. Marking it as a
            // fallback is what stops enrichment from appending a model-authored
            // specific to a sentence that says Holmes can't tell.
            entities: ["surface": ContextSurface.unknown.rawValue,
                       "headlineKind": "fallback"],
            selection: nil,
            focusedField: nil,
            media: nil,
            bodyText: "",
            capturedAt: Date()
        )
    }

    // MARK: Assembly

    /// Runs the deterministic formatter over a draft and seals it into a LiveContext.
    ///
    /// The formatter reports WHICH KIND of sentence it produced, and that verdict
    /// is stamped into `entities["headlineKind"]`:
    ///
    ///   "specific" — a real reading: every clause came from a field that was read.
    ///   "fallback" — an admission of failure (hedged OCR line, honestFallback, or
    ///                a candidate the validator rejected as app-name-only).
    ///
    /// This is a first-class fact because enrichment depends on it: a model may
    /// append specifics behind a real reading, but appending to "Holmes can't tell
    /// what's on screen" is pure invention with a true sentence bolted on the
    /// front. See HolmesAgent.acceptedHeadline.
    static func finish(_ draft: ContextDraft, activityOverride: String?) -> LiveContext {
        var draft = draft
        let headline = HeadlineFormatter.headline(draft)
        draft.entities["headlineKind"] = headline.isFallback ? "fallback" : "specific"
        let detail = HeadlineFormatter.detail(draft, headline: headline.text)
        let activity = HeadlineFormatter.normalizedActivity(activityOverride, draft: draft)
        return LiveContext(
            source: draft.source,
            confidence: draft.confidence,
            app: draft.app,
            site: draft.site,
            url: draft.url,
            title: draft.title,
            activity: activity,
            headline: headline.text,
            detail: detail,
            entities: draft.entities,
            selection: draft.selection,
            focusedField: draft.focusedField,
            media: draft.media,
            bodyText: draft.bodyText,
            capturedAt: Date()
        )
    }

    // MARK: Payload sub-objects

    private static func focusedField(from any: Any?) -> FocusedField? {
        guard let dict = any as? [String: Any] else { return nil }
        let role = (dict["role"] as? String ?? "").trimmed
        let label = (dict["label"] as? String ?? dict["placeholder"] as? String ?? "").trimmed
        let value = String(((dict["value"] as? String) ?? (dict["text"] as? String) ?? "").prefix(4000))
        // Trust an explicit flag; otherwise infer from the role name (the extension
        // sends DOM/ARIA roles, the AX path sends AX roles — accept both).
        let editable: Bool
        if let flag = dict["isEditable"] as? Bool {
            editable = flag
        } else if let flag = dict["editable"] as? Bool {
            editable = flag
        } else {
            let editableRoles: Set<String> = ["textbox", "textarea", "input", "searchbox",
                                              "combobox", "contenteditable",
                                              "axtextfield", "axtextarea", "axcombobox",
                                              "axsearchfield"]
            editable = editableRoles.contains(role.lowercased())
        }
        guard !role.isEmpty || !label.isEmpty || !value.isEmpty else { return nil }
        return FocusedField(role: role, label: label, value: value, isEditable: editable)
    }

    private static func mediaState(from any: Any?) -> MediaState? {
        guard let dict = any as? [String: Any] else { return nil }
        func double(_ keys: String...) -> Double? {
            for key in keys {
                if let d = dict[key] as? Double { return d }
                if let i = dict[key] as? Int { return Double(i) }
                if let s = dict[key] as? String, let d = Double(s) { return d }
            }
            return nil
        }
        let title = ((dict["title"] as? String) ?? "").trimmed
        let position = double("position", "positionSeconds", "currentTime") ?? -1
        let duration = double("duration", "durationSeconds") ?? -1
        let playing = (dict["playing"] as? Bool) ?? (dict["isPlaying"] as? Bool) ?? (position >= 0)
        guard !title.isEmpty || duration > 0 else { return nil }
        return MediaState(title: title, positionSeconds: position,
                          durationSeconds: duration, isPlaying: playing)
    }

    private static func surfaceFromClassification(_ type: ContextEngine.ContextType,
                                                  app: String, window: String,
                                                  entities: [String: String]) -> ContextSurface {
        switch type {
        case .emailCompose: return .emailCompose
        case .emailInbox:   return entities["sender"] != nil ? .emailRead : .emailInbox
        case .iMessage:     return .directMessage
        case .chat:         return (entities["contact"] ?? "").hasPrefix("#") ? .teamChannel : .directMessage
        case .aiPrompting:  return .aiChat
        case .githubRepo:   return .githubRepo
        case .linkedIn:     return .socialFeed
        case .coding:       return .code
        case .browsing:     return .article
        case .unknown:
            let a = app.lowercased()
            if a.contains("terminal") || a.contains("iterm") || a.contains("warp") || a.contains("ghostty") {
                return .terminal
            }
            if a.contains("xcode") || a.contains("cursor") || a.contains("code") {
                return .code
            }
            return .unknown
        }
    }

    private static func assistantDisplayName(_ platform: String?) -> String {
        switch (platform ?? "").lowercased() {
        case "claude":  return "Claude"
        case "chatgpt": return "ChatGPT"
        case "gemini":  return "Gemini"
        default:        return "the assistant"
        }
    }
}

// MARK: - ContextSurface inference

extension ContextSurface {

    /// Picks the surface from the extension's hint first (it read the DOM and knows
    /// best), then from the URL, then from which entities are present.
    static func infer(hint: String?, site: String?, url: String?, title: String,
                      entities: [String: String], media: MediaState?,
                      focusedField: FocusedField?) -> ContextSurface {
        // 1 — explicit hint, including the v1 extension's `type` values.
        if let raw = hint?.trimmed, !raw.isEmpty {
            if let exact = ContextSurface(rawValue: raw) { return exact }
            switch raw.lowercased() {
            case "gmail_compose", "email_compose", "compose": return .emailCompose
            case "gmail_read", "email_read", "email":         return .emailRead
            case "gmail_inbox", "inbox":                      return .emailInbox
            case "post", "tweet", "social":                   return .socialPost
            case "feed", "timeline":                          return .socialFeed
            case "watch", "video":                            return .video
            case "pr", "pull_request":                        return .githubPR
            case "issue":                                     return .githubIssue
            case "file", "blob":                              return .githubFile
            case "repo", "repository":                        return .githubRepo
            case "dm", "direct_message", "imessage":          return .directMessage
            case "channel", "slack":                          return .teamChannel
            case "ai", "ai_chat", "chatbot":                  return .aiChat
            case "doc", "document":                           return .document
            case "article", "blog":                           return .article
            case "search", "results":                         return .search
            case "product", "shopping":                       return .shopping
            default: break
            }
        }

        let host = (site ?? "").lowercased()
        let path = (LiveContextFormat.path(of: url) ?? "").lowercased()
        let hasComposer = focusedField?.isEditable == true

        // 2 — the URL is the most literal signal a browser can give.
        if host.contains("mail.google.com") || host.contains("outlook.") || host.contains("mail.proton") {
            if hasComposer || entities["recipient"] != nil { return .emailCompose }
            if entities["sender"] != nil || entities["subject"] != nil { return .emailRead }
            return .emailInbox
        }
        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("vimeo.com") {
            return media != nil || path.contains("watch") ? .video : .socialFeed
        }
        if host.contains("github.com") {
            if path.contains("/pull/") { return .githubPR }
            if path.contains("/issues/") { return .githubIssue }
            if path.contains("/blob/") || entities["file"] != nil { return .githubFile }
            if !path.isEmpty && path.split(separator: "/").count >= 2 { return .githubRepo }
            return .githubRepo
        }
        if host.contains("x.com") || host.contains("twitter.com")
            || host.contains("linkedin.com") || host.contains("reddit.com")
            || host.contains("threads.net") || host.contains("bsky.app") {
            if hasComposer && entities["author"] != nil { return .socialPost }
            if entities["author"] != nil || path.contains("/status/")
                || path.contains("/posts/") || path.contains("/comments/") { return .socialPost }
            return .socialFeed
        }
        if host.contains("claude.ai") || host.contains("chatgpt.com")
            || host.contains("chat.openai.com") || host.contains("gemini.google.com")
            || host.contains("perplexity.ai") || host.contains("copilot.microsoft.com") {
            return .aiChat
        }
        if host.contains("docs.google.com") || host.contains("notion.so")
            || host.contains("notion.site") || host.contains("quip.com")
            || host.contains("coda.io") || host.contains("sharepoint.com") {
            return .document
        }
        if host.contains("slack.com") || host.contains("discord.com") {
            return (entities["channel"] ?? "").hasPrefix("#") ? .teamChannel
                 : (entities["contact"] != nil ? .directMessage : .teamChannel)
        }
        if host.contains("web.whatsapp.com") || host.contains("messenger.com")
            || host.contains("web.telegram.org") || host.contains("messages.google.com") {
            return .directMessage
        }
        if host.contains("amazon.") || host.contains("ebay.") || host.contains("etsy.")
            || entities["price"] != nil || entities["product"] != nil {
            return .shopping
        }
        if entities["query"] != nil || path.hasPrefix("/search")
            || host.contains("google.com") && path.hasPrefix("/search") {
            return .search
        }

        // 3 — entity shape, when the host is unknown.
        if media != nil { return .video }
        if entities["prNumber"] != nil { return .githubPR }
        if entities["subject"] != nil && entities["sender"] != nil { return .emailRead }
        if entities["articleTitle"] != nil { return .article }
        if entities["docTitle"] != nil { return .document }
        if entities["contact"] != nil { return .directMessage }
        if site != nil && !title.isEmpty { return .article }
        return .unknown
    }
}

// MARK: - HeadlineFormatter
//
// THE HEART OF THE FILE. Turns structured fields into a literal English sentence.
// Every branch is pure string assembly over data that was READ, never guessed, and
// every branch degrades field by field instead of inventing a substitute.
//
// Ordering rule: composing > watching > reading > selection. What someone is
// WRITING beats what they are looking at, because that's what they need help with.

enum HeadlineFormatter {

    /// A candidate headline plus whether it may skip the "is this only an app
    /// name?" validator. `trustedThin` is for sentences that are honestly small
    /// but literally true (an inbox listing, an unreadable feed) — rejecting those
    /// would replace a true statement with a vaguer one.
    private struct Candidate {
        let text: String
        let trustedThin: Bool
        init(_ text: String, trustedThin: Bool = false) {
            self.text = text
            self.trustedThin = trustedThin
        }
    }

    // MARK: Entry point

    /// The sentence, plus whether it is a READING or an ADMISSION that Holmes
    /// couldn't produce one. Callers must carry `isFallback` forward — it is the
    /// difference between "there is something established here" and "there isn't",
    /// and only the first may be enriched (see LiveContextBuilder.finish).
    static func headline(_ d: ContextDraft) -> (text: String, isFallback: Bool) {
        // OCR never gets a specific sentence. Not one. This is the whole point.
        if d.confidence == .inferred || d.source == .ocr {
            return (hedgedHeadline(d), true)
        }
        guard let candidate = specific(d) else { return (honestFallback(d), true) }
        if candidate.trustedThin { return (candidate.text, false) }
        return validated(candidate.text, d)
    }

    private static func specific(_ d: ContextDraft) -> Candidate? {
        if let composing = composingHeadline(d) { return composing }
        if let watching = mediaHeadline(d) { return watching }
        if let reading = readingHeadline(d) { return reading }
        if let selected = selectionHeadline(d) { return selected }
        return nil
    }

    // MARK: Composing — beats everything else on screen

    private static func composingHeadline(_ d: ContextDraft) -> Candidate? {
        let field = d.focusedField
        let typing = field?.isEditable == true
        let draftText = (field?.isEditable == true ? field?.value : nil)?.trimmed
            ?? d.entity("draft") ?? ""
        let words = LiveContextFormat.wordCount(draftText)
        let place = siteName(d)

        switch d.surface {
        case .emailCompose:
            let verb = d.flagIsReply ? "Writing a reply" : "Writing an email"
            var line = verb
            if let to = d.entity("recipient", "to") { line += " to \(to)" }
            var tail: [String] = []
            if let subject = d.entity("subject") { tail.append("subject \(quoted(subject))") }
            if words > 0 { tail.append("\(words) \(plural(words, "word")) so far") }
            if !tail.isEmpty { line += " — " + tail.joined(separator: ", ") }
            return Candidate(line)

        case .socialPost, .socialFeed:
            // Only when the caret is actually in the composer — a post page with a
            // reply box the user hasn't clicked is being READ, not written.
            guard typing else { return nil }
            if let author = d.entity("author", "authorHandle") {
                var line = "Typing a reply to \(possessive(author)) post"
                if let place { line += " on \(place)" }
                if draftText.count >= 12 { line += " — \(quoted(short(draftText, 70)))" }
                return Candidate(line)
            }
            guard typing else { return nil }
            var line = place.map { "Writing a new post on \($0)" } ?? "Writing a new post"
            if draftText.count >= 12 { line += " — \(quoted(short(draftText, 70)))" }
            return Candidate(line)

        case .aiChat:
            // Only the LIVE composer counts here. A `prompt` entity is the question
            // already sent, which the reading branch phrases as "Reading Claude's
            // answer to …" — saying "Asking" then would misstate the moment.
            guard typing || !draftText.isEmpty else { return nil }
            let assistant = d.entity("assistant") ?? place ?? "the assistant"
            if !draftText.isEmpty {
                return Candidate("Asking \(assistant): \(quoted(short(draftText, 100)))")
            }
            return Candidate("Typing a message to \(assistant)", trustedThin: true)

        case .directMessage:
            guard typing else { return nil }
            var line = "Typing a message"
            if let contact = d.entity("contact", "recipient") { line += " to \(contact)" }
            if let place { line += " on \(place)" }
            if draftText.count >= 12 { line += " — \(quoted(short(draftText, 60)))" }
            return Candidate(line, trustedThin: d.entity("contact", "recipient") != nil)

        case .teamChannel:
            guard typing else { return nil }
            var line = "Typing a message"
            if let channel = d.entity("channel") { line += " in \(channel)" }
            if let place { line += " on \(place)" }
            if draftText.count >= 12 { line += " — \(quoted(short(draftText, 60)))" }
            return Candidate(line, trustedThin: d.entity("channel") != nil)

        case .document:
            // Not typing → the reading branch says "Reading …", which is the honest
            // verb for a document the user is only scrolling.
            guard typing else { return nil }
            let name = d.entity("docTitle") ?? cleanTitle(d)
            guard !name.isEmpty else { return nil }
            var line = "Editing \(quoted(name))"
            if let place { line += " in \(place)" }
            if let section = d.entity("section") { line += " — in the section \(quoted(section))" }
            else if words > 0 { line += " — \(words) \(plural(words, "word")) in this draft" }
            return Candidate(line)

        case .githubPR, .githubIssue:
            guard typing, draftText.count >= 4 else { return nil }
            let number = d.entity("prNumber", "issueNumber").map { "#\($0)" } ?? ""
            let kind = d.surface == .githubPR ? "PR" : "issue"
            var line = "Writing a comment on \(kind) \(number)".trimmed
            if let repo = d.entity("repo") { line += " in \(repo)" }
            line += " — \(quoted(short(draftText, 60)))"
            return Candidate(line)

        case .search:
            guard typing else { return nil }
            let query = draftText.isEmpty ? (d.entity("query") ?? "") : draftText
            guard !query.isEmpty else { return nil }
            return Candidate(place.map { "Searching \($0) for \(quoted(short(query, 70)))" }
                             ?? "Searching for \(quoted(short(query, 70)))")

        case .code, .terminal:
            // The AX "focused field" in an editor is the whole file — treat it as
            // reading/editing a file, not as composing a message.
            return nil

        default:
            // Generic editable control. A huge value means it's a document body,
            // not a compose box, so don't quote it as a message draft.
            guard typing, let field, draftText.count < 400 else { return nil }
            let where_ = place ?? (d.site ?? d.app)
            if !draftText.isEmpty {
                let inField = field.label.isEmpty ? "" : " in the \(quoted(field.label)) field"
                return Candidate("Typing\(inField) on \(where_) — \(quoted(short(draftText, 70)))")
            }
            guard !field.label.isEmpty else { return nil }
            return Candidate("Typing in the \(quoted(field.label)) field on \(where_)",
                             trustedThin: true)
        }
    }

    // MARK: Watching

    private static func mediaHeadline(_ d: ContextDraft) -> Candidate? {
        guard let media = d.media else { return nil }
        let name = media.title.isEmpty ? (d.entity("videoTitle") ?? cleanTitle(d)) : media.title
        guard !name.isEmpty else { return nil }
        var line = (media.isPlaying ? "Watching " : "Paused on ") + quoted(short(name, 80))
        if let creator = d.entity("creator", "channelName", "byline") { line += " by \(creator)" }
        if let place = siteName(d) { line += " on \(place)" }
        if let progress = media.progressLabel { line += " — \(progress)" }
        return Candidate(line)
    }

    // MARK: Reading

    private static func readingHeadline(_ d: ContextDraft) -> Candidate? {
        let place = siteName(d)

        switch d.surface {
        case .emailRead:
            let sender = d.entity("sender", "senderEmail")
            let subject = d.entity("subject")
            let thread = d.number("threadCount").map { " (\($0) \(plural($0, "message")) in thread)" } ?? ""
            if let sender, let subject {
                return Candidate("Reading \(possessive(sender)) email \(quoted(subject))\(thread)")
            }
            if let sender { return Candidate("Reading an email from \(sender)\(thread)") }
            if let subject { return Candidate("Reading the email \(quoted(subject))\(thread)") }
            return nil

        case .emailInbox:
            let unread = d.number("unreadCount")
            let top = d.entity("sender", "lastSender")
            var line = place.map { "In your \($0) inbox" } ?? "In your inbox"
            var tail: [String] = []
            if let unread, unread > 0 { tail.append("\(unread) unread") }
            if let top { tail.append("newest from \(top)") }
            if !tail.isEmpty { line += " — " + tail.joined(separator: ", ") }
            return Candidate(line, trustedThin: true)

        case .socialPost:
            guard let author = d.entity("author", "authorHandle") else {
                guard let text = d.entity("postText") else { return nil }
                var line = "Reading a post"
                if let place { line += " on \(place)" }
                return Candidate(line + " — \(quoted(short(text, 70)))")
            }
            var line = "Reading \(possessive(author)) post"
            if let place { line += " on \(place)" }
            if let topic = d.entity("topic") { line += " about \(short(topic, 60))" }
            else if let text = d.entity("postText") { line += " — \(quoted(short(text, 70)))" }
            return Candidate(line)

        case .socialFeed:
            if let place {
                return Candidate("Scrolling the \(place) feed — no single post in view",
                                 trustedThin: true)
            }
            return nil

        case .video:
            let name = d.entity("videoTitle") ?? cleanTitle(d)
            guard !name.isEmpty else { return nil }
            var line = "Watching \(quoted(short(name, 80)))"
            if let creator = d.entity("creator", "channelName") { line += " by \(creator)" }
            if let place { line += " on \(place)" }
            return Candidate(line)

        case .githubPR, .githubIssue:
            let isPR = d.surface == .githubPR
            let number = d.entity("prNumber", "issueNumber")
            let name = d.entity("prTitle", "issueTitle") ?? cleanTitle(d)
            var line = isPR ? "Reviewing PR" : "Reading issue"
            if let number { line += " #\(number)" }
            if !name.isEmpty { line += " \(quoted(short(name, 70)))" }
            if let repo = d.entity("repo") { line += " in \(repo)" }
            if let diff = diffLabel(d) { line += " \(diff)" }
            guard number != nil || !name.isEmpty else { return nil }
            return Candidate(line)

        case .githubFile:
            guard let file = d.entity("file") else { return nil }
            var line = "Reading \(file)"
            if let repo = d.entity("repo") { line += " in \(repo)" }
            if let place { line += " on \(place)" }
            return Candidate(line)

        case .githubRepo:
            guard let repo = d.entity("repo") else { return nil }
            var line = "Browsing the \(repo) repo"
            if let place { line += " on \(place)" }
            return Candidate(line)

        case .directMessage:
            guard let contact = d.entity("contact", "sender") else { return nil }
            // Native chat apps carry no site, so name the APP as the place — the
            // headline must never be contact-only ("Messaging Alex" says nothing
            // about where). A web DM keeps its host name (siteName) as before.
            let where_ = place ?? (d.site == nil ? d.app : nil)
            var line = "Messaging \(contact)"
            if let where_, !where_.isEmpty { line += " on \(where_)" }
            // `lastMessageGist` is the ONE place a model may contribute: a short
            // paraphrase of the last received message, written behind an already
            // correct headline. Absent it, we quote the message literally.
            if let gist = d.entity("lastMessageGist") { line += " — \(short(gist, 70))" }
            else if let last = d.entity("lastMessage") { line += " — last: \(quoted(short(last, 60)))" }
            return Candidate(line, trustedThin: true)

        case .teamChannel:
            guard let channel = d.entity("channel", "contact") else { return nil }
            var line = "In \(channel)"
            if let place { line += " on \(place)" }
            var tail: [String] = []
            if let unread = d.number("unreadCount"), unread > 0 {
                tail.append("\(unread) new \(plural(unread, "message"))")
            }
            if let last = d.entity("lastSender") { tail.append("last from \(last)") }
            if !tail.isEmpty { line += " — " + tail.joined(separator: ", ") }
            return Candidate(line, trustedThin: true)

        case .aiChat:
            let assistant = d.entity("assistant") ?? place ?? "an assistant"
            if let prompt = d.entity("prompt", "lastPrompt") {
                return Candidate("Reading \(assistant)'s answer to \(quoted(short(prompt, 80)))")
            }
            let name = cleanTitle(d)
            if !name.isEmpty {
                return Candidate("In a \(assistant) conversation titled \(quoted(short(name, 70)))")
            }
            return Candidate("In a \(assistant) conversation", trustedThin: true)

        case .document:
            let name = d.entity("docTitle") ?? cleanTitle(d)
            guard !name.isEmpty else { return nil }
            var line = "Reading \(quoted(short(name, 70)))"
            if let place { line += " in \(place)" }
            if let section = d.entity("section") { line += " — in the section \(quoted(section))" }
            return Candidate(line)

        case .search:
            guard let query = d.entity("query") else { return nil }
            return Candidate(place.map { "Searching \($0) for \(quoted(short(query, 70)))" }
                             ?? "Looking at results for \(quoted(short(query, 70)))")

        case .shopping:
            let product = d.entity("product") ?? cleanTitle(d)
            guard !product.isEmpty else { return nil }
            var line = "Looking at \(quoted(short(product, 70)))"
            if let place { line += " on \(place)" }
            if let price = d.entity("price") { line += " — \(price)" }
            return Candidate(line)

        case .code:
            guard let file = d.entity("file") ?? LiveContextFormat.fileName(inWindowTitle: d.title) else {
                return nil
            }
            // "in <project>" comes from the workspace/folder Holmes read (never
            // "in Xcode" — the app name says nothing the user's Dock doesn't).
            let place = d.entity("workspace", "repo")
            var line = place.map { "Editing \(file) in \($0)" } ?? "Editing \(file)"
            var tail: [String] = []
            if let ln = d.entity("line")                     { tail.append("line \(ln)") }
            if let symbol = d.entity("symbol", "function")   { tail.append(symbol) }
            if !tail.isEmpty { line += " — " + tail.joined(separator: ", ") }
            return Candidate(line)

        case .terminal:
            // cwd + command → "Running `npm test` in ~/dev/holmes". Backticks (not
            // quotes) keep the command literal without disarming the validator.
            let cwd = d.entity("cwd")
            if let command = d.entity("command") {
                var line = "Running `\(short(command, 60))`"
                if let cwd { line += " in \(cwd)" }
                return Candidate(line)
            }
            if let cwd {
                return Candidate("Working in a terminal in \(cwd)", trustedThin: true)
            }
            let name = cleanTitle(d)
            guard !name.isEmpty else { return nil }
            // NOT trustedThin: a terminal window is very often titled after the
            // terminal itself ("Ghostty"), and `In Ghostty — window "Ghostty"` is
            // the app-only shape rule 4 forbids. Let the validator decide.
            return Candidate("In \(d.app) — window \(quoted(short(name, 60)))")

        case .emailCompose:
            // The compose branch already had first refusal; if it declined there
            // is nothing readable here worth a sentence.
            return nil

        case .article, .unknown:
            let name = d.entity("articleTitle") ?? cleanTitle(d)
            // A window title that IS the app name ("Spotify", "Messages",
            // "System Settings") describes nothing. cleanTitle only strips a
            // separator-delimited brand suffix, so it hands those straight
            // through — refuse to build a sentence out of them at all rather
            // than emitting `Working on "Spotify" in Spotify` and hoping the
            // validator catches it.
            guard name.count >= 3,
                  !tokens(name).allSatisfy({ appNameTokens(d).contains($0) }) else { return nil }
            if let host = d.site {
                var line = "Reading \(quoted(short(name, 80))) on \(siteName(d) ?? host)"
                if let byline = d.entity("byline") { line += " by \(byline)" }
                return Candidate(line)
            }
            return Candidate("Working on \(quoted(short(name, 80))) in \(d.app)")
        }
    }

    // MARK: Selection — weakest specific signal, still literal

    private static func selectionHeadline(_ d: ContextDraft) -> Candidate? {
        guard let selection = d.selection?.trimmed, selection.count >= 3 else { return nil }
        let place = siteName(d) ?? d.site ?? d.app
        return Candidate("Looking at \(quoted(short(selection, 80))) in \(place)")
    }

    // MARK: OCR — hedged, never specific

    /// The ONLY sentence shape OCR is allowed to produce. The app name and window
    /// title come from the OS (not from pixels), so naming them is honest; every
    /// other detail is explicitly declared unreadable.
    private static func hedgedHeadline(_ d: ContextDraft) -> String {
        let app = d.app.trimmed.isEmpty ? "an app" : d.app.trimmed
        let window = d.title.trimmed
        if !window.isEmpty && window.lowercased() != app.lowercased() {
            return "Looks like you're in \(app), window \(quoted(short(window, 60))) — can't read the details (OCR only)"
        }
        return "Looks like you're in \(app) — can't read the details (OCR only)"
    }

    // MARK: - Validator
    //
    // The guard that enforces rule #4: a headline naming only an app or a site is
    // not a headline, it's a shrug. Anything that fails here is replaced with a
    // sentence that says exactly WHAT IS MISSING.

    /// Returns the headline when it carries real information, otherwise an honest
    /// statement of what Holmes couldn't read — flagged as a fallback so nothing
    /// downstream mistakes the substitute for a reading.
    private static func validated(_ candidate: String, _ d: ContextDraft) -> (text: String, isFallback: Bool) {
        let text = candidate.trimmed
        guard !text.isEmpty else { return (honestFallback(d), true) }
        guard !namesOnlyAnAppOrSite(text, d) else {
            #if DEBUG
            print("[LiveContext] Rejected app-only headline: \"\(text)\"")
            #endif
            return (honestFallback(d), true)
        }
        return (text, false)
    }

    /// True when, after removing filler words and every token of the app/site name,
    /// fewer than two meaningful words remain — i.e. the sentence says nothing the
    /// user didn't already know from their own Dock.
    ///
    /// Quoted content and digits are proof of specificity, but ONLY when what they
    /// carry isn't the app/site name over again. The formatter adds those quotes
    /// itself, so a syntactic "contains a quote" test let the validator be disarmed
    /// by its own punctuation — `Working on "Spotify" in Spotify` is a shrug wearing
    /// quotation marks, and `In 1Password` is not a count, a timestamp or a PR id.
    private static func namesOnlyAnAppOrSite(_ headline: String, _ d: ContextDraft) -> Bool {
        let nameTokens = appNameTokens(d)

        // A quoted span earns the short-circuit only if it contains a word that
        // is neither filler nor the app/site name — i.e. real screen content.
        // omittingEmptySubsequences: false keeps the odd/even parity honest when a
        // quote opens the sentence.
        let quotedSpans = headline.split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
        if quotedSpans.contains(where: { span in
            tokens(span).contains { !nameTokens.contains($0) && !fillerWords.contains($0) }
        }) { return false }

        // Same rule for digits: the number has to live in a token the app name
        // doesn't already supply ("1Password", "Xcode" + a real "#412" differ).
        if headline.rangeOfCharacter(from: .decimalDigits) != nil,
           tokens(headline).contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil
                                              && !nameTokens.contains($0) }) { return false }

        let meaningful = tokens(headline).filter {
            $0.count > 1 && !fillerWords.contains($0) && !nameTokens.contains($0)
        }
        return meaningful.count < 2
    }

    /// Every token of the app name, the host, and the host's display name — the
    /// words a headline can repeat without telling the user anything their Dock
    /// didn't. Shared by the validator and by the candidate branches that must
    /// refuse to build a sentence out of nothing but those words.
    private static func appNameTokens(_ d: ContextDraft) -> Set<String> {
        Set(tokens([d.app, d.site ?? "", siteName(d) ?? ""].joined(separator: " ")))
    }

    /// Words that carry no information about WHAT the user is doing.
    private static let fillerWords: Set<String> = [
        "a", "an", "the", "on", "in", "at", "of", "and", "with", "your", "you",
        "youre", "some", "something", "stuff", "now", "currently", "open",
        "using", "use", "used", "browsing", "browse", "viewing", "view",
        "looking", "look", "working", "work", "web", "app", "application",
        "screen", "page", "site", "website", "window", "tab", "content",
        "doing", "here", "this", "that", "it", "is", "are", "was"
    ]

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// What Holmes says when it genuinely doesn't know: name the missing piece.
    /// Never "Using Comet", never "Browsing the web".
    private static func honestFallback(_ d: ContextDraft) -> String {
        switch d.source {
        case .browserExtension:
            if let site = d.site {
                return "On \(site) — the Holmes extension sent no readable content for this page yet."
            }
            return "The Holmes extension is connected but sent no page content."
        case .accessibility:
            let app = d.app.trimmed.isEmpty ? "This app" : d.app.trimmed
            if d.bodyText.trimmed.isEmpty {
                return "\(app) is frontmost but exposes no text to Accessibility — Holmes can't tell what's on screen."
            }
            return "In \(app) — Holmes can read the window but can't identify a specific task on it."
        case .ocr:
            return hedgedHeadline(d)
        case .none:
            let app = d.app.trimmed
            return app.isEmpty
                ? "Holmes has no context source right now — no extension, no Accessibility data."
                : "Can't read this page — the Holmes extension isn't running in \(app)."
        }
    }

    // MARK: - Detail
    //
    // Deterministic multi-line specifics: the receipts behind the headline. Every
    // line is a field that was actually read. OCR contexts get the opposite — an
    // explicit statement that there is nothing quotable.

    static func detail(_ d: ContextDraft, headline: String) -> String {
        var lines: [String] = []
        lines.append("Source: \(d.source.label) · confidence \(d.confidence.rawValue)")

        guard d.confidence != .inferred else {
            let characters = d.entities["ocrCharacters"] ?? "0"
            lines.append("App: \(d.app)")
            if !d.title.isEmpty { lines.append("Window: \"\(d.title)\"") }
            lines.append("OCR produced \(characters) characters, and Holmes will not quote any of it — OCR text is unreliable.")
            lines.append("To get exact context here, use the Holmes browser extension (web pages) or grant Accessibility (native apps).")
            return lines.joined(separator: "\n")
        }

        lines.append("App: \(d.app)")
        if let site = d.site { lines.append("Site: \(site)") }
        if let url = d.url { lines.append("URL: \(short(url, 160))") }
        if !d.title.isEmpty { lines.append("Title: \"\(short(d.title, 140))\"") }

        // Entities in a stable, readable order — never dictionary order, which
        // would make the same screen produce a different detail block each tick.
        for key in detailKeyOrder {
            guard let value = d.entities[key]?.trimmed, !value.isEmpty else { continue }
            lines.append("\(detailLabels[key] ?? key.capitalized): \(short(value, 200))")
        }

        if let field = d.focusedField, field.isEditable {
            let label = field.label.isEmpty ? field.role : field.label
            let words = field.wordCount
            var line = "Composing in: \(label.isEmpty ? "a text field" : label)"
            if words > 0 { line += " (\(words) \(plural(words, "word")))" }
            lines.append(line)
            if !field.value.trimmed.isEmpty {
                lines.append("Draft so far: \"\(short(field.value.trimmed, 240))\"")
            }
        }
        if let media = d.media {
            var line = "Media: \"\(media.title)\""
            if let progress = media.progressLabel { line += " — \(progress)" }
            line += media.isPlaying ? " (playing)" : " (paused)"
            lines.append(line)
        }
        if let selection = d.selection?.trimmed, !selection.isEmpty {
            lines.append("Selected: \"\(short(selection, 240))\"")
        }
        if !d.bodyText.trimmed.isEmpty {
            lines.append("Page text (verbatim, \(d.bodyText.count) chars): \"\(short(d.bodyText.trimmed, 600))\"")
        }
        return lines.joined(separator: "\n")
    }

    private static let detailKeyOrder = [
        "sender", "senderEmail", "recipient", "subject", "threadCount",
        "unreadCount", "author", "topic", "postText", "creator", "videoTitle",
        "repo", "prNumber", "prTitle", "issueNumber", "issueTitle",
        "additions", "deletions", "file", "workspace", "line", "symbol", "function", "docPath",
        "contact", "lastSender", "lastMessage", "channel",
        "assistant", "prompt", "docTitle", "section",
        "articleTitle", "byline", "query", "product", "price", "cwd", "command",
        // Model enrichment lands here and ONLY here. It appears in the detail block
        // behind an already-correct headline; the formatter never reads it, so a
        // model can't rewrite what Holmes claims to see.
        "goal"
    ]

    private static let detailLabels: [String: String] = [
        "senderEmail": "Sender email", "threadCount": "Messages in thread",
        "unreadCount": "Unread", "postText": "Post", "videoTitle": "Video",
        "prNumber": "PR number", "prTitle": "PR title",
        "issueNumber": "Issue number", "issueTitle": "Issue title",
        "additions": "Lines added", "deletions": "Lines removed",
        "lastSender": "Last message from", "lastMessage": "Last message",
        "docTitle": "Document", "articleTitle": "Article",
        "creator": "Creator", "command": "Command",
        "workspace": "Project", "line": "Line", "symbol": "Symbol",
        "docPath": "File path", "cwd": "Working directory",
        "goal": "Apparent goal (model-enriched)"
    ]

    // MARK: - Activity

    /// Normalizes to the fixed vocabulary the rest of Holmes switches on:
    /// reading | composing | watching | coding | chatting | searching | shopping |
    /// browsing | other.
    static func normalizedActivity(_ override: String?, draft d: ContextDraft) -> String {
        let allowed: Set<String> = ["reading", "composing", "watching", "coding",
                                    "chatting", "searching", "shopping", "browsing", "other"]
        if let override = override?.lowercased().trimmed, allowed.contains(override) {
            return override
        }
        if d.confidence == .inferred { return "other" }
        if d.focusedField?.isEditable == true {
            switch d.surface {
            case .code, .terminal: return "coding"
            case .search:          return "searching"
            default:               return "composing"
            }
        }
        switch d.surface {
        case .emailCompose:                       return "composing"
        case .emailRead, .emailInbox, .article,
             .document, .githubPR, .githubIssue,
             .githubFile, .githubRepo, .socialPost: return "reading"
        case .video:                              return "watching"
        case .code, .terminal:                    return "coding"
        case .directMessage, .teamChannel, .aiChat: return "chatting"
        case .search:                             return "searching"
        case .shopping:                           return "shopping"
        case .socialFeed:                         return "browsing"
        case .unknown:                            return d.site != nil ? "browsing" : "other"
        }
    }

    // MARK: - Phrase helpers

    /// "Sarah Chen" → "Sarah Chen's", "@sama" → "@sama's", "Chris" → "Chris'".
    private static func possessive(_ name: String) -> String {
        let n = name.trimmed
        guard !n.isEmpty else { return n }
        return n.lowercased().hasSuffix("s") ? "\(n)'" : "\(n)'s"
    }

    private static func quoted(_ s: String) -> String { "\"\(s.trimmed)\"" }

    private static func short(_ s: String, _ limit: Int) -> String {
        let t = s.trimmed.replacingOccurrences(of: "\n", with: " ")
        return t.count > limit ? String(t.prefix(limit)).trimmed + "…" : t
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        n == 1 ? word : word + "s"
    }

    /// "(+220 −18)" — the real diff, using a proper minus sign. Nil unless at
    /// least one side is known.
    private static func diffLabel(_ d: ContextDraft) -> String? {
        let additions = d.number("additions")
        let deletions = d.number("deletions")
        switch (additions, deletions) {
        case (let a?, let b?): return "(+\(a) −\(b))"
        case (let a?, nil):    return "(+\(a))"
        case (nil, let b?):    return "(−\(b))"
        default:               return nil
        }
    }

    /// The window/tab title with the trailing site branding stripped
    /// ("Rust in 100 Seconds - YouTube" → "Rust in 100 Seconds").
    private static func cleanTitle(_ d: ContextDraft) -> String {
        var title = d.title.trimmed
        guard !title.isEmpty else { return "" }
        let brands = [siteName(d), d.site, d.app].compactMap { $0 }.filter { !$0.isEmpty }
        for separator in [" - ", " — ", " – ", " | ", " · ", " :: "] {
            for brand in brands {
                let suffix = separator + brand
                if title.lowercased().hasSuffix(suffix.lowercased()) {
                    title = String(title.dropLast(suffix.count)).trimmed
                }
            }
        }
        // "(3) Inbox" — unread badges browsers prepend to the tab title.
        if let range = title.range(of: "^\\(\\d+\\)\\s*", options: .regularExpression) {
            title.removeSubrange(range)
        }
        return title.trimmed
    }

    /// Human name for the site: "x.com" → "X", "swiftbysundell.com" → itself.
    private static func siteName(_ d: ContextDraft) -> String? {
        guard let host = d.site?.lowercased(), !host.isEmpty else { return nil }
        for (needle, name) in siteNames where host.contains(needle) { return name }
        return host
    }

    /// Brands whose display name differs from their host. Ordered longest-match
    /// first where hosts overlap (mail.google.com before google.com).
    private static let siteNames: [(String, String)] = [
        ("mail.google.com", "Gmail"),
        ("docs.google.com", "Google Docs"),
        ("sheets.google.com", "Google Sheets"),
        ("slides.google.com", "Google Slides"),
        ("drive.google.com", "Google Drive"),
        ("calendar.google.com", "Google Calendar"),
        ("messages.google.com", "Google Messages"),
        ("gemini.google.com", "Gemini"),
        ("google.com", "Google"),
        ("outlook.office.com", "Outlook"),
        ("outlook.live.com", "Outlook"),
        ("mail.proton.me", "Proton Mail"),
        ("youtube.com", "YouTube"),
        ("youtu.be", "YouTube"),
        ("github.com", "GitHub"),
        ("x.com", "X"),
        ("twitter.com", "X"),
        ("linkedin.com", "LinkedIn"),
        ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"),
        ("web.whatsapp.com", "WhatsApp"),
        ("whatsapp.com", "WhatsApp"),
        ("web.telegram.org", "Telegram"),
        ("messenger.com", "Messenger"),
        ("slack.com", "Slack"),
        ("discord.com", "Discord"),
        ("claude.ai", "Claude"),
        ("chatgpt.com", "ChatGPT"),
        ("chat.openai.com", "ChatGPT"),
        ("perplexity.ai", "Perplexity"),
        ("notion.so", "Notion"),
        ("notion.site", "Notion"),
        ("figma.com", "Figma"),
        ("stackoverflow.com", "Stack Overflow"),
        ("amazon.com", "Amazon"),
        ("vimeo.com", "Vimeo"),
        ("bsky.app", "Bluesky"),
        ("threads.net", "Threads")
    ]
}

// MARK: - LiveContextFormat
// Small deterministic string/number utilities shared by the builders, the
// formatter, and the fingerprint. No heuristics live here — only formatting.

enum LiveContextFormat {

    /// "2:14", "1:02:03", "" when unknown.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Host of a URL string, lowercased and without "www.".
    static func host(of url: String?) -> String? {
        guard let url, let components = URLComponents(string: url),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static func path(of url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        return components.path
    }

    /// URL reduced to what identifies the PAGE: scheme+host+path, plus only the
    /// query parameters that change which content is shown. Tracking params and
    /// fragments are dropped so the fingerprint doesn't churn on every click.
    static func canonicalURL(_ url: String?) -> String? {
        guard let url, var components = URLComponents(string: url) else { return url?.lowercased() }
        components.fragment = nil
        let meaningful: Set<String> = ["v", "q", "id", "p", "page", "thread", "channel", "search_query"]
        if let items = components.queryItems {
            let kept = items.filter { meaningful.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return (components.string ?? url).lowercased()
    }

    /// The filename in a window title like "HolmesAgent.swift — holmes" or
    /// "index.ts - my-project". Returns nil when the title names no file.
    static func fileName(inWindowTitle title: String) -> String? {
        let pattern = "[A-Za-z0-9_+\\-.]+\\.(swift|ts|tsx|js|jsx|py|rb|go|rs|java|kt|c|cc|cpp|h|hpp|m|mm|cs|php|sh|zsh|json|ya?ml|toml|md|html|css|scss|sql)"
        guard let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(title[range])
    }

    /// The last shell command visible in terminal AX text — the line after the
    /// final prompt marker. Literal text, never a guess about what it did.
    static func lastShellCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.reversed() {
            for marker in ["$ ", "% ", "› ", "❯ "] {
                if let range = line.range(of: marker) {
                    let command = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if command.count >= 2 { return String(command.prefix(120)) }
                }
            }
        }
        return nil
    }

    /// FNV-1a — a hash that is IDENTICAL across launches, unlike Swift's seeded
    /// `hashValue`. The fingerprint is compared against persisted values, so it
    /// must be stable over time.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Bridging from ScreenEngine

extension FocusedField {
    /// Lifts ScreenEngine's Accessibility focus reading into the LiveContext
    /// vocabulary, so callers can write:
    ///   LiveContextBuilder.fromAccessibility(app:window:axText:
    ///       focused: result.focused.map(FocusedField.init))
    init(_ focused: FocusedContext) {
        let selection = focused.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // In a read-only control the SELECTION is the meaningful content — and
        // fromAccessibility promotes a non-editable field's value into
        // LiveContext.selection, so carry it across rather than dropping it.
        let value = (!focused.isEditable && !selection.isEmpty) ? focused.selectedText : focused.value
        self.init(role: focused.role,
                  label: focused.label.isEmpty ? focused.roleDescription : focused.label,
                  value: value,
                  isEditable: focused.isEditable)
    }
}

// MARK: - String helper

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
