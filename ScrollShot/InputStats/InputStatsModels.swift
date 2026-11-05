import Foundation

/// Per-day input statistics.
/// Inspired by KeyStats (https://github.com/debugtheworldbot/keyStats, MIT).
struct DailyInputStats: Codable, Equatable {
    var date: Date
    var keyPresses: Int
    var keyPressCounts: [String: Int]
    var leftClicks: Int
    var rightClicks: Int
    var mouseDistance: Double      // pixels
    var scrollDistance: Double     // pixels

    init(date: Date = Calendar.current.startOfDay(for: Date())) {
        self.date = date
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
    }

    var totalClicks: Int { leftClicks + rightClicks }

    /// Merge two same-day stats by summing every counter (used for cross-device
    /// aggregation). The left-hand date wins.
    static func +(lhs: DailyInputStats, rhs: DailyInputStats) -> DailyInputStats {
        var merged = lhs
        merged.keyPresses += rhs.keyPresses
        merged.leftClicks += rhs.leftClicks
        merged.rightClicks += rhs.rightClicks
        merged.mouseDistance += rhs.mouseDistance
        merged.scrollDistance += rhs.scrollDistance
        for (key, count) in rhs.keyPressCounts {
            merged.keyPressCounts[key, default: 0] += count
        }
        return merged
    }

    /// Top keys sorted by count, capped for display.
    func topKeys(limit: Int = 15) -> [(key: String, count: Int)] {
        keyPressCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (key: $0.key, count: $0.value) }
    }
}

// MARK: - Formatting helpers

private let metersPerPixel: Double = 0.000264583

enum InputStatsFormat {
    static func number(_ value: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        return fmt.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Space-saving form for the menu bar: 2,308 → "2.3K", 11,854 → "11.9K",
    /// 1,200,000 → "1.2M". Full grouped `number()` stays for the dashboard.
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000...: return trimmed(v / 1_000_000, "M")
        case 1_000...:     return trimmed(v / 1_000, "K")
        default:           return "\(value)"
        }
    }

    private static func trimmed(_ n: Double, _ suffix: String) -> String {
        let s = String(format: "%.1f", n)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
    }

    static func mouseDistance(_ pixels: Double) -> String {
        let meters = pixels * metersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if meters >= 1 {
            return String(format: "%.1f m", meters)
        } else {
            return String(format: "%.0f cm", meters * 100)
        }
    }

    static func scrollDistance(_ pixels: Double) -> String {
        if pixels >= 10_000 {
            return String(format: "%.1f kPx", pixels / 1000)
        } else {
            return String(format: "%.0f px", pixels)
        }
    }
}
