import Foundation

/// Fetches Claude usage windows from the claude.ai web API using a browser session key.
///
/// This mirrors CodexBar's "Web API (cookies)" source: the user copies the `sessionKey`
/// cookie from a logged-in claude.ai browser tab, and we call the same undocumented
/// endpoints that the Claude web app uses.
///
/// Endpoints:
///   - GET https://claude.ai/api/organizations
///   - GET https://claude.ai/api/organizations/{orgId}/usage
///   - GET https://claude.ai/api/organizations/{orgId}/overage_spend_limit
enum ClaudeWebUsageFetcher {
    private static let baseURL = "https://claude.ai/api"
    private static let userAgent = "ScrollShot/1.0 (Claude web usage)"

    enum FetchError: LocalizedError {
        case invalidResponse
        case unauthorized
        case serverError(Int)
        case noOrganization
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Claude 网页 API 返回异常。"
            case .unauthorized:    return "Session key 已失效，请重新从浏览器复制。"
            case .serverError(let code): return "Claude 网页 API 错误 \(code)。"
            case .noOrganization:  return "未找到 Claude 组织。"
            case .network(let e):  return "网络错误：\(e.localizedDescription)"
            }
        }
    }

    struct Organization: Equatable {
        let id: String
        let name: String?
    }

    struct ExtraUsage: Equatable {
        let usedCredits: Double
        let monthlyLimit: Double
        let currency: String
    }

    static func fetchLimits(sessionKey: String) async throws -> UsageLimits {
        let org = try await fetchOrganization(sessionKey: sessionKey)
        let (limits, extraFromUsage) = try await fetchUsage(orgId: org.id, sessionKey: sessionKey)
        let overage = try? await fetchOverageSpendLimit(orgId: org.id, sessionKey: sessionKey)

        var result = limits
        if let overage = overage {
            result.extraUsedCredits = overage.usedCredits
            result.extraMonthlyLimit = overage.monthlyLimit
            result.extraCurrency = overage.currency
        } else if let extra = extraFromUsage {
            result.extraUsedCredits = extra.usedCredits
            result.extraMonthlyLimit = extra.monthlyLimit
            result.extraCurrency = extra.currency
        }
        return result
    }

    // MARK: - Organizations

    private static func fetchOrganization(sessionKey: String) async throws -> Organization {
        let data = try await request(path: "/organizations", sessionKey: sessionKey)
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !orgs.isEmpty else {
            throw FetchError.invalidResponse
        }

        let selected = orgs.first { org in
            let caps = org["capabilities"] as? [String] ?? []
            return caps.contains("chat")
        } ?? orgs.first { org in
            (org["api_only"] as? Bool) != true
        } ?? orgs.first

        guard let selected, let uuid = selected["uuid"] as? String else {
            throw FetchError.noOrganization
        }
        return Organization(id: uuid, name: selected["name"] as? String)
    }

    // MARK: - Usage

    private static func fetchUsage(orgId: String, sessionKey: String) async throws -> (UsageLimits, ExtraUsage?) {
        let data = try await request(path: "/organizations/\(orgId)/usage", sessionKey: sessionKey)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }

        var limits = UsageLimits()
        limits.session     = window(json["five_hour"])
        limits.weekly      = window(json["seven_day"])
        limits.weeklyOpus  = window(json["seven_day_opus"])
        limits.weeklySonnet = window(json["seven_day_sonnet"])
        limits.routines    = window(json["seven_day_routines"]) ?? window(json["seven_day_cowork"])

        let extra = extraUsage(json["extra_usage"])
        return (limits, extra)
    }

    // MARK: - Overage spend limit

    private static func fetchOverageSpendLimit(orgId: String, sessionKey: String) async throws -> ExtraUsage? {
        let data = try await request(path: "/organizations/\(orgId)/overage_spend_limit", sessionKey: sessionKey)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return extraUsage(json)
    }

    // MARK: - HTTP helper

    private static func request(path: String, sessionKey: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw FetchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
            switch http.statusCode {
            case 200: return data
            case 401, 403: throw FetchError.unauthorized
            default: throw FetchError.serverError(http.statusCode)
            }
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.network(error)
        }
    }

    // MARK: - Parsing helpers

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let utilization = (dict["utilization"] as? Double)
            ?? (dict["utilization"] as? Int).map(Double.init)
            ?? 0
        let resetsAt: Date?
        if let iso = dict["resets_at"] as? String {
            resetsAt = isoFormatter.date(from: iso) ?? isoFormatterPlain.date(from: iso)
        } else {
            resetsAt = nil
        }
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
    }

    private static func extraUsage(_ value: Any?) -> ExtraUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        let used = (dict["used_credits"] as? Double)
            ?? (dict["used_credits"] as? Int).map(Double.init)
        let limit = (dict["monthly_limit"] as? Double)
            ?? (dict["monthly_limit"] as? Int).map(Double.init)
        guard let used, let limit else { return nil }
        return ExtraUsage(
            usedCredits: used,
            monthlyLimit: limit,
            currency: (dict["currency"] as? String) ?? "USD")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
