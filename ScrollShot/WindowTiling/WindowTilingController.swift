import AppKit
import ApplicationServices
import KeyboardShortcuts

/// Registers the window-tiling global shortcuts and dispatches them to
/// `WindowTiler`. Opt-in (default off); enabling activates the shortcuts the
/// user has assigned in 设置.
@MainActor
final class WindowTilingController {
    static let shared = WindowTilingController()

    private static let enabledKey = "windowTiling.enabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private var registered = false
    private init() {}

    /// Registers handlers once, then applies the enabled state.
    func start() {
        if !registered {
            registered = true
            for tile in Tile.allCases {
                KeyboardShortcuts.onKeyUp(for: tile.shortcutName) {
                    MainActor.assumeIsolated { WindowTilingController.shared.handle(tile) }
                }
            }
        }
        applyEnabled()
    }

    /// Call after the enabled toggle changes.
    func reload() { applyEnabled() }

    private func applyEnabled() {
        for tile in Tile.allCases {
            if Self.enabled {
                KeyboardShortcuts.enable(tile.shortcutName)
            } else {
                KeyboardShortcuts.disable(tile.shortcutName)
            }
        }
    }

    private func handle(_ tile: Tile) {
        guard Self.enabled else { return }
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            return
        }
        WindowTiler.apply(tile)
    }

    private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = AppConfig.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}
