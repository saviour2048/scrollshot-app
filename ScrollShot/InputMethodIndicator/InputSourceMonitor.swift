import Foundation
import AppKit
import Carbon

/// Monitors frontmost-application changes and applies per-app or per-domain
/// input-source rules.
@MainActor
final class InputSourceMonitor {
    static let shared = InputSourceMonitor()

    private var appObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastBundleID: String?
    private var lastSwitchedSourceID: String?

    private init() {}

    // MARK: - Lifecycle

    /// Start or stop observers based on the current enabled state and rules.
    func reload() {
        let hasAppRules = InputSourceStore.shared.rules.contains {
            $0.isEnabled && $0.bundleID != nil && $0.domain == nil
        }
        let hasDomainRules = InputSourceStore.shared.rules.contains {
            $0.isEnabled && $0.domain != nil
        }

        Diag.inputSource.info("reload: enabled=\(InputSourceStore.shared.isEnabled), domainEnabled=\(InputSourceStore.shared.isDomainEnabled), appRules=\(hasAppRules), domainRules=\(hasDomainRules)")

        guard InputSourceStore.shared.isEnabled,
              (hasAppRules || hasDomainRules) else {
            stop()
            return
        }
        start()
    }

    func start() {
        guard appObserver == nil else { return }

        // Switch immediately for the current app on launch/enable.
        evaluateRules(for: NSWorkspace.shared.frontmostApplication)

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleAppActivated(app)
        }

        Diag.inputSource.info("InputSourceMonitor started")
    }

    func stop() {
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appObserver = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        lastBundleID = nil
        lastSwitchedSourceID = nil
        BrowserURLDetector.shared.stopPolling()
        Diag.inputSource.info("InputSourceMonitor stopped")
    }

    // MARK: - Rule evaluation

    private func handleAppActivated(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier
        guard bundleID != lastBundleID else { return }
        lastBundleID = bundleID

        // Stop any previous domain polling; we'll restart it if needed.
        BrowserURLDetector.shared.stopPolling()

        // Debounce rapid app switches (e.g. ⌘-Tab spam) to avoid input-source thrashing.
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateRules(for: app)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func evaluateRules(for app: NSWorkspaceApplication?) {
        let bundleID = app?.bundleIdentifier
        let rules = InputSourceStore.shared.rules.filter { $0.isEnabled }

        Diag.inputSource.info("evaluateRules for \(bundleID ?? "<nil>", privacy: .public), rules=\(rules.count)")

        // Priority 1: exact (bundleID + domain) match when a browser is active.
        if BrowserURLDetector.isBrowser(bundleID),
           InputSourceStore.shared.isDomainEnabled,
           hasEnabledDomainRule(for: bundleID, in: rules) {
            Diag.inputSource.info("Starting domain polling for \(bundleID ?? "<nil>", privacy: .public)")
            startDomainPolling(app: app, rules: rules)
            return
        }

        // Priority 2: app-level match (bundleID only).
        if let match = rules.first(where: { $0.bundleID == bundleID && $0.domain == nil }) {
            Diag.inputSource.info("App-level match: \(match.inputSourceID, privacy: .public)")
            applyRule(match)
            return
        }

        // Priority 3: default rule (bundleID == nil, domain == nil).
        if let fallback = rules.first(where: { $0.bundleID == nil && $0.domain == nil }) {
            Diag.inputSource.info("Fallback match: \(fallback.inputSourceID, privacy: .public)")
            applyRule(fallback)
            return
        }

        Diag.inputSource.debug("No input-source rule for \(bundleID ?? "<nil>", privacy: .public)")
    }

    private func hasEnabledDomainRule(for bundleID: String?, in rules: [InputSourceRule]) -> Bool {
        guard let bundleID else { return false }
        return rules.contains { $0.bundleID == bundleID && $0.domain != nil }
    }

    private func startDomainPolling(app: NSWorkspaceApplication?, rules: [InputSourceRule]) {
        let bundleID = app?.bundleIdentifier

        BrowserURLDetector.shared.startPolling { [weak self] host in
            guard let self else { return }

            Diag.inputSource.info("Domain polling callback: host=\(host ?? "<nil>", privacy: .public)")

            // Find the most specific domain rule for this host and browser.
            if let host,
               let match = rules.first(where: {
                   $0.bundleID == bundleID
                   && $0.domain != nil
                   && host.matchesDomain($0.domain!)
               }) {
                Diag.inputSource.info("Domain match: \(match.inputSourceID, privacy: .public)")
                self.applyRule(match)
                return
            }

            // No matching domain rule: fall back to app-level or default rule.
            if let fallback = rules.first(where: { $0.bundleID == bundleID && $0.domain == nil })
               ?? rules.first(where: { $0.bundleID == nil && $0.domain == nil }) {
                Diag.inputSource.info("Domain fallback: \(fallback.inputSourceID, privacy: .public)")
                self.applyRule(fallback)
            }
        }
    }

    private func applyRule(_ rule: InputSourceRule) {
        let current = InputSourceController.currentInputSourceID
        guard current != rule.inputSourceID else {
            Diag.inputSource.debug("Already on target input source \(rule.inputSourceID, privacy: .public)")
            return
        }
        guard InputSourceController.selectInputSource(id: rule.inputSourceID) else { return }
        lastSwitchedSourceID = rule.inputSourceID
    }
}

// MARK: - Domain matching

private extension String {
    /// Returns true if `self` (a host like "example.feishu.cn") matches the
    /// configured domain (e.g. "feishu.cn" or "example.feishu.cn").
    func matchesDomain(_ domain: String) -> Bool {
        let host = self.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = domain.lowercased().trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        return host == pattern || host.hasSuffix(".\(pattern)")
    }
}

// NSRunningApplication is not Sendable; alias to keep the MainActor isolation clear.
private typealias NSWorkspaceApplication = NSRunningApplication
