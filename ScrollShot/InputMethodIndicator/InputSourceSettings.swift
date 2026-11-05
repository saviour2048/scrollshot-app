import Foundation

/// UserDefaults-backed toggles for the Input Source Pro-style feature.
@MainActor
enum InputSourceSettings {
    private static let enabledKey = "InputSourceStore.enabled"
    private static let domainEnabledKey = "InputSourceStore.domainEnabled"
    private static let rulesKey = "InputSourceStore.rules"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isDomainEnabled: Bool {
        get { UserDefaults.standard.object(forKey: domainEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: domainEnabledKey) }
    }

    static var rulesData: Data? {
        get { UserDefaults.standard.data(forKey: rulesKey) }
        set { UserDefaults.standard.set(newValue, forKey: rulesKey) }
    }

    // MARK: - Shift-tap 中/EN toggle (ShiftInputToggle)

    private static let shiftToggleEnabledKey = "shiftToggle.enabled"
    private static let shiftToggleSideKey = "shiftToggle.side"
    private static let shiftToggleLatinKey = "shiftToggle.latinSourceID"
    private static let shiftToggleCJKKey = "shiftToggle.cjkSourceID"

    static var shiftToggleEnabled: Bool {
        get { UserDefaults.standard.object(forKey: shiftToggleEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: shiftToggleEnabledKey) }
    }

    static var shiftToggleSide: ShiftInputToggle.Side {
        get { ShiftInputToggle.Side(rawValue: UserDefaults.standard.string(forKey: shiftToggleSideKey) ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: shiftToggleSideKey) }
    }

    static var shiftToggleLatinSourceID: String? {
        get { UserDefaults.standard.string(forKey: shiftToggleLatinKey) }
        set { UserDefaults.standard.set(newValue, forKey: shiftToggleLatinKey) }
    }

    static var shiftToggleCJKSourceID: String? {
        get { UserDefaults.standard.string(forKey: shiftToggleCJKKey) }
        set { UserDefaults.standard.set(newValue, forKey: shiftToggleCJKKey) }
    }

    /// The CJK input mode the user last had active (runtime memory for the
    /// Shift toggle; deliberately NOT synced via SettingsSync — IME sets
    /// differ per Mac).
    private static let shiftToggleLastCJKKey = "shiftToggle.lastCJKSourceID"

    static var shiftToggleLastCJKSourceID: String? {
        get { UserDefaults.standard.string(forKey: shiftToggleLastCJKKey) }
        set { UserDefaults.standard.set(newValue, forKey: shiftToggleLastCJKKey) }
    }

    /// The stored choice if any, otherwise auto-detected: ABC (or US) for
    /// Latin, the first Pinyin / Apple input-method source for Chinese.
    static var resolvedLatinSourceID: String? {
        if let id = shiftToggleLatinSourceID, !id.isEmpty { return id }
        return InputSourceController.enabledInputSources.first {
            $0.sourceID.hasPrefix("com.apple.keylayout.ABC") || $0.sourceID == "com.apple.keylayout.US"
        }?.sourceID
    }

    static var resolvedCJKSourceID: String? {
        if let id = shiftToggleCJKSourceID, !id.isEmpty { return id }
        let sources = InputSourceController.enabledInputSources
        return sources.first { $0.sourceID.contains("Pinyin") }?.sourceID
            ?? sources.first { $0.sourceID.hasPrefix("com.apple.inputmethod.") }?.sourceID
    }

    static var suppressPermissionPrompts: Bool {
        AppConfig.suppressesPermissionPrompts
    }
}
