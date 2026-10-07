import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, gemini

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Gemini" }
    var keyAccount: String { self == .claude ? "anthropic_api_key" : "gemini_api_key" }
    var keyPrefixHint: String { self == .claude ? "sk-ant-..." : "AIza..." }
    var consoleHint: String { self == .claude ? "console.anthropic.com" : "aistudio.google.com" }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let label: String
}

/// Suggested model ids. Providers rename models over time, so every id can also be typed by hand in Settings.
enum ModelCatalog {
    static let claude: [ModelOption] = [
        ModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
        ModelOption(id: "claude-opus-5-5", label: "Claude Opus 5.5"),
        ModelOption(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
        ModelOption(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
    ]
    static let gemini: [ModelOption] = [
        ModelOption(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
        ModelOption(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash"),
        ModelOption(id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash-Lite"),
    ]

    static func options(for provider: Provider) -> [ModelOption] {
        provider == .claude ? claude : gemini
    }
    static func defaultModel(for provider: Provider) -> String {
        provider == .claude ? "claude-sonnet-5-5" : "gemini-2.5-flash"
    }
}

struct ModelChoice: Codable, Hashable {
    var provider: Provider
    var model: String
}

/// Each job in the app can use a different model.
enum Role: String, Codable, CaseIterable, Identifiable {
    case extraction, marking, generation, verification

    var id: String { rawValue }
    var title: String {
        switch self {
        case .extraction: return "Reading papers"
        case .marking: return "Marking your work"
        case .generation: return "Writing new questions"
        case .verification: return "Checking answers"
        }
    }
    var detail: String {
        switch self {
        case .extraction: return "Reads the PDFs and pulls out every question and memo line. Needs strong PDF reading."
        case .marking: return "Reads your handwriting and marks it. Accuracy matters most here."
        case .generation: return "Writes new questions aimed at your weak skills."
        case .verification: return "Solves each new question independently. A different model family catches more errors."
        }
    }
    var defaultChoice: ModelChoice {
        switch self {
        case .verification: return ModelChoice(provider: .gemini, model: "gemini-2.5-flash")
        default: return ModelChoice(provider: .claude, model: "claude-sonnet-5-5")
        }
    }
}

enum Part {
    case text(String)
    case pdf(Data, cache: Bool)
    case image(Data)          // JPEG
}

/// Direct calls to the Claude and Gemini HTTP APIs. Keys come from the Keychain and go nowhere else.
final class LLMService {
    private let http: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 900
        http = URLSession(configuration: cfg)
    }

    static func hasKey(_ provider: Provider) -> Bool {
        (KeychainStore.get(provider.keyAccount) ?? "").isEmpty == false
    }

    func complete(_ choice: ModelChoice, system: String, parts: [Part], maxTokens: Int) async throws -> String {
        guard let key = KeychainStore.get(choice.provider.keyAccount), !key.isEmpty else {
            throw AppError.missingKey(choice.provider)
        }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                switch choice.provider {
                case .claude: return try await claude(key: key, model: choice.model, system: system, parts: parts, maxTokens: maxTokens)
                case .gemini: return try await gemini(key: key, model: choice.model, system: system, parts: parts, maxTokens: maxTokens)
                }
            } catch AppError.server(let code, let msg) {
                lastError = AppError.server(code, msg)
                if attempt == 0 && (code == 429 || code >= 500) {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                throw AppError.server(code, msg)
            }
        }
        throw lastError ?? AppError.message("The request failed.")
    }

    // MARK: Claude

    private func claude(key: String, model: String, system: String, parts: [Part], maxTokens: Int) async throws -> String {
        var content: [[String: Any]] = []
        for part in parts {
            switch part {
            case .text(let t):
                content.append(["type": "text", "text": t])
            case .pdf(let data, let cache):
                var block: [String: Any] = [
                    "type": "document",
                    "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()],
                ]
                if cache { block["cache_control"] = ["type": "ephemeral"] }
                content.append(block)
            case .image(let data):
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()],
                ])
            }
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.badResponse("Claude returned something unreadable.")
        }
        if (obj["stop_reason"] as? String) == "max_tokens" {
            throw AppError.message("The reply was cut off. Try a smaller piece of work.")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        var text = ""
        for b in blocks {
            if (b["type"] as? String) == "text", let t = b["text"] as? String { text += t }
        }
        return text
    }

    // MARK: Gemini

    private func gemini(key: String, model: String, system: String, parts: [Part], maxTokens: Int) async throws -> String {
        var gp: [[String: Any]] = []
        for part in parts {
            switch part {
            case .text(let t):
                gp.append(["text": t])
            case .pdf(let data, _):
                gp.append(["inline_data": ["mime_type": "application/pdf", "data": data.base64EncodedString()]])
            case .image(let data):
                gp.append(["inline_data": ["mime_type": "image/jpeg", "data": data.base64EncodedString()]])
            }
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": gp]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "maxOutputTokens": max(maxTokens, 16000),
            ],
        ]
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let data = try await send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.badResponse("Gemini returned something unreadable.")
        }
        guard let cands = obj["candidates"] as? [[String: Any]], let first = cands.first else {
            let reason = (obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw AppError.message("Gemini returned no answer" + (reason.map { " (\($0))." } ?? "."))
        }
        if (first["finishReason"] as? String) == "MAX_TOKENS" {
            throw AppError.message("The reply was cut off. Try a smaller piece of work.")
        }
        let content = first["content"] as? [String: Any]
        let pieces = content?["parts"] as? [[String: Any]] ?? []
        var text = ""
        for p in pieces { if let t = p["text"] as? String { text += t } }
        return text
    }

    // MARK: transport

    private func send(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await http.data(for: req)
        } catch {
            throw AppError.message("Network error: \(error.localizedDescription)")
        }
        let (data, resp) = result
        guard let h = resp as? HTTPURLResponse else { throw AppError.badResponse("No response from the model provider.") }
        if h.statusCode >= 400 { throw AppError.server(h.statusCode, LLMService.providerErrorText(data)) }
        return data
    }

    static func providerErrorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return SupabaseClient.errorText(data)
    }
}
