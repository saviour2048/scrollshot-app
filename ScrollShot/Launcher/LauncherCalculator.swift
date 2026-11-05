import Foundation
import MathParser

/// Evaluates simple math expressions for the launcher (Raycast-style calculator).
/// Uses DDMathParser so it supports + − × ÷ ^, parentheses, functions like sqrt,
/// and localized/unicode number forms.
enum LauncherCalculator {
    /// Tries to evaluate `query` as a math expression. Returns nil if the query
    /// is not a valid, fully-resolvable expression (e.g. an app name, empty, or
    /// contains unresolved variables).
    static func evaluate(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Skip queries that look like plain words / app searches ("safari", "prefs").
        // We still allow numbers, operators, parentheses, functions, and whitespace.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^%()×÷√²³π ")
            .union(.letters) // for functions like sqrt, sin, pi, e
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }

        do {
            let expression = try Expression(string: trimmed)
            let value = try Evaluator.default.evaluate(expression)
            return format(value)
        } catch {
            return nil
        }
    }

    /// Clean, compact formatting: drop trailing .0 for integers, cap reasonable
    /// precision, and keep very small/large numbers readable.
    private static func format(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return String(value) }

        // Integer results: show without decimals.
        if value == floor(value), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }

        // Avoid scientific notation for modest values; cap precision at 6 decimals.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
