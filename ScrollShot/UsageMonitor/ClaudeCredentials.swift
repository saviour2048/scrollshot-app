import Foundation
import Security
import LocalAuthentication

/// Reads the Claude Code OAuth access token from the local machine — **read-only**.
///
/// Mirrors how CodexBar reaches it (it works where Claude Code stores creds in the
/// standard places):
///   1. `~/.claude/.credentials.json` (Linux / headless location)
///   2. `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
///      — the login-keychain item Claude Code writes on macOS. Shelling out to the
///      trusted system tool avoids the cross-app keychain ACL prompt.
///   3. `SecItemCopyMatching` by service, no-UI (background-safe fallback).
///
/// We never refresh or write the token back, so we can't rotate Claude Code's
/// refresh token out from under it. Expired → caller tells the user to open
/// Claude Code (which refreshes it).
enum ClaudeCredentials {
    struct Token {
        let accessToken: String
        let expiresAt: Date?
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    enum CredentialError: LocalizedError {
        case notFound
        case expired
        var errorDescription: String? {
            switch self {
            case .notFound: return "未找到 Claude 登录凭据。请在偏好设置里登录 Claude,或在本机打开并登录一次订阅版 Claude Code。"
            case .expired:  return "Claude 登录已过期。打开 Claude Code 用一次即可刷新,或在偏好设置里重新登录。"
            }
        }
    }

    static let keychainService = "Claude Code-credentials"

    static func current() async throws -> Token {
        // 1. ScrollShot's own logged-in token (Settings → 登录 Claude), refreshed if needed.
        //    A failure here (expired, refresh error, rate limit) must NOT block the
        //    fallback below — otherwise a dead own-token kills the whole pipeline.
        if let token = try? await ownToken() { return token }
        // 2. Fall back to reading Claude Code's own token, where it's readable.
        guard let raw = readRawJSON() else { throw CredentialError.notFound }
        guard let token = parse(raw) else { throw CredentialError.notFound }
        if token.isExpired { throw CredentialError.expired }
        return token
    }

    /// Our own OAuth token from the login flow. Refreshes if expiring within 60s.
    private static func ownToken() async throws -> Token? {
        guard var s = ClaudeOAuthStore.load() else { return nil }
        let expiry = s.expiresAt.map { Date(timeIntervalSince1970: $0) }
        if let expiry, expiry <= Date().addingTimeInterval(60) {
            guard let rt = s.refreshToken else {
                ClaudeOAuthStore.clear()
                throw CredentialError.expired
            }
            // Back off after a failed refresh so we don't hammer the token endpoint
            // on every poll cycle (repeated attempts trigger HTTP 429 rate limiting).
            if let last = lastRefreshFailure, Date().timeIntervalSince(last) < 300 {
                throw CredentialError.expired
            }
            do {
                let refreshed = try await ClaudeLogin.refresh(refreshToken: rt)
                s.accessToken = refreshed.accessToken
                if let nrt = refreshed.refreshToken { s.refreshToken = nrt }
                if let ein = refreshed.expiresIn {
                    s.expiresAt = Date().addingTimeInterval(ein).timeIntervalSince1970
                }
                ClaudeOAuthStore.save(s)
                lastRefreshFailure = nil
                return Token(accessToken: s.accessToken,
                             expiresAt: s.expiresAt.map { Date(timeIntervalSince1970: $0) })
            } catch {
                lastRefreshFailure = Date()
                // Refresh token revoked/rotated → the stored login is dead, drop it
                // so we stop trying and the caller falls back to Claude Code's token.
                if ClaudeLogin.isInvalidGrant(error) { ClaudeOAuthStore.clear() }
                throw error
            }
        }
        return Token(accessToken: s.accessToken, expiresAt: expiry)
    }

    /// Last time a token-refresh attempt failed (for backoff, main-thread only).
    private static var lastRefreshFailure: Date?

    // MARK: Sources (tried in order)

    private static func readRawJSON() -> Data? {
        readFile() ?? readViaSecurityCLI() ?? readViaFramework()
    }

    private static func readFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    /// `security find-generic-password -s "Claude Code-credentials" -w` → JSON on stdout.
    private static func readViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text.data(using: .utf8)
    }

    /// Security.framework query, configured NOT to show a UI prompt (so a denied
    /// item fails fast instead of blocking a background refresh).
    private static func readViaFramework() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    // MARK: Parsing — `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms> } }`

    private static func parse(_ data: Data) -> Token? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { return nil }

        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return Token(accessToken: access, expiresAt: expiresAt)
    }
}
