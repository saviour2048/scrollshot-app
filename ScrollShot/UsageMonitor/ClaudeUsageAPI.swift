import Foundation

/// Fetches Claude rate-limit windows from Anthropic's OAuth usage endpoint.
///
/// ⚠️ This is an **undocumented** endpoint that the Claude Code CLI uses
/// internally; we impersonate the CLI with the same headers. It can change or
/// disappear without notice — when it does, only the "limits" half of the UI
/// goes blank; local cost/token stats are unaffected.
enum ClaudeUsageAPI {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/1.0 (ScrollShot usage monitor)"

    static func fetchLimits() async throws -> UsageLimits {
        let token = try await ClaudeCredentials.current()

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        guard http.statusCode == 200 else {
            throw APIError.status(http.statusCode)
        }
        return try decode(data)
    }

    enum APIError: LocalizedError {
        case badResponse
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "用量接口返回异常。"
            case .status(let code): return "用量接口返回 \(code)(接口可能已变更)。"
            }
        }
    }

    // MARK: Decoding

    private static func decode(_ data: Data) throws -> UsageLimits {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        var limits = UsageLimits()
        limits.session     = window(root["five_hour"])
        limits.weekly      = window(root["seven_day"])
        limits.weeklyOpus  = window(root["seven_day_opus"])
        limits.weeklySonnet = window(root["seven_day_sonnet"])
        limits.routines    = window(root["seven_day_routines"])

        if let extra = root["extra_usage"] as? [String: Any] {
            limits.extraUsedCredits = (extra["used_credits"] as? Double)
                ?? (extra["used_credits"] as? Int).map(Double.init)
            limits.extraMonthlyLimit = (extra["monthly_limit"] as? Double)
                ?? (extra["monthly_limit"] as? Int).map(Double.init)
            limits.extraCurrency = extra["currency"] as? String
        }
        return limits
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let utilization = (dict["utilization"] as? Double)
            ?? (dict["utilization"] as? Int).map(Double.init)
            ?? 0
        var resetsAt: Date?
        if let iso = dict["resets_at"] as? String {
            resetsAt = isoFormatter.date(from: iso) ?? isoFormatterNoFraction.date(from: iso)
        }
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
