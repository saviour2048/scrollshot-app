import Foundation

/// OpenCode Go 套餐用量 —— 直接复用 opencode CLI 的本地 API Key
/// (`~/.local/share/opencode/auth.json` 的 `opencode-go` 条目),探测官方
/// `GET https://opencode.ai/zen/go/v1/usage`(三个窗口只用百分比,无金额)。
/// 与 CodexUsage 同形:零配置、解析宽容、字段缺失不炸。
enum OpenCodeSettings {
    static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    /// 已配置 = auth.json 存在且 `opencode-go` 条目有非空 key。
    static var isConfigured: Bool { loadAuth() != nil }

    static func loadAuth(from url: URL = authFileURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    /// 设置页展示用的打码 key(如 `oc_sk_…yeWZ`),读取失败返回 nil。
    static var maskedKey: String? {
        guard let key = loadAuth() else { return nil }
        guard key.count > 10 else { return key }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

/// 一个套餐限流窗口(rolling = 5 小时滚动,weekly = 周,monthly = 月)。
struct OpenCodeWindowUsage: Equatable {
    var usedPercent: Double
    var resetAt: Date?
    /// true = 接口报 rate-limited,此时 usedPercent 已强制为 100。
    var rateLimited: Bool = false

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// 解析后的 OpenCode Go 用量快照。
struct OpenCodeUsageSnapshot: Equatable {
    var rolling: OpenCodeWindowUsage?
    var weekly: OpenCodeWindowUsage?
    var monthly: OpenCodeWindowUsage?
}

enum OpenCodeUsageFetcher {
    enum OpenCodeError: LocalizedError, Equatable {
        case noAuth, http(Int), parse
        var errorDescription: String? {
            switch self {
            case .noAuth: return "未检测到 OpenCode Go key:请先在终端完成 opencode 登录(opencode-go)"
            case .http(let c):
                if c == 401 { return "OpenCode key 无效或已过期,请在终端重新登录 opencode" }
                return "OpenCode 接口返回 \(c)"
            case .parse: return "OpenCode 用量响应无法解析(接口格式可能已变更)"
            }
        }
    }

    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch() async throws -> OpenCodeUsageSnapshot {
        guard let key = OpenCodeSettings.loadAuth() else { throw OpenCodeError.noAuth }
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenCodeError.http(http.statusCode)
        }
        return try parse(data: data)
    }

    /// 纯解析(可单测)。字段缺失宽容;三个窗口全解析不出来才算格式变更。
    /// 实测响应(2026-11-04,真实 key):
    /// {"usage":{"rolling":{"status":"ok","percent":71,"resetsAt":"2026-11-04T12:31:30.000Z"},
    ///           "weekly":{…},"monthly":{…}}}
    static func parse(data: Data) throws -> OpenCodeUsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else {
            throw OpenCodeError.parse
        }
        let snap = OpenCodeUsageSnapshot(
            rolling: window(usage["rolling"]),
            weekly: window(usage["weekly"]),
            monthly: window(usage["monthly"]))
        guard snap.rolling != nil || snap.weekly != nil || snap.monthly != nil else {
            throw OpenCodeError.parse
        }
        return snap
    }

    private static func window(_ any: Any?) -> OpenCodeWindowUsage? {
        guard let d = any as? [String: Any], let percent = num(d["percent"]) else { return nil }
        let rateLimited = (d["status"] as? String) == "rate-limited"
        return OpenCodeWindowUsage(
            usedPercent: rateLimited ? 100 : max(0, min(100, percent)),
            resetAt: isoDate(d["resetsAt"]),
            rateLimited: rateLimited)
    }

    /// String-or-number tolerant numeric read(与 CodexUsage 同款)。
    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// ISO8601(实测带毫秒,如 2026-11-04T12:31:30.000Z;宽容无毫秒写法)。
    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
