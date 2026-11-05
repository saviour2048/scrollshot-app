import AppKit

/// Detects other screenshot/screen-capture utilities that are known to conflict
/// with ScrollShot because they also install global mouse/keyboard event hooks.
///
/// When two such tools run at the same time, the first mouse event after the
/// overlay appears can be consumed by the other tool, producing the symptom
/// "first drag does nothing, second drag works".
enum ConflictDetector {
    struct KnownApp {
        let bundleIdentifier: String
        let displayName: String
    }

    /// List of screenshot utilities that have been reported or are likely to
    /// conflict with ScrollShot's global hotkey + overlay interaction.
    static let knownConflicts: [KnownApp] = [
        KnownApp(bundleIdentifier: "com.shottr.mac", displayName: "Shottr"),
        KnownApp(bundleIdentifier: "com.cleanshot.mac", displayName: "CleanShot X"),
        KnownApp(bundleIdentifier: "com.cleanshot.macos", displayName: "CleanShot X"),
        KnownApp(bundleIdentifier: "com.snipaste.Snipaste", displayName: "Snipaste"),
        KnownApp(bundleIdentifier: "com.better365.ishot", displayName: "iShot"),
        KnownApp(bundleIdentifier: "com.xnip.app", displayName: "Xnip"),
        KnownApp(bundleIdentifier: "com.techsmith.snagit", displayName: "Snagit"),
        KnownApp(bundleIdentifier: "com.evernote.skitch", displayName: "Skitch"),
        KnownApp(bundleIdentifier: "com.monosnap.monosnap", displayName: "Monosnap"),
        KnownApp(bundleIdentifier: "com.skillbrains.lightshot", displayName: "Lightshot"),
        KnownApp(bundleIdentifier: "com.yourcompany.Xnip", displayName: "Xnip"),
        KnownApp(bundleIdentifier: "pl.maketheweb.screenshotshot", displayName: "Shottr"),
    ]

    private static let suppressKey = "ConflictDetector.suppressWarning"

    /// Returns the subset of `knownConflicts` that is currently running.
    static func detectRunningConflicts() -> [KnownApp] {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return knownConflicts.filter { runningBundleIDs.contains($0.bundleIdentifier) }
    }

    /// Shows an alert if a conflicting app is running and the user has not
    /// chosen to suppress the warning.
    static func showConflictAlertIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return }

        let conflicts = detectRunningConflicts()
        guard !conflicts.isEmpty else { return }

        let names = conflicts.map(\.displayName).joined(separator: "、")

        let alert = NSAlert()
        alert.messageText = "检测到可能冲突的截图工具"
        alert.informativeText = ""
            + "ScrollShot 检测到 \(names) 正在运行。"
            + "多个截图工具同时监听全局鼠标/键盘事件时，可能导致第一次拖拽没有反应。"
            + "建议在使用 ScrollShot 时退出其他截图工具，或避免让它们使用相同的快捷键。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "我知道了")
        alert.addButton(withTitle: "不再提示")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
    }
}
