import Foundation

// MARK: - LocalModelEngine
// Priority: Apple MLX (via mlx-swift or bundled Core ML) → Ollama → heuristics only
// For v1 we implement Ollama (localhost) as the active path since MLX Swift
// requires SPM packages. Core ML / MLX integration is stubbed and ready to swap in.

enum ModelBackend: String {
    case ollama  = "Ollama (localhost)"
    case none    = "Heuristics only"
}

@MainActor
final class LocalModelEngine {
    static let shared = LocalModelEngine()

    private(set) var activeBackend: ModelBackend = .none
    private(set) var isAvailable: Bool = false

    private let ollamaBase = "http://127.0.0.1:11434"
    private let preferredModel = "llama3.2:3b"    // small + fast, ~2GB
    private let fallbackModel  = "mistral:7b-instruct-q4_0"

    private init() {}

    // MARK: - Probe available backends

    func probe() async {
        if await probeOllama() {
            activeBackend = .ollama
            isAvailable = true
            print("[Holmes] LocalModel: Ollama available — \(activeBackend.rawValue)")
            return
        }
        activeBackend = .none
        isAvailable = false
        print("[Holmes] LocalModel: No LLM backend available — heuristics only")
    }

    // MARK: - Generate

    /// Sends a prompt and streams the response back via the callback.
    func generate(prompt: String, onToken: @escaping (String) -> Void) async -> String {
        switch activeBackend {
        case .ollama:
            return await generateOllama(prompt: prompt, onToken: onToken)
        case .none:
            return ""
        }
    }

    /// Non-streaming version — returns full response string.
    func generate(prompt: String) async -> String {
        await generate(prompt: prompt, onToken: { _ in })
    }

    // MARK: - Ollama

    private func probeOllama() async -> Bool {
        let endpoints = ["\(ollamaBase)/api/tags", "http://localhost:11434/api/tags"]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                // Accept any running Ollama regardless of which models are pulled
                print("[Holmes] Ollama reachable at \(endpoint)")
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    let names = models.compactMap { $0["name"] as? String }
                    print("[Holmes] Ollama models: \(names)")
                }
                return true
            } catch {
                print("[Holmes] Ollama probe failed at \(endpoint): \(error.localizedDescription)")
            }
        }
        return false
    }

    private func activeOllamaModel() async -> String {
        guard let url = URL(string: "\(ollamaBase)/api/tags") else { return preferredModel }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return preferredModel }

        let names = models.compactMap { $0["name"] as? String }
        // Prefer smallest capable model
        for prefix in ["llama3.2:3b", "llama3.2", "llama3", "phi3", "phi", "mistral", "gemma"] {
            if let match = names.first(where: { $0.hasPrefix(prefix) }) { return match }
        }
        return names.first ?? preferredModel
    }

    private func generateOllama(prompt: String, onToken: @escaping (String) -> Void) async -> String {
        let model = await activeOllamaModel()
        guard let url = URL(string: "\(ollamaBase)/api/generate") else { return "" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true,
            "options": [
                "num_predict": 300,
                "temperature": 0.3,
                "top_p": 0.9
            ]
        ]
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
