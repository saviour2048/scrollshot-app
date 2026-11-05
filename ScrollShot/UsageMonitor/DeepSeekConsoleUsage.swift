import Foundation

/// DeepSeek 网页控制台(platform.deepseek.com)的账号整体消耗 ——
/// 跨所有工具、所有 API key。数据来自控制台内部接口,仅需 userToken
/// (不带 cookie 也 200,已实测验证)。
enum DeepSeekConsoleSettings {
    static var consoleToken: String {
        get { KeychainStore.load(account: "deepseek.consoleToken") ?? "" }
        set { KeychainStore.save(newValue, account: "deepseek.consoleToken") }
    }

    static var isConfigured: Bool { !consoleToken.isEmpty }
}

/// 账号 30 天 + 今日的花费/token 汇总。
struct DeepSeekUsageSnapshot: Equatable {
    var todayCost: Double
    var cost30d: Double
    var todayTokens: Int
    var tokens30d: Int
    var topModel: String?   // 30 天花费最高的模型
    var currency: String    // "CNY" / "USD"
}

enum DeepSeekConsoleUsageFetcher {
    enum ConsoleError: LocalizedError, Equatable {
        case noToken, http(Int), biz(String), parse
        var errorDescription: String? {
            switch self {
            case .noToken: return "未配置控制台令牌,请先在偏好设置·用量里填写"
            case .http(let c):
                if c == 401 { return "控制台令牌已过期,请在偏好设置里重新获取" }
                return "DeepSeek 控制台接口返回 \(c)"
            case .biz(let msg): return "DeepSeek 控制台接口错误:\(msg)"
            case .parse: return "DeepSeek 控制台响应无法解析(接口格式可能已变更)"
            }
        }
    }

    private static let base = "https://platform.deepseek.com"
    private static let costPath = "/api/v0/usage/by_api_key/cost"
    private static let amountPath = "/api/v0/usage/by_api_key/amount"

    /// 30 天窗口的日界对齐参数:接口要求按当地日界对齐,否则 INVALID_PARAM。
    /// start/end 含今天共 30 天;返回 (start, end, tzOffsetSeconds, todayStart)。
    static func windowParams(now: Date = Date(), tz: TimeZone = .current)
        -> (start: Int, end: Int, tzOffset: Int, todayStart: Int) {
        let tzSec = tz.secondsFromGMT()
        let todayStart = Int(floor((now.timeIntervalSince1970 + Double(tzSec)) / 86400)) * 86400 - tzSec
        return (todayStart - 29 * 86400, todayStart + 86400, tzSec, todayStart)
    }

    static func fetch() async throws -> DeepSeekUsageSnapshot {
        let token = DeepSeekConsoleSettings.consoleToken
        guard !token.isEmpty else { throw ConsoleError.noToken }
        let p = windowParams()
        async let costData = get(path: costPath, params: p, token: token)
        async let amountData = get(path: amountPath, params: p, token: token)
        let (cost, amount) = try await (costData, amountData)
        return try merge(cost: cost, amount: amount, todayStart: p.todayStart)
    }

    private static func get(path: String,
                            params p: (start: Int, end: Int, tzOffset: Int, todayStart: Int),
                            token: String) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = [
            URLQueryItem(name: "start", value: String(p.start)),
            URLQueryItem(name: "end", value: String(p.end)),
            URLQueryItem(name: "tz", value: String(p.tzOffset)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ConsoleError.http(http.statusCode)
        }
        return data
    }

    /// 拆信封:{code, data:{biz_code, biz_msg, biz_data}}。biz_code != 0 带 biz_msg 报错。
    static func bizData(_ data: Data) throws -> [String: Any] {
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = env["data"] as? [String: Any] else { throw ConsoleError.parse }
        if let biz = int(d["biz_code"]), biz != 0 {
            throw ConsoleError.biz(d["biz_msg"] as? String ?? "biz_code \(biz)")
        }
        guard let bizData = d["biz_data"] as? [String: Any] else { throw ConsoleError.parse }
        return bizData
    }

    /// 合并 cost + amount 两个响应(纯函数,可单测):
    /// cost.biz_data.data[] 按币种分组,series[].buckets[].cost 是字符串;
    /// amount.biz_data.series 直接挂在 biz_data 下,buckets[].usage 按类型分 token。
    /// 当天数据 = buckets 里 time == todayStart 的那条。
    static func merge(cost costData: Data, amount amountData: Data, todayStart: Int) throws -> DeepSeekUsageSnapshot {
        let costBiz = try bizData(costData)
        let amountBiz = try bizData(amountData)

        var currency = "CNY"
        var todayCost = 0.0, cost30d = 0.0
        var costPerModel: [String: Double] = [:]
        var sawCostSeries = false
        for group in costBiz["data"] as? [[String: Any]] ?? [] {
            if let c = group["currency"] as? String { currency = c }
            for s in group["series"] as? [[String: Any]] ?? [] {
                sawCostSeries = true
                let model = s["model"] as? String ?? ""
                for b in s["buckets"] as? [[String: Any]] ?? [] {
                    guard let c = num(b["cost"]), let t = int(b["time"]) else { continue }
                    cost30d += c
                    costPerModel[model, default: 0] += c
                    if t == todayStart { todayCost += c }
                }
            }
        }

        var todayTokens = 0, tokens30d = 0
        var sawAmountSeries = false
        for s in amountBiz["series"] as? [[String: Any]] ?? [] {
            sawAmountSeries = true
            for b in s["buckets"] as? [[String: Any]] ?? [] {
                guard let t = int(b["time"]),
                      let usage = b["usage"] as? [String: Any] else { continue }
                // token 总量 = 输出 + 缓存命中输入 + 缓存未命中输入
                let tokens = (int(usage["RESPONSE_TOKEN"]) ?? 0)
                    + (int(usage["PROMPT_CACHE_HIT_TOKEN"]) ?? 0)
                    + (int(usage["PROMPT_CACHE_MISS_TOKEN"]) ?? 0)
                tokens30d += tokens
                if t == todayStart { todayTokens += tokens }
            }
        }

        guard sawCostSeries || sawAmountSeries else { throw ConsoleError.parse }
        let topModel = costPerModel.max(by: { $0.value < $1.value })?.key
        return DeepSeekUsageSnapshot(todayCost: todayCost, cost30d: cost30d,
                                     todayTokens: todayTokens, tokens30d: tokens30d,
                                     topModel: topModel, currency: currency)
    }

    /// String-or-number tolerant reads(金额/时间字段文档是字符串,宽容收 number)。
    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
