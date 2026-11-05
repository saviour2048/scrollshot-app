import Foundation

/// DeepSeek(或同一 key 指向的 OpenAI 兼容端点)余额 ——
/// `GET {base}/user/balance`,Bearer key。凭据复用 AI 对话的 LLMSettings。
/// 只查询展示,不做任何本地 token 记账,也不进菜单栏。
struct DeepSeekBalanceSnapshot: Equatable {
    /// 单币种余额;金额保留接口返回的原始字符串,显示时再格式化。
    struct BalanceInfo: Equatable {
        var currency: String
        var total: String
        var granted: String
        var toppedUp: String
    }
    var isAvailable: Bool
    var balances: [BalanceInfo]
}

enum DeepSeekBalanceFetcher {
    enum DeepSeekError: LocalizedError, Equatable {
        case noKey, http(Int), parse
        var errorDescription: String? {
            switch self {
            case .noKey: return "未配置 API Key,请先在偏好设置·AI 对话里填写"
            case .http(let c):
                switch c {
                case 401: return "API Key 无效或已过期,请在偏好设置·AI 对话里检查"
                case 404: return "该接口不支持余额查询"
                default: return "余额接口返回 \(c)"
                }
            case .parse: return "余额响应无法解析(接口格式可能已变更)"
            }
        }
    }

    /// 与 LLMSettings.endpoint 同一拼法:base 不带 /v1 就补上。
    /// DeepSeek 的余额接口 /user/balance 与 /v1/user/balance 都可用,
    /// 跟随对话端点的规则统一补 /v1;其它兼容端点若没有此路径会 404。
    static var endpoint: URL? {
        var base = LLMSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/v1") && !base.contains("/v1/") {
            base += "/v1"
        }
        return URL(string: base + "/user/balance")
    }

    static func fetch() async throws -> DeepSeekBalanceSnapshot {
        let key = LLMSettings.apiKey
        guard !key.isEmpty, let url = endpoint else { throw DeepSeekError.noKey }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DeepSeekError.http(http.statusCode)
        }
        return try parse(data: data)
    }

    /// 纯解析(可单测)。金额文档是字符串,宽容收 number;balance_infos 为空算格式变更。
    static func parse(data: Data) throws -> DeepSeekBalanceSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekError.parse
        }
        let infos = (obj["balance_infos"] as? [[String: Any]] ?? []).compactMap { d -> DeepSeekBalanceSnapshot.BalanceInfo? in
            guard let currency = d["currency"] as? String,
                  let total = str(d["total_balance"]) else { return nil }
            return DeepSeekBalanceSnapshot.BalanceInfo(
                currency: currency,
                total: total,
                granted: str(d["granted_balance"]) ?? "0",
                toppedUp: str(d["topped_up_balance"]) ?? "0"
            )
        }
        guard !infos.isEmpty else { throw DeepSeekError.parse }
        return DeepSeekBalanceSnapshot(isAvailable: (obj["is_available"] as? Bool) ?? true,
                                       balances: infos)
    }

    /// String-or-number tolerant read.
    private static func str(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
