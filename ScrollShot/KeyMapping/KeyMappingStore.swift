import Foundation
import Combine

/// Persists the user's keyboard-remapping rules and broadcasts changes.
@MainActor
final class KeyMappingStore: ObservableObject {
    static let shared = KeyMappingStore()

    private static let rulesKey = "KeyMappingStore.rules"
    private static let enabledKey = "KeyMappingStore.enabled"

    @Published var rules: [KeyMappingRule] {
        didSet {
            saveRules()
            notifyRemapper()
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            notifyRemapper()
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([KeyMappingRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = KeyMappingRule.vimArrowPresets
        }
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.rulesKey)
        }
    }

    private func notifyRemapper() {
        KeyboardRemapper.shared.update(rules: isEnabled ? rules : [])
    }

    /// Start the event-tap from the persisted state. MUST be called once at
    /// launch: `init` assigns `rules`/`isEnabled` directly, which does NOT fire
    /// their `didSet`, so without this the tap is never created until the user
    /// happens to toggle a rule. (This was why remapping silently did nothing.)
    func activate() {
        notifyRemapper()
    }

    /// Re-read the persisted rules/enabled state and re-apply to the running
    /// remapper. Called after an iCloud settings sync pulls newer values in.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([KeyMappingRule].self, from: data) {
            rules = decoded            // didSet → saveRules + notifyRemapper
        }
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func addRule(_ rule: KeyMappingRule) {
        rules.append(rule)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func resetToDefaults() {
        rules = KeyMappingRule.vimArrowPresets
    }
}
