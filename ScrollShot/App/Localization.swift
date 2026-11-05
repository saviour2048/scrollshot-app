import Foundation
import SwiftUI

/// Supported app languages. The raw value matches the .lproj folder name.
enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans:  return "简体中文"
        case .english: return "English"
        case .spanish: return "Español"
        }
    }
}

/// Runtime language switcher. Hooks into Bundle.main so `NSLocalizedString`
/// and SwiftUI `Text("key")` follow the user-chosen language without a restart.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let key = "app.selectedLanguage"

    @Published var current: AppLanguage {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
            UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
            Bundle.setLanguage(current.rawValue)
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        current = language
        // Refresh AppKit UI that is built once and not driven by SwiftUI.
        MainMenuBarController.shared.reload()
        InputStatsStatusItemController.shared.reload()
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        let language = AppLanguage(rawValue: stored ?? "") ?? .zhHans
        current = language
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        Bundle.setLanguage(language.rawValue)
    }
}

/// Convenience shorthand for localized strings.
func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

extension Notification.Name {
    static let languageChanged = Notification.Name("scrollshot.languageChanged")
}

// MARK: - Bundle hook

private var bundleKey: UInt8 = 0
private var languageBundleKey: UInt8 = 0

extension Bundle {
    /// Switch the main bundle to the given language at runtime.
    static func setLanguage(_ language: String) {
        object_setClass(Bundle.main, AnyLanguageBundle.self)
        objc_setAssociatedObject(Bundle.main,
                                 &bundleKey,
                                 language,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // Cache the language bundle once here; `localizedString` runs on every
        // string lookup, so it must not rebuild a Bundle via `Bundle(path:)`.
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap { Bundle(path: $0) }
        objc_setAssociatedObject(Bundle.main,
                                 &languageBundleKey,
                                 bundle,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private class AnyLanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String,
                                  value: String?,
                                  table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(Bundle.main, &languageBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// MARK: - SwiftUI helpers

struct LocalizedText: View {
    let key: String
    var body: some View { Text(L(key)) }
}
