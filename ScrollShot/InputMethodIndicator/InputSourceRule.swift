import Foundation

/// A single rule mapping an application (and optionally a website domain) to a
/// specific input source. The most specific matching rule wins:
///
///   1. Exact (bundleID + domain)
///   2. App-level (bundleID only)
///   3. Default/fallback rule
///
/// Domain-based matching is reserved for future Phase 2 browser integration.
struct InputSourceRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var isEnabled = true

    /// Target application bundle identifier, e.g. "com.apple.dt.Xcode".
    /// If `nil` the rule matches any app (useful as a fallback default).
    var bundleID: String?

    /// Optional website host, e.g. "github.com". Currently unused in Phase 1.
    var domain: String?

    /// Text Input Services input-source ID, e.g. "com.apple.keylayout.ABC".
    var inputSourceID: String

    /// Display name cached at creation time so the UI doesn't have to hit TIS repeatedly.
    var inputSourceName: String

    static func == (lhs: InputSourceRule, rhs: InputSourceRule) -> Bool {
        lhs.id == rhs.id
        && lhs.isEnabled == rhs.isEnabled
        && lhs.bundleID == rhs.bundleID
        && lhs.domain == rhs.domain
        && lhs.inputSourceID == rhs.inputSourceID
        && lhs.inputSourceName == rhs.inputSourceName
    }
}

extension InputSourceRule {
    /// A human-readable label for the app part of the rule.
    var bundleLabel: String {
        bundleID ?? "Default"
    }

    /// A label for the domain part, if any.
    var domainLabel: String? {
        domain?.isEmpty == false ? domain : nil
    }
}
