import Foundation
import AppKit
import ApplicationServices

/// Reads the current URL from the frontmost browser window using the
/// Accessibility API. This requires the user to grant Accessibility access.
@MainActor
final class BrowserURLDetector {
    static let shared = BrowserURLDetector()

    /// Bundle identifiers of browsers we know how to inspect.
    private static let supportedBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]

    private var timer: Timer?
    private var lastHost: String?
    private var onHostChange: ((String?) -> Void)?

    private init() {}

    /// Whether the current process is trusted for Accessibility access.
    var isAccessibilityTrusted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Starts polling the browser URL. `handler` is called whenever the host changes.
    func startPolling(handler: @escaping (String?) -> Void) {
        stopPolling()
        onHostChange = handler

        Diag.inputSource.info("BrowserURLDetector started, accessibility trusted: \(self.isAccessibilityTrusted)")

        // Immediate first read.
        tick()

        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        onHostChange = nil
        lastHost = nil
    }

    /// Returns true if the given bundle ID belongs to a supported browser.
    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBrowsers.contains(bundleID)
    }

    // MARK: - Private

    private func tick() {
        let host = currentBrowserHost()
        if host != lastHost {
            Diag.inputSource.info("Browser host changed: \(host ?? "<nil>", privacy: .public)")
        }
        guard host != lastHost else { return }
        lastHost = host
        onHostChange?(host)
    }

    /// Best-effort extraction of the host from the frontmost browser's address bar.
    private func currentBrowserHost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            Diag.inputSource.debug("No frontmost application")
            return nil
        }
        guard Self.isBrowser(app.bundleIdentifier) else {
            Diag.inputSource.debug("Frontmost app is not a supported browser: \(app.bundleIdentifier ?? "<nil>", privacy: .public)")
            return nil
        }
        guard isAccessibilityTrusted else {
            Diag.inputSource.warning("Accessibility not trusted; cannot read browser URL")
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axValue(axApp, kAXFocusedWindowAttribute) as! AXUIElement? else {
            Diag.inputSource.debug("Could not get focused window for \(app.bundleIdentifier ?? "<nil>", privacy: .public)")
            return nil
        }

        // Try to find a text field that contains a URL-like value.
        if let urlString = findURLString(in: window) {
            let host = host(from: urlString)
            Diag.inputSource.debug("Read URL string '\(urlString, privacy: .public)' -> host '\(host ?? "<nil>", privacy: .public)'")
            return host
        }
        Diag.inputSource.debug("No URL string found in browser window")
        return nil
    }

    /// Browser windows can expose enormous (or cyclic) AX trees; an unbounded
    /// recursion here blew the main-thread stack (crash report 2026-07-17).
    /// Cap both the recursion depth and the number of visited elements.
    private static let maxSearchDepth = 30
    private static let maxSearchNodes = 2000

    private func findURLString(in element: AXUIElement) -> String? {
        var budget = Self.maxSearchNodes
        return findURLString(in: element, depth: 0, budget: &budget)
    }

    private func findURLString(in element: AXUIElement, depth: Int, budget: inout Int) -> String? {
        guard depth <= Self.maxSearchDepth, budget > 0 else { return nil }
        budget -= 1

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String

        if roleString == (kAXTextFieldRole as String) || roleString == (kAXTextAreaRole as String) {
            if let value = axValue(element, kAXValueAttribute) as? String,
               value.looksLikeURL {
                return value
            }
        }

        guard let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findURLString(in: child, depth: depth + 1, budget: &budget) {
                return found
            }
        }
        return nil
    }

    private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func host(from urlString: String) -> String? {
        // The accessibility value sometimes returns just the host, sometimes a full URL.
        // It may also omit the scheme (e.g. "example.feishu.cn/wiki/..."); prepend https://
        // so URL can parse out the real host.
        var normalized = urlString.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        if !normalized.hasPrefix("http://"), !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        return URL(string: normalized)?.host
    }
}

private extension String {
    var looksLikeURL: Bool {
        let lower = self.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("file://")
            || (lower.contains(".") && !lower.contains(" "))
    }
}
