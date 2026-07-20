import Foundation
import AppKit
import CoreGraphics

// MARK: - LocalModelEngine
// Ollama (localhost) client — the always-on, private, on-device brain used for
// context detection, trigger classification, and the no-API-key fallback.
//
// Speed matters more than anything here (this runs on every context change):
//   • the model is chosen ONCE at probe() and cached — no /api/tags round-trip
//     per generation (that alone added ~50-100ms to every call)
//   • keep_alive keeps the model resident in RAM between calls, and probe()
//     fires a warmup load so the FIRST detection isn't a cold multi-second start
//   • format:"json" mode constrains output for structured extraction, which is
//     both faster (no rambling) and reliably parseable
// Preference order starts with Gemma (gemma4 auto-selected the day it ships;
// gemma3 today) — noticeably more accurate than llama3.2 at the same speed class.

enum ModelBackend: String {
    case ollama  = "Ollama (localhost)"
    case none    = "Heuristics only"
}

@MainActor
final class LocalModelEngine {
    static let shared = LocalModelEngine()

    private(set) var activeBackend: ModelBackend = .none
    private(set) var isAvailable: Bool = false
    /// The Ollama model chosen at probe() — cached so generate() never re-lists.
    private(set) var selectedModel: String?
    /// Whether the selected model can see images (gemma3, llava, *-vision, …).
    /// When true, the deep-context path sends the actual screenshot for
    /// layout-aware understanding OCR can't provide.
    private(set) var visionAvailable: Bool = false

    /// Model-name prefixes/fragments known to be vision-capable in Ollama.
    private let visionModelMarkers = ["gemma3", "llava", "-vision", "vision-",
                                      "minicpm-v", "moondream", "bakllava",
                                      "qwen2-vl", "qwen2.5vl", "qwen2.5-vl",
                                      "granite3.2-vision", "mistral-small3"]

    private let ollamaBase = "http://localhost:11434"
    /// Keep the model loaded between the 3s perception ticks — a cold load is
    /// multi-second; a resident model responds in well under a second.
    private let keepAlive = "30m"
    /// Best-first: Gemma (newest first, so gemma4 wins automatically once
    /// pulled), then the previous defaults as fallbacks.
    private let modelPreference = ["gemma4", "gemma3n", "gemma3", "llama3.2:3b",
                                   "llama3.2", "llama3", "phi3", "phi", "mistral"]

    /// Label for the main panel, e.g. "Ollama (gemma3:4b)".
    var backendLabel: String {
        if case .ollama = activeBackend, let model = selectedModel {
            return "Ollama (\(model)\(visionAvailable ? " · vision" : ""))"
        }
        return activeBackend.rawValue
    }

    private init() {}

    // MARK: - Probe available backends

    func probe() async {
        if let model = await pickOllamaModel() {
            selectedModel = model
            let lower = model.lowercased()
            let marked = visionModelMarkers.contains { lower.contains($0) }
            // Some models carry a vision-family name but are text-only variants —
            // notably Gemma 3 is multimodal only at 4B/12B/27B; gemma3:1b and the
            // 270m embedding variant cannot see. Don't send them images.
            let textOnlyVariant = lower.hasPrefix("gemma3:1b") || lower.contains("gemma3:270m")
            visionAvailable = marked && !textOnlyVariant
            activeBackend = .ollama
            isAvailable = true
            print("[Holmes] LocalModel: Ollama available — using \(model)\(visionAvailable ? " (vision ✓)" : "")")
            warmUp(model: model)
            return
        }
        selectedModel = nil
        visionAvailable = false
        activeBackend = .none
        isAvailable = false
        print("[Holmes] LocalModel: No LLM backend available — heuristics only")
    }

    /// Loads the model into memory now so the first real detection is instant.
    /// An /api/generate call with no prompt is Ollama's documented load request.
    private func warmUp(model: String) {
        Task {
            guard let url = URL(string: "\(ollamaBase)/api/generate") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "keep_alive": keepAlive
            ])
            _ = try? await URLSession.shared.data(for: request)
            print("[Holmes] LocalModel: \(model) warmed up and resident")
        }
    }

    // MARK: - Generate

    /// Sends a prompt and streams the response back via the callback.
    /// - asJSON: constrain output to a single JSON object (Ollama format mode) —
    ///   use for structured extraction; faster and reliably parseable.
    /// - maxTokens: response budget; keep small for classification-style calls.
    /// - images: base64-encoded images to attach (vision). Ignored unless the
    ///   selected model is vision-capable (visionAvailable).
    func generate(prompt: String,
                  maxTokens: Int = 300,
                  asJSON: Bool = false,
                  images: [String] = [],
                  onToken: @escaping (String) -> Void) async -> String {
        switch activeBackend {
        case .ollama:
            return await generateOllama(prompt: prompt, maxTokens: maxTokens,
                                        asJSON: asJSON, images: images, onToken: onToken)
        case .none:
            return ""
        }
    }

    /// Non-streaming version — returns full response string.
    func generate(prompt: String, maxTokens: Int = 300, asJSON: Bool = false,
                  images: [String] = []) async -> String {
        await generate(prompt: prompt, maxTokens: maxTokens, asJSON: asJSON,
                       images: images, onToken: { _ in })
    }

    // MARK: - Vision image encoding

    /// Downscales a screenshot and encodes it as base64 JPEG for the vision
    /// model. ~1024px longest edge keeps detail readable while staying fast.
    nonisolated static func encodeForVision(_ cgImage: CGImage,
                                            maxDimension: CGFloat = 1024,
                                            quality: CGFloat = 0.6) -> String? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        guard w > 1, h > 1 else { return nil }
        let scale = min(1, maxDimension / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]) else { return nil }
        return jpeg.base64EncodedString()
    }

    // MARK: - Ollama

    /// One tags fetch, best preferred model wins. nil when Ollama is down or
    /// has no models pulled.
    private func pickOllamaModel() async -> String? {
        guard let url = URL(string: "\(ollamaBase)/api/tags") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }

        let names = models.compactMap { $0["name"] as? String }
        guard !names.isEmpty else { return nil }
        for prefix in modelPreference {
            if let match = names.first(where: { $0.hasPrefix(prefix) }) { return match }
        }
        return names.first
    }

    private func generateOllama(prompt: String,
                                maxTokens: Int,
                                asJSON: Bool,
                                images: [String],
                                onToken: @escaping (String) -> Void) async -> String {
        // Model was cached at probe(); if probe never succeeded we wouldn't be
        // here (activeBackend gates entry), but re-pick defensively just in case.
        var model = selectedModel
        if model == nil {
            model = await pickOllamaModel()
            selectedModel = model
        }
        guard let model, let url = URL(string: "\(ollamaBase)/api/generate") else { return "" }

        // Only attach images to a vision-capable model — a text-only model errors
        // on an images field.
        let sendImages = !images.isEmpty && visionAvailable

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = sendImages ? 120 : 60

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true,
            "keep_alive": keepAlive,
            "options": [
                "num_predict": maxTokens,
                "temperature": 0.3,
                "top_p": 0.9
            ]
        ]
        if asJSON { body["format"] = "json" }
        if sendImages { body["images"] = images }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var fullResponse = ""
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["response"] as? String
                else { continue }

                fullResponse += token
                await MainActor.run { onToken(token) }

                if let done = json["done"] as? Bool, done { break }
            }
        } catch {
            print("[Holmes] Ollama generate error: \(error)")
        }
        return fullResponse
    }
}
