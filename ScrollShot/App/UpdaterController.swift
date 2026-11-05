import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater.
///
/// Sparkle reads its configuration from Info.plist (`SUFeedURL`, `SUPublicEDKey`,
/// `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). With
/// `startingUpdater: true` it begins background update checks automatically on
/// the scheduled interval; this type just exposes a manual "检查更新…" entry and
/// reports whether a check is currently possible (so the menu item can disable
/// itself while an update is already in flight).
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        // userDriver = nil → Sparkle's standard UI (the familiar "有新版本可用" panel).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether a manual check can be started right now.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Shows the standard "checking…/up to date/new version" flow.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
