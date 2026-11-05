import Foundation

/// Kimi (Moonshot) "Kimi For Coding" usage — the same probe CodexBar's API
/// mode uses: `GET {base}/usages` with `Authorization: Bearer <key>`. Fields
/// arrive as strings OR numbers depending on gateway version, so parsing is
/// deliberately tolerant.
enum KimiSettings {
    static var apiKey: String {
        get { KeychainStore.load(account: "kimi.apiKey") ?? "" }
        set { KeychainStore.save(newValue, account: "kimi.apiKey") }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "kimi.baseURL") ?? "https://api.kimi.com" }
        set { UserDefaults.standard.set(newValue, forKey: "kimi.baseURL") }
    }

    static var isConfigured: Bool { !apiKey.isEmpty }
}

/// One usage window (weekly quota or the short rate-limit window).
struct KimiWindowUsage: Equatable {
    var limit: Double
    var used: Double
    var resetAt: Date?

    var usedPercent: Double { limit > 0 ? min(100, max(0, used / limit * 100)) : 0 }
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// Parsed Kimi coding quota: the weekly window plus the short-cycle rate limit
/// (e.g. "每 5 小时"), both from the same /usages response.
struct KimiSnapshot: Equatable {
    var weekly: KimiWindowUsage?
    var rate: KimiWindowUsage?
    var rateLabel: String?     // e.g. "5 小时"
}

enum KimiUsageFetcher {
    enum KimiError: LocalizedError {
        case badURL, http(Int), parse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Kimi Base URL 无效,请在偏好设置里检查"
            case .http(let c):
                switch c {
                case 401, 403: return "Kimi 接口返回 \(c):API Key 无效或已过期,请在偏好设置里重新填写 Kimi API Key"
                case 404: return "Kimi 接口返回 404:Base URL 可能不对,请在偏好设置里检查"
                default: return "Kimi 接口返回 \(c)"
                }
            case .parse: return "Kimi 用量响应无法解析(接口格式可能已变更)"
            }
        }
    }

    static func fetch() async throws -> KimiSnapshot {
        var base = KimiSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // Real path is {base}/coding/v1/usages (verified: /usages → 404,
        // /coding/v1/usages → 401 without a key). Accept bases that already
        // carry the coding[/v1] segments, like CodexBar does.
        let path: String
        if base.hasSuffix("/coding/v1") { path = "/usages" }
        else if base.hasSuffix("/coding") { path = "/v1/usages" }
        else { path = "/coding/v1/usages" }
        guard !base.isEmpty, let url = URL(string: base + path) else { throw KimiError.badURL }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(KimiSettings.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KimiError.http(http.statusCode)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiError.parse
        }
        // Code-API shape: {usage: {...}, limits: [{window, detail}]};
        // gateway shape: {usages: [{scope, detail, limits}]}.
        var weeklyDetail = obj["usage"] as? [String: Any]
        var limitsArr = obj["limits"] as? [[String: Any]]
        if weeklyDetail == nil, let usages = obj["usages"] as? [[String: Any]] {
            let coding = usages.first { ($0["scope"] as? String) == "FEATURE_CODING" } ?? usages.first
            weeklyDetail = coding?["detail"] as? [String: Any]
            if limitsArr == nil { limitsArr = coding?["limits"] as? [[String: Any]] }
        }

        var snapshot = KimiSnapshot()
        if let d = weeklyDetail, let w = windowUsage(from: d) { snapshot.weekly = w }
        // The short rate-limit window ("每 5 小时…") rides in limits[0].
        if let first = limitsArr?.first {
            if let d = first["detail"] as? [String: Any], let r = windowUsage(from: d) {
                snapshot.rate = r
            }
            if let win = first["window"] as? [String: Any],
               let duration = num(win["duration"]) {
                let unitRaw = (win["timeUnit"] as? String ?? "").lowercased()
                let unit = unitRaw.contains("hour") ? "小时"
                         : unitRaw.contains("minute") ? "分钟"
                         : unitRaw.contains("day") ? "天" : unitRaw
                snapshot.rateLabel = "\(Int(duration)) \(unit)"
            }
        }
        guard snapshot.weekly != nil || snapshot.rate != nil else { throw KimiError.parse }
        return snapshot
    }

    /// Parse one usage-detail dict (limit/used/remaining/resetTime, tolerant).
    private static func windowUsage(from d: [String: Any]) -> KimiWindowUsage? {
        guard let limit = num(d["limit"]) else { return nil }
        let used = num(d["used"])
        let remaining = num(d["remaining"])
        return KimiWindowUsage(
            limit: limit,
            used: used ?? (remaining.map { max(0, limit - $0) } ?? 0),
            resetAt: date(d["resetTime"] ?? d["reset_time"] ?? d["resetAt"] ?? d["reset_at"])
        )
    }

    /// String-or-number tolerant numeric read.
    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// ISO-8601 or epoch (s / ms) tolerant date read.
    private static func date(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            if let epoch = Double(s) { return epochDate(epoch) }
        }
        if let n = any as? NSNumber { return epochDate(n.doubleValue) }
        return nil
    }

    private static func epochDate(_ v: Double) -> Date? {
        guard v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
    }
}
