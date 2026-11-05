import ServiceManagement

/// "Launch at login" backed by SMAppService (macOS 13+). The system owns the
/// state, so it is read live here instead of being persisted in UserDefaults —
/// and deliberately excluded from SettingsSync (login items are per-Mac).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns nil on success, or a localized error to surface in the UI.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
