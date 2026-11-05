import Foundation
import Combine

/// Persists per-app input-source rules and broadcasts changes.
///
/// Modeled after `KeyMappingStore`: `@Published` properties automatically save,
/// and `activate()`/`reload()` bridge the gap where `init` assignments don't
/// fire `didSet`.
@MainActor
final class InputSourceStore: ObservableObject {
    static let shared = InputSourceStore()

    @Published var rules: [InputSourceRule] {
        didSet { saveRules() }
    }

    @Published var isEnabled: Bool {
        didSet {
            InputSourceSettings.isEnabled = isEnabled
            InputSourceMonitor.shared.reload()
        }
    }

    @Published var isDomainEnabled: Bool {
        didSet {
            InputSourceSettings.isDomainEnabled = isDomainEnabled
            InputSourceMonitor.shared.reload()
        }
    }

    private init() {
        if let data = InputSourceSettings.rulesData,
           let decoded = try? JSONDecoder().decode([InputSourceRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = InputSourceStore.defaultRules
        }
        self.isEnabled = InputSourceSettings.isEnabled
        self.isDomainEnabled = InputSourceSettings.isDomainEnabled
    }

    /// Must be called once at launch: `init` assigns directly and therefore
    /// does not fire `didSet`, so the monitor would not start until the user
    /// toggled something.
    func activate() {
        InputSourceMonitor.shared.reload()
    }

    /// Re-read persisted state after an iCloud settings sync pulls newer values.
    func reload() {
        if let data = InputSourceSettings.rulesData,
           let decoded = try? JSONDecoder().decode([InputSourceRule].self, from: data) {
            rules = decoded
        }
        isEnabled = InputSourceSettings.isEnabled
        isDomainEnabled = InputSourceSettings.isDomainEnabled
    }

    func addRule(_ rule: InputSourceRule) {
        rules.append(rule)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func updateRule(_ rule: InputSourceRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func resetToDefaults() {
        rules = InputSourceStore.defaultRules
    }

    // MARK: - Persistence

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            InputSourceSettings.rulesData = data
        }
    }

    /// Sensible starter rules for Chinese-English bilingual users.
    private static var defaultRules: [InputSourceRule] {
        let sources = InputSourceController.enabledInputSources
        let abc = sources.first { $0.sourceID.hasPrefix("com.apple.keylayout.ABC")
            || $0.sourceID == "com.apple.keylayout.US" }
        let pinyin = sources.first { $0.sourceID.contains("Pinyin") }

        var defaults: [InputSourceRule] = []
        if let abc {
            defaults.append(InputSourceRule(
                bundleID: "com.apple.dt.Xcode",
                inputSourceID: abc.sourceID,
                inputSourceName: abc.localizedName
            ))
            defaults.append(InputSourceRule(
                bundleID: "com.apple.Terminal",
                inputSourceID: abc.sourceID,
                inputSourceName: abc.localizedName
            ))
        }
        if let pinyin {
            defaults.append(InputSourceRule(
                bundleID: "com.tencent.xinWeChat",
                inputSourceID: pinyin.sourceID,
                inputSourceName: pinyin.localizedName
            ))
        }
        return defaults
    }
}
