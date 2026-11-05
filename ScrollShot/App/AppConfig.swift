import Foundation

/// App-wide constants and small helpers.
enum AppConfig {
    static let appName = "ScrollShot"

    /// Minimum drag size (in points) that counts as a valid region selection.
    static let minimumSelectionSize: CGFloat = 8

    /// Default directory offered by the save panel (~/Pictures, falling back to home).
    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The Desktop directory — the default auto-save location (Flameshot-style).
    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static let saveDirectoryKey = "saveDirectoryPath"

    /// Where captures auto-save. User-configurable in 设置; defaults to the
    /// Desktop. Falls back to Desktop if the saved folder no longer exists.
    static var saveDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: saveDirectoryKey) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return desktopDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: saveDirectoryKey) }
    }

    /// True when the user has chosen a custom folder (vs. the Desktop default).
    static var hasCustomSaveDirectory: Bool {
        UserDefaults.standard.string(forKey: saveDirectoryKey) != nil
    }

    /// Reverts the save location back to the Desktop default.
    static func resetSaveDirectory() {
        UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
    }

    /// Timestamped default file name, e.g. `ScrollShot-20260606-153012.png`.
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(appName)-\(formatter.string(from: date)).png"
    }

    /// Deep link to System Settings ▸ Privacy & Security ▸ Screen Recording.
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    /// Deep link to System Settings ▸ Privacy & Security ▸ Accessibility.
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    /// Deep link to System Settings ▸ Privacy & Security ▸ Full Disk Access
    /// (needed for whole-disk scanning in the disk-cleanup module).
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    /// When `SCROLLSHOT_SKIP_PERMISSION_PROMPTS=1` is set in the environment,
    /// the app will not surface any system permission dialogs. This is intended
    /// for automated testing and for local debug runs where the developer has
    /// already granted the released app permissions and does not want to be
    /// re-prompted for every unsigned/debug binary.
    static var suppressesPermissionPrompts: Bool {
        ProcessInfo.processInfo.environment["SCROLLSHOT_SKIP_PERMISSION_PROMPTS"] == "1"
    }
}
