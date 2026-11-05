import Foundation

/// Anonymous, opt-in usage analytics — "how many people use ScrollShot", never
/// "who they are". By design:
///  • OFF by default. Nothing is sent unless the user turns it on in Settings.
///  • Only a RANDOM install id (not derived from hardware/serial), the app
///    version and the macOS version are sent. NEVER any clipboard, screenshot,
///    file, keystroke or other personal content.
///  • No network call at all until BOTH the user opts in AND an ingest endpoint
///    is configured below.
enum AnalyticsSettings {
    /// Opt-in switch, default false (see the privacy note in Settings).
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "analytics.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "analytics.enabled") }
    }
}

final class AnalyticsReporter: @unchecked Sendable {
    static let shared = AnalyticsReporter()
    private init() {}

    /// YOUR ingest endpoint. Leave EMPTY to keep the app fully offline. Point it
    /// at your own tiny server / Cloudflare Worker, or a TelemetryDeck-compatible
    /// URL, when you're ready. Until then this feature sends nothing.
    private let endpoint = ""

    /// A random, anonymous install id (created lazily — only ever generated when
    /// a report is actually sent, i.e. after the user opts in).
    private var installID: String {
        let key = "analytics.installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Call at launch. No-op unless the user opted in AND an endpoint is set.
    /// Throttled to one heartbeat per calendar day → daily-active count, no spam.
    func reportLaunch() {
        guard AnalyticsSettings.enabled, !endpoint.isEmpty else { return }
        let today = Self.dayKey()
        guard UserDefaults.standard.string(forKey: "analytics.lastDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "analytics.lastDay")
        send(event: "heartbeat")
    }

    private func send(event: String) {
        guard AnalyticsSettings.enabled, !endpoint.isEmpty, let url = URL(string: endpoint) else { return }
        let info = Bundle.main.infoDictionary
        // Minimal, anonymous. Do NOT ever add personal/user content here.
        let payload: [String: Any] = [
            "install_id": installID,
            "event": event,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req).resume()
    }

    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
