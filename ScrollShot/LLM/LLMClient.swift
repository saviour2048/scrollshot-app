import Foundation
import Security

/// Settings for the OpenAI-compatible chat provider. Base URL + model live in
/// UserDefaults (synced via iCloud like other prefs); the API key lives in the
/// KEYCHAIN only — never in defaults, never synced, never in the settings file.
enum LLMSettings {
    private static let d = UserDefaults.standard

    /// e.g. "https://api.deepseek.com" or "https://api.openai.com/v1"
    static var baseURL: String {
        get { d.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com" }
        set { d.set(newValue, forKey: "llm.baseURL") }
    }

    static var model: String {
        get { d.string(forKey: "llm.model") ?? "deepseek-flash" }
        set { d.set(newValue, forKey: "llm.model") }
    }

    static var apiKey: String {
        get { KeychainStore.load(account: "llm.apiKey") ?? "" }
        set { KeychainStore.save(newValue, account: "llm.apiKey") }
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    /// Normalized ".../chat/completions" endpoint. Accepts base URLs with or
    /// without a trailing "/v1".
    static var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/v1") && !base.contains("/v1/") {
            // DeepSeek accepts both; OpenAI & most compatibles require /v1.
            base += "/v1"
        }
        return URL(string: base + "/chat/completions")
    }
}

/// Minimal generic-password Keychain wrapper (non-sandboxed app, login keychain).
enum KeychainStore {
    private static let service = "com.scrollshot.app"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One message in OpenAI wire format.
struct LLMMessage: Codable {
    let role: String      // "user" / "assistant" / "system"
    let content: String
}

/// Streaming client for any OpenAI-compatible /chat/completions endpoint.
enum LLMClient {
    enum LLMError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没配置 API Key — 打开 偏好设置 ▸ AI 对话 填写。"
            case .badURL: return "Base URL 无效,请检查 偏好设置 ▸ AI 对话。"
            case .http(let code, let body): return "接口返回 \(code):\(body.prefix(300))"
            }
        }
    }

    /// Send the whole conversation; yields content deltas as they stream in.
    static func stream(messages: [LLMMessage]) async throws -> AsyncThrowingStream<String, Error> {
        guard LLMSettings.isConfigured else { throw LLMError.notConfigured }
        guard let url = LLMSettings.endpoint else { throw LLMError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(LLMSettings.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": LLMSettings.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 500 { break }
            }
            throw LLMError.http(http.statusCode, bodyText)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty
                        else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
