import Foundation

/// Shared data types for the Claude Code usage monitor.
///
/// Two independent pipelines feed these:
///  • **Limits** (`UsageWindow`s) — from Anthropic's OAuth usage endpoint, or
///    from the claude.ai web API via a browser `sessionKey` cookie.
///  • **Cost / tokens** (`CostSummary`) — from scanning local `~/.claude` JSONL logs.
/// They fail independently, so a snapshot may carry one without the other.

/// One rate-limit window (session / weekly / per-model), as returned by the API.
struct UsageWindow: Equatable {
    /// Percent of the allowance already used (0–100).
    let utilization: Double
    /// When this window's allowance resets.
    let resetsAt: Date?

    /// Percent still available (0–100).
    var remainingPercent: Double { max(0, min(100, 100 - utilization)) }
}

/// All limit windows for the current Claude account.
struct UsageLimits: Equatable {
    var session: UsageWindow?        // five_hour
    var weekly: UsageWindow?         // seven_day
    var weeklyOpus: UsageWindow?     // seven_day_opus
    var weeklySonnet: UsageWindow?   // seven_day_sonnet
    var routines: UsageWindow?       // seven_day_routines
    /// Optional paid extra-usage (credits) info.
    var extraUsedCredits: Double?
    var extraMonthlyLimit: Double?
    var extraCurrency: String?
}

/// Per-day cost + token totals (one bar in the 30-day chart).
struct DailyUsage: Equatable, Identifiable {
    let day: Date          // start-of-day
    var cost: Double
    var tokens: Int
    var id: Date { day }
}

/// Locally-computed cost and token totals.
struct CostSummary: Equatable {
    var todayCost: Double = 0
    var cost30d: Double = 0
    var tokens30d: Int = 0
    var latestDayTokens: Int = 0
    var topModel: String?
    /// Last 30 days, oldest → newest (gaps filled with zero), for the bar chart.
    var daily: [DailyUsage] = []
    /// 30-day token totals per model (for a small breakdown).
    var perModelTokens: [String: Int] = [:]

    /// Diagnostics: how many log files were examined and how many assistant-usage
    /// rows were successfully parsed. Keeps the UI from silently showing $0.00
    /// when there is simply no log data.
    var filesScanned: Int = 0
    var entriesParsed: Int = 0

    var hasData: Bool { entriesParsed > 0 }
}

/// A full snapshot the UI renders. Either half may be nil if its pipeline failed.
struct UsageSnapshot: Equatable {
    var limits: UsageLimits?
    var cost: CostSummary?
    var kimi: KimiSnapshot?
    var codex: CodexSnapshot?
    var deepseek: DeepSeekBalanceSnapshot?
    var deepseekUsage: DeepSeekUsageSnapshot?
    var opencode: OpenCodeUsageSnapshot?
    var limitsError: String?
    var costError: String?
    var kimiError: String?
    var codexError: String?
    var deepseekError: String?
    var deepseekUsageError: String?
    var opencodeError: String?
    var updatedAt: Date?

    static let empty = UsageSnapshot()
}

// MARK: - Formatting helpers

enum UsageFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// 定宽货币串:为菜单栏固定宽度服务,优先 2 位小数,超宽逐步压缩到
    /// 1 位 → 0 位 → k 缩写,保证返回宽度 <= maxChars。
    static func compactMoney(_ value: Double, symbol: String, maxChars: Int) -> String {
        for digits in [2, 1, 0] {
            let s = symbol + String(format: "%.\(digits)f", value)
            if s.count <= maxChars { return s }
        }
        let s = symbol + String(format: "%.1fk", value / 1000)
        return s.count <= maxChars ? s : String(s.prefix(maxChars))
    }

    /// Compact dollars, e.g. `$36.04`, `$2,984`. Reuses formatters per
    /// fraction-digit count — rebuilding a NumberFormatter re-creates its ICU
    /// decimal format every time, which is noticeably expensive on the hot path.
    private static var currencyFormatters: [Int: NumberFormatter] = [:]

    static func dollars(_ value: Double, fractionDigits: Int = 2) -> String {
        let digits = value >= 1000 ? 0 : fractionDigits
        let f = currencyFormatter(for: digits)
        return f.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private static func currencyFormatter(for digits: Int) -> NumberFormatter {
        if let f = currencyFormatters[digits] { return f }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        currencyFormatters[digits] = f
        return f
    }

    /// Compact token counts, e.g. `41M`, `3.1B`.
    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.0fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.0fK", v / 1_000)
        default:               return "\(value)"
        }
    }

    /// "4h 36m" style countdown until `date` (or "—" if past / nil).
    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let secs = Int(date.timeIntervalSince(now))
        guard secs > 0 else { return "0m" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 {
            let d = h / 24
            return "\(d)d \(h % 24)h"
        }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Absolute reset time, e.g. "今天 18:30" / "明天 02:00" / "周四 14:00" / "7/6 14:00".
    static func resetClock(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        let time = hmFormatter.string(from: date)
        if cal.isDateInToday(date)    { return "今天 \(time)" }
        if cal.isDateInTomorrow(date) { return "明天 \(time)" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: date)).day ?? 0
        if days < 7 { return "\(weekdayFormatter.string(from: date)) \(time)" }
        return dateTimeFormatter.string(from: date)
    }

    private static let hmFormatter = makeFormatter("HH:mm")
    private static let weekdayFormatter = makeFormatter("EEE")     // 周四
    private static let dateTimeFormatter = makeFormatter("M/d HH:mm")
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = format
        return f
    }
}
