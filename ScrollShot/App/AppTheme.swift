import AppKit

/// User-selectable appearance for all ScrollShot windows.
enum AppThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.mode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("settings.appearance.system")
        case .light:  return L("settings.appearance.light")
        case .dark:   return L("settings.appearance.dark")
        }
    }

    /// `nil` means "inherit from the system".
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }

    static func resolve(storedValue: String?) -> AppThemeMode {
        guard let storedValue, let mode = AppThemeMode(rawValue: storedValue) else {
            return .system
        }
        return mode
    }
}

@MainActor
enum AppTheme {
    static var stored: AppThemeMode {
        AppThemeMode.resolve(
            storedValue: UserDefaults.standard.string(forKey: AppThemeMode.storageKey)
        )
    }

    static func applyStored() {
        apply(stored)
    }

    static func apply(_ mode: AppThemeMode) {
        NSApp.appearance = mode.appearanceName.flatMap(NSAppearance.init(named:))
    }
}
