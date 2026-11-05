import Foundation

/// Codex(ChatGPT 订阅)用量 —— 直接复用 codex CLI 的本地登录凭据
/// (`~/.codex/auth.json`),探测 `GET {backend}/wham/usage`(与 codex CLI 同一接口)。
/// 与 KimiUsage 同形:解析对 number/string 宽容,字段缺失不炸。
enum CodexSettings {
    static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    /// 已登录 = auth.json 存在、auth_mode 为 chatgpt、access_token/account_id 非空。
    static var isConfigured: Bool { loadAuth() != nil }

    /// 登录邮箱:优先从 auth.json 里 id_token 的 JWT payload 解析;解析不到返回 nil
    /// (UI 退而显示用量接口返回的 email / plan)。
    static var accountEmail: String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return jwtEmail(idToken)
    }

    static func loadAuth(from url: URL = authFileURL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["auth_mode"] as? String) == "chatgpt",
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty else { return nil }
        return CodexAuth(accessToken: access,
                         accountID: account,
                         refreshToken: tokens["refresh_token"] as? String ?? "")
    }

    /// base64url 解 JWT 的 payload 取 email;codex 的 id_token 里 email 也可能
    /// 嵌在 https://api.openai.com/profile 下。
    private static func jwtEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let email = payload["email"] as? String { return email }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any] {
            return profile["email"] as? String
        }
        return nil
    }
}

/// auth.json 里本次请求需要的三个字段。
struct CodexAuth: Equatable {
    var accessToken: String
    var accountID: String
    var refreshToken: String
}

/// 一个限速窗口(primary = 5 小时,secondary = 7 天)。
struct CodexWindowUsage: Equatable {
    var usedPercent: Double
    var resetAt: Date?
    var windowSeconds: Int?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// 解析后的 Codex 订阅用量快照。
struct CodexSnapshot: Equatable {
    var planType: String?
    var primary: CodexWindowUsage?
    var secondary: CodexWindowUsage?
    var hasCredits: Bool = false
    var creditsUnlimited: Bool = false
    var creditsBalance: String?
    var email: String?
}

enum CodexUsageFetcher {
    enum CodexError: LocalizedError, Equatable {
        case noAuth, http(Int), parse
        var errorDescription: String? {
            switch self {
            case .noAuth: return "未检测到 Codex 登录:请先在终端运行 codex 完成登录"
            case .http(let c):
                if c == 401 { return "Codex 登录已过期,请在终端重新运行 codex 登录" }
                return "Codex 接口返回 \(c)"
            case .parse: return "Codex 用量响应无法解析(接口格式可能已变更)"
            }
        }
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    // codex CLI 的公开 OAuth client_id 与 UA(服务端按 UA 识别客户端)。
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let userAgent = "codex_cli_rs/0.55.0"

    static func fetch() async throws -> CodexSnapshot {
        guard let auth = CodexSettings.loadAuth() else { throw CodexError.noAuth }
        do {
            return try await request(token: auth.accessToken, accountID: auth.accountID)
        } catch CodexError.http(let code) where code == 401 {
            // access_token 过期:用 refresh_token 换新后重试一次
            try await refreshTokens(auth: auth)
            guard let fresh = CodexSettings.loadAuth() else { throw CodexError.noAuth }
            return try await request(token: fresh.accessToken, accountID: fresh.accountID)
        }
    }

    private static func request(token: String, accountID: String) async throws -> CodexSnapshot {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CodexError.http(http.statusCode)
        }
        return try parse(data: data)
    }

    /// POST refresh_token 换新,成功后写回 auth.json。
    private static func refreshTokens(auth: CodexAuth) async throws {
        guard !auth.refreshToken.isEmpty else { throw CodexError.http(401) }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: auth.refreshToken),
        ]
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CodexError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = obj["access_token"] as? String, !newAccess.isEmpty else {
            throw CodexError.parse
        }
        try writeBackTokens(accessToken: newAccess,
                            refreshToken: obj["refresh_token"] as? String,
                            idToken: obj["id_token"] as? String)
    }

    /// 重新读 auth.json、只更新 tokens 下的对应键、原子写回 ——
    /// 避免覆盖 codex CLI 并发刷新时写入的其它字段。
    private static func writeBackTokens(accessToken: String, refreshToken: String?, idToken: String?) throws {
        let url = CodexSettings.authFileURL
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.parse
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    /// 纯解析(可单测)。字段缺失宽容;两个窗口都解析不出来才算格式变更。
    static func parse(data: Data) throws -> CodexSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.parse
        }
        var snap = CodexSnapshot()
        snap.planType = obj["plan_type"] as? String
        snap.email = obj["email"] as? String
        if let rl = obj["rate_limit"] as? [String: Any] {
            snap.primary = window(rl["primary_window"])
            snap.secondary = window(rl["secondary_window"])
        }
        if let credits = obj["credits"] as? [String: Any] {
            snap.hasCredits = (credits["has_credits"] as? Bool) ?? false
            snap.creditsUnlimited = (credits["unlimited"] as? Bool) ?? false
            snap.creditsBalance = credits["balance"] as? String
        }
        guard snap.primary != nil || snap.secondary != nil else { throw CodexError.parse }
        return snap
    }

    private static func window(_ any: Any?) -> CodexWindowUsage? {
        guard let d = any as? [String: Any], let used = num(d["used_percent"]) else { return nil }
        return CodexWindowUsage(
            usedPercent: max(0, min(100, used)),
            resetAt: epoch(d["reset_at"]),
            windowSeconds: num(d["limit_window_seconds"]).map(Int.init)
        )
    }

    /// String-or-number tolerant numeric read.
    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// epoch 秒(兼容毫秒)。
    private static func epoch(_ any: Any?) -> Date? {
        guard let v = num(any), v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
    }
}
