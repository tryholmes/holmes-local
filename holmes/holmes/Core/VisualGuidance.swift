// Approach derived from OpenClicky (MIT, © 2025 Jason Kneen): the model→visual-
// guidance bridge — asking the model to answer a question about the screen AND
// return draw-on-screen annotations in screenshot-pixel space, then parsing them
// into overlay shapes (CompanionManager+PointTagParsing.swift's POINT/RECT/SCRIBBLE
// parsing, OpenClickyVisualGuidanceOverlayModels.swift's shape model). Adapted to
// Holmes: strict-JSON (grammar-constrained by Ollama's `format`) instead of
// inline tags, driven by OllamaClient + WindowCapture. See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

// MARK: - VisualGuidance

/// Captures the screen, asks the local vision model to answer the user's spoken
/// question about what's on screen, and — when pointing at specific UI would help
/// — to return annotations in the DECLARED SCREENSHOT-PIXEL space (top-left
/// origin; or the 0-1000 grid when OllamaConfig.coordinateSpace says so). The caller
/// speaks `Result.spokenAnswer` (TTS) and hands `Result.annotations` +
/// `Result.capture` to `VisualGuidanceOverlay.show(_:mappedFrom:)`.
enum VisualGuidance {

    struct Result {
        /// The concise, conversational answer to speak aloud.
        let spokenAnswer: String
        /// Draw-on-screen annotations. Points are in the MODEL's coordinate space
        /// (screenshot pixels, or the 0-1000 grid) — the overlay maps them through
        /// `WindowCapture.modelPointToGlobalAppKit`, which interprets that space.
        /// Sizes are already converted to screenshot pixels (the overlay scales
        /// them by points-per-pixel directly).
        let annotations: [GuidanceAnnotation]
        /// The exact capture the annotations were produced against. Required by
        /// `VisualGuidanceOverlay.show(_:mappedFrom:)` to map the model's pixel
        /// coordinates onto the physical display, so it travels with the result.
        let capture: ComputerUseCapture
    }

    /// Runs the full see → answer → (optionally) point pipeline. Returns `nil`
    /// when the local model isn't ready, the screen can't be captured, or the
    /// model produced neither a spoken answer nor a usable annotation.
    ///
    /// `context` is the deterministic live-context headline ("Terminal error in
    /// Ghostty"). It's passed to the model as ground truth so the answer stays
    /// pinned to THIS screen — the guard against a mismatched teach question
    /// (e.g. a meeting-notes playbook that fired on a code screen) dragging the
    /// answer off into a topic that isn't visible.
    static func answer(question: String, context: String = "") async -> Result? {
        guard OllamaConfig.isConfigured else { return nil }
        guard let capture = await WindowCapture.captureForModel() else { return nil }

        let system = systemPrompt(
            width: capture.screenshotWidthInPixels,
            height: capture.screenshotHeightInPixels,
            context: context
        )

        let raw: String
        do {
            // Grammar-constrained to `guidanceSchema`; the user is waiting with
            // the hotkey held, so this is .agent priority — never dropped as
            // .busy behind background enrichment.
            raw = try await OllamaClient.shared.complete(
                system: system,
                user: question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "What's on my screen, and where should I look?"
                    : question,
                maxTokens: 1200,
                asJSON: true,
                schema: guidanceSchema,
                imageBase64: capture.jpegBase64,
                priority: .agent
            )
        } catch {
            print("[Clicky] VisualGuidance failed — \(error.localizedDescription)")
            return nil
        }

        return parse(raw, capture: capture)
    }

    // MARK: - Schema

    /// The reply shape Ollama's grammar enforces. Every property of an
    /// objectSchema is REQUIRED, so the prompt tells the model to fill unused
    /// numeric fields with 0 and unused text with "" — the parser treats those
    /// as absent (`scribble` carries its points in `path`, `[]` when unused).
    private static let guidanceSchema: [String: Any] = OllamaClient.objectSchema([
        "answer": ["type": "string",
                   "description": "A concise, friendly SPOKEN answer (1-3 sentences, no markdown, no lists, no coordinates)."],
        "annotations": [
            "type": "array",
            "description": "Things to draw on screen; empty array when nothing is worth pointing at.",
            "items": OllamaClient.objectSchema([
                "kind": ["type": "string",
                         "enum": ["circle", "arrow", "highlight", "label", "scribble"],
                         "description": "circle: ring around x,y (its center). arrow: points at x,y. highlight: translucent box with top-left x,y and size w,h. label: a caption bubble beside x,y (text required). scribble: a freehand stroke through the points in path."],
                "x": ["type": "number", "description": "Horizontal coordinate in the stated coordinate space."],
                "y": ["type": "number", "description": "Vertical coordinate in the stated coordinate space."],
                "w": ["type": "number", "description": "Width (highlight; optional for circle). 0 when not used."],
                "h": ["type": "number", "description": "Height (highlight; optional for circle). 0 when not used."],
                "text": ["type": "string", "description": "Short on-screen label, 1-4 words. \"\" when none."],
                "path": ["type": "array",
                         "items": ["type": "array", "items": ["type": "number"]],
                         "description": "scribble only: 2-12 [x,y] points in the stated coordinate space. [] when not used."]
            ])
        ]
    ])

    // MARK: - System prompt

    private static func systemPrompt(width: Int, height: Int, context: String = "") -> String {
        let space = WindowCapture.coordinateSpaceDescription(width: width, height: height)
        let bounds = WindowCapture.modelCoordinateBounds(width: width, height: height)
        let grounding = context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

        GROUND TRUTH — what the user is actually doing right now: "\(context)". \
        This was read directly from the screen. Answer ONLY about what is genuinely \
        visible in THIS screenshot and consistent with that. If the question you were \
        handed doesn't match what's on screen, IGNORE the question and just help with \
        what's actually here. NEVER mention an app, document, meeting, message, or \
        topic that is not visibly present — no guessing, no carrying over from \
        elsewhere. When unsure what something is, say what you can see, not what you \
        assume.
        """
        return """
        You are Holmes, an AI buddy living on the user's Mac. You are looking at a \
        screenshot of the user's screen and answering a question they asked OUT LOUD.\(grounding)

        Reply with ONE JSON object, and nothing else — no prose, no code fences:
        {
          "answer": "a concise, friendly, SPOKEN answer (1-3 sentences, no markdown, \
        no lists, no coordinates — this is read aloud by text-to-speech)",
          "annotations": [ ... ]   // may be empty: []
        }

        Add annotations whenever pointing at specific on-screen UI helps the user \
        follow your answer (e.g. "click here", "it's up there", "this is the field"). \
        When you DO point at something, be GENEROUS and draw it richly — don't settle \
        for a single lonely ring. Draw a small CLUSTER that frames the subject: \
        typically a highlight box (or circle) AROUND the element, an arrow pointing \
        AT it, and a short label naming it — 2 to 4 complementary annotations working \
        together. Only leave the array empty for purely general questions where \
        nothing on screen is worth indicating.

        COORDINATE SPACE: \(space) Keep x within 0…\(Int(bounds.width)) and y within \
        0…\(Int(bounds.height)). Sizes (w, h) are in the same units.

        Every annotation has ALL SIX fields: "kind", "x", "y", "w", "h", "text". Put 0 in \
        a number you don't need and "" in a text you don't need. Kinds:
        {"kind":"circle","x":N,"y":N,"w":0,"h":0,"text":"optional short label"}
            circle the element — x,y is its CENTER. Put its size in "w"/"h" if known, else 0.
        {"kind":"arrow","x":N,"y":N,"w":0,"h":0,"text":"optional short label"}
            point an arrow AT x,y (the thing you're indicating).
        {"kind":"highlight","x":N,"y":N,"w":N,"h":N,"text":"optional short label"}
            translucent box over a region — x,y is its TOP-LEFT corner, w,h its size.
        {"kind":"label","x":N,"y":N,"w":0,"h":0,"text":"short caption"}
            a caption bubble beside x,y (text is required for this kind).

        Example: {"answer":"Click the blue Save button at the top right.","annotations":[\
        {"kind":"highlight","x":1100,"y":40,"w":120,"h":36,"text":"Save"},\
        {"kind":"arrow","x":1160,"y":58,"w":0,"h":0,"text":""}]}

        Labels are 1-4 words, drawn on-screen (NOT spoken). Point at the CENTER of \
        buttons/controls, not their edges. If nothing is worth pointing at, return \
        "annotations": [].
        """
    }

    // MARK: - Parsing (defensive)

    private static func parse(_ raw: String, capture: ComputerUseCapture) -> Result? {
        guard let object = extractJSONObject(raw) else {
            // Model ignored the JSON contract but may still have said something useful.
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? nil : Result(spokenAnswer: fallback, annotations: [], capture: capture)
        }

        let answer = (object["answer"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var annotations: [GuidanceAnnotation] = []
        if let rawAnnotations = object["annotations"] as? [[String: Any]] {
            for entry in rawAnnotations {
                if let annotation = annotation(from: entry, capture: capture) {
                    annotations.append(annotation)
                }
            }
        }

        // Generosity guarantee: the TEACH overlay should FRAME the subject, not
        // leave a single lonely ring. When the model pointed at exactly one thing,
        // add a complementary arrow aimed at that same spot so the user sees a
        // box/ring + arrow together. Points stay in the model's coordinate space
        // (the overlay maps them later) — this never touches the pixel→screen
        // coordinate math. The size is in screenshot pixels, so half of it is
        // taken back into model units before being added to the point.
        if annotations.count == 1, let sole = annotations.first,
           sole.kind == .circle || sole.kind == .highlight || sole.kind == .label {
            var tip = sole.point
            if sole.kind == .highlight, let size = sole.size {
                let half = WindowCapture.screenshotPixelsToModelPoint(
                    CGPoint(x: size.width / 2, y: size.height / 2),
                    width: capture.screenshotWidthInPixels, height: capture.screenshotHeightInPixels)
                tip = CGPoint(x: sole.point.x + half.x, y: sole.point.y + half.y)
            }
            annotations.append(GuidanceAnnotation(kind: .arrow, point: tip))
        }

        guard !answer.isEmpty || !annotations.isEmpty else { return nil }
        return Result(spokenAnswer: answer, annotations: annotations, capture: capture)
    }

    private static func annotation(from dict: [String: Any], capture: ComputerUseCapture) -> GuidanceAnnotation? {
        guard let rawKind = (dict["kind"] as? String)?.lowercased() else { return nil }

        let kind: GuidanceAnnotation.Kind
        switch rawKind {
        case "circle":                         kind = .circle
        case "arrow":                          kind = .arrow
        case "highlight", "rect", "rectangle", "box": kind = .highlight
        case "label", "caption":               kind = .label
        case "scribble", "draw", "path":       kind = .scribble
        default:                               return nil
        }

        let text = (dict["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if kind == .scribble {
            guard let path = parsePath(dict["path"]), path.count >= 2 else { return nil }
            let clamped = path.map { clampToScreenshot($0, capture) }
            return GuidanceAnnotation(kind: .scribble, point: clamped[0], text: text, path: clamped)
        }

        guard let x = number(dict["x"]), let y = number(dict["y"]) else { return nil }
        let point = clampToScreenshot(CGPoint(x: x, y: y), capture)

        // 0/0 (the schema's "not used" value) → no size. A real size is handed
        // to the overlay in screenshot pixels, whatever space the model spoke.
        var size: CGSize?
        if let w = number(dict["w"]), let h = number(dict["h"]), w > 0, h > 0 {
            let px = WindowCapture.modelPointToScreenshotPixels(CGPoint(x: w, y: h), in: capture)
            size = CGSize(width: px.x, height: px.y)
        }

        // A label with no caption is nothing to draw.
        if kind == .label, text == nil { return nil }

        return GuidanceAnnotation(kind: kind, point: point, size: size, text: text, path: nil)
    }

    // MARK: - Low-level helpers

    /// Clamps in the MODEL's coordinate space (pixels, or 0…1000 on the grid).
    private static func clampToScreenshot(_ point: CGPoint, _ capture: ComputerUseCapture) -> CGPoint {
        let bounds = WindowCapture.modelCoordinateBounds(
            width: capture.screenshotWidthInPixels, height: capture.screenshotHeightInPixels)
        return CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height)
        )
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func parsePath(_ any: Any?) -> [CGPoint]? {
        guard let array = any as? [Any] else { return nil }
        var points: [CGPoint] = []
        for element in array {
            if let pair = element as? [Any], pair.count >= 2,
               let x = number(pair[0]), let y = number(pair[1]) {
                points.append(CGPoint(x: x, y: y))
            } else if let dict = element as? [String: Any],
                      let x = number(dict["x"]), let y = number(dict["y"]) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points.isEmpty ? nil : points
    }

    /// Extracts the first balanced top-level `{...}` object, string-literal aware so
    /// braces inside the answer text don't throw off the brace counter. Handles the
    /// model wrapping its JSON in prose or code fences.
    private static func extractJSONObject(_ string: String) -> [String: Any]? {
        guard let start = string.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < string.endIndex {
            let character = string[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let slice = string[start...index]
                        guard let data = slice.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            return nil
                        }
                        return object
                    }
                }
            }
            index = string.index(after: index)
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
