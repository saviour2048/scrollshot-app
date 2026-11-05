import Foundation

/// Hardcoded Claude per-token prices (USD) and the cost formula.
///
/// Matched by family substring (`opus` / `sonnet` / `haiku`) so new dated model
/// IDs keep working without edits. Rates are USD **per token**. Update here when
/// Anthropic changes pricing or ships a new family.
enum UsagePricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheWrite: Double   // 5-minute cache creation
        let cacheRead: Double
    }

    // $/token. (e.g. Opus 4.5 = $5 / $25 per million → 5e-6 / 25e-6)
    private static let opus   = Rate(input: 5e-6,   output: 25e-6,  cacheWrite: 6.25e-6,  cacheRead: 0.5e-6)
    private static let sonnet = Rate(input: 3e-6,   output: 15e-6,  cacheWrite: 3.75e-6,  cacheRead: 0.3e-6)
    private static let haiku  = Rate(input: 0.8e-6, output: 4e-6,   cacheWrite: 1e-6,     cacheRead: 0.08e-6)

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("opus") { return opus }
        if m.contains("haiku") { return haiku }
        // Default to Sonnet (the common case) for anything else.
        return sonnet
    }

    /// Cost in USD for one priced message's token counts.
    /// 1-hour cache writes are billed at 2× the input rate (Anthropic rule).
    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int
    ) -> Double {
        let r = rate(for: model)
        return Double(input) * r.input
            + Double(output) * r.output
            + Double(cacheRead) * r.cacheRead
            + Double(cacheWrite5m) * r.cacheWrite
            + Double(cacheWrite1h) * (r.input * 2)
    }
}
