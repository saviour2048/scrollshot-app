import Foundation
import Security
import CryptoKit

/// "Login with Claude" — OAuth 2.0 + PKCE against the public Claude Code client,
/// so ScrollShot can read the user's own subscription usage even when Claude
/// Code's token isn't readable locally.
///
/// Flow: open `claude.ai/oauth/authorize` in the browser → user authorizes →
/// Anthropic shows an authorization code (`code#state`) → user pastes it back →
/// we exchange it for tokens and store them in OUR OWN keychain item (never
/// touching Claude Code's). This is an unofficial use of Claude Code's public
/// client_id; it can change or be restricted by Anthropic without notice.
enum ClaudeLogin {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scope = "org:create_api_key user:profile user:inference"
    private static let authorizeBase = "https://claude.ai/oauth/authorize"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    // MARK: PKCE

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The browser URL to open. `state` is the verifier (per the canonical flow).
    static func authorizeURL(verifier: String) -> URL {
        var c = URLComponents(string: authorizeBase)!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier)
        ]
        return c.url!
    }

    // MARK: Token exchange / refresh

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// Exchanges the pasted `code#state` and stores the tokens.
    static func exchange(pastedCode raw: String, verifier: String) async throws {
        let parts = raw.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? raw
        let state = parts.count > 1 ? parts[1] : verifier
        let token = try await postToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
        ClaudeOAuthStore.save(from: token)
    }

    static func refresh(refreshToken: String) async throws -> TokenResponse {
        try await postToken([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])
    }

    private static func postToken(_ body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ScrollShot/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw err("登录失败:无响应。")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            var info: [String: Any] = [NSLocalizedDescriptionKey:
                "登录失败(HTTP \(http.statusCode))。请重试,并确认粘贴的授权码完整(含 # 后半段)。"]
            if body.contains("invalid_grant") { info["ClaudeLoginInvalidGrant"] = true }
            throw NSError(domain: "ClaudeLogin", code: http.statusCode, userInfo: info)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// True if the token endpoint rejected the grant (`invalid_grant`) — the
    /// stored refresh token is revoked/rotated and the login is unrecoverable.
    static func isInvalidGrant(_ error: Error) -> Bool {
        (error as NSError).userInfo["ClaudeLoginInvalidGrant"] as? Bool == true
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "ClaudeLogin", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Stores ScrollShot's own Claude OAuth tokens in our own login-keychain item.
/// (Our app created it, so reading/writing needs no prompt and never touches
/// Claude Code's credentials.)
enum ClaudeOAuthStore {
    private static let service = "com.scrollshot.claude-oauth"
    private static let account = "default"

    struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Double?   // epoch seconds
    }

    static var isLoggedIn: Bool { load() != nil }

    static func save(from token: ClaudeLogin.TokenResponse) {
        var s = Stored(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: nil)
        if let ein = token.expiresIn {
            s.expiresAt = Date().addingTimeInterval(ein).timeIntervalSince1970
        }
        save(s)
    }

    static func save(_ s: Stored) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return s
    }

    static func clear() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
    }
}
