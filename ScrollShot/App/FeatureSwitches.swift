import AppKit
import Combine
import KeyboardShortcuts

/// Master on/off switches for every background feature, surfaced as per-row
/// toggles in the Settings sidebar. "Off" means truly stopped — timers, event
/// taps, monitors, status items and hotkeys all come down, not just hidden UI.
///
/// Most features reuse their existing UserDefaults key (so existing users keep
/// their state); four keys are new (`shelf.enabled`, `launcher.enabled`,
/// `aiChat.enabled`, `brightness.enabled`) and default to ON to preserve
/// current behavior. New keys must also be registered in
/// `SettingsSync.syncedKeys` to sync across Macs.
@MainActor
final class FeatureSwitches: ObservableObject {
    static let shared = FeatureSwitches()

    /// Bumped after every change so observing views re-render.
    @Published private(set) var revision = 0

    private let d = UserDefaults.standard

    private init() {}

    enum AppFeature: CaseIterable {
        case usage, inputStats, clipboard, shelf, launcher, aiChat
        case keyMapping, inputSource, brightness, mouseAccel, windowTiling, systemMonitor
        case smartPaste, deviceBattery, agentBridge
    }

    // MARK: State

    func isEnabled(_ f: AppFeature) -> Bool {
        switch f {
        case .usage:         return UsageMonitorSettings.enabled
        case .inputStats:    return InputStatsSettings.enabled
        case .clipboard:     return ClipboardMonitor.isEnabled
        case .shelf:         return d.object(forKey: "shelf.enabled") as? Bool ?? true
        case .launcher:      return d.object(forKey: "launcher.enabled") as? Bool ?? true
        case .aiChat:        return d.object(forKey: "aiChat.enabled") as? Bool ?? true
        case .keyMapping:    return KeyMappingStore.shared.isEnabled
        case .inputSource:   return InputSourceSettings.isEnabled
        case .brightness:    return d.object(forKey: "brightness.enabled") as? Bool ?? true
        case .mouseAccel:    return MouseAccelerationController.enabled // "关闭加速"开 = 功能开
        case .windowTiling:  return WindowTilingController.enabled
        case .systemMonitor: return SystemMonitorSettings.enabled
        case .smartPaste:    return SmartPasteController.isEnabled
        case .deviceBattery: return d.object(forKey: DeviceBatteryStore.enabledKey) as? Bool ?? true
        case .agentBridge:   return d.object(forKey: "agentBridge.enabled") as? Bool ?? false // 刘海审批,默认关
        }
    }

    func setEnabled(_ f: AppFeature, _ on: Bool) {
        write(f, on)
        apply(f)
        revision += 1
    }

    private func write(_ f: AppFeature, _ on: Bool) {
        switch f {
        case .usage:         UsageMonitorSettings.enabled = on
        case .inputStats:    InputStatsSettings.enabled = on   // setter reloads status item
        case .clipboard:     ClipboardMonitor.isEnabled = on
        case .shelf:         d.set(on, forKey: "shelf.enabled")
        case .launcher:      d.set(on, forKey: "launcher.enabled")
        case .aiChat:        d.set(on, forKey: "aiChat.enabled")
        case .keyMapping:    KeyMappingStore.shared.isEnabled = on   // didSet → remapper
        case .inputSource:   InputSourceStore.shared.isEnabled = on  // didSet → monitor reload
        case .brightness:    d.set(on, forKey: "brightness.enabled")
        case .mouseAccel:    MouseAccelerationController.enabled = on
        case .windowTiling:  WindowTilingController.enabled = on
        case .systemMonitor: SystemMonitorSettings.enabled = on
        case .smartPaste:    SmartPasteController.isEnabled = on
        case .deviceBattery: d.set(on, forKey: DeviceBatteryStore.enabledKey)
        case .agentBridge:   d.set(on, forKey: "agentBridge.enabled")
        }
    }

    /// Apply the current stored state of a feature (start or stop its resources).
    func apply(_ f: AppFeature) {
        let on = isEnabled(f)
        switch f {
        case .usage:
            UsageStatusItemController.shared.reload()
        case .inputStats:
            InputStatsEventMonitor.shared.updateMonitors()
            if on { InputStatsSync.shared.startSyncing() } else { InputStatsSync.shared.stopSyncing() }
        case .clipboard:
            if on { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
        case .shelf:
            if on {
                if ShelfSettings.autoPresent { ShelfWindowController.shared.startAutoPresent() }
                KeyboardShortcuts.enable(.shelf)
            } else {
                ShelfWindowController.shared.stopAutoPresent()
                ShelfWindowController.shared.dismiss()
                KeyboardShortcuts.disable(.shelf)
            }
        case .launcher:
            if on { KeyboardShortcuts.enable(.launcher) } else { KeyboardShortcuts.disable(.launcher) }
        case .aiChat:
            if on { KeyboardShortcuts.enable(.aiChat) } else { KeyboardShortcuts.disable(.aiChat) }
        case .keyMapping:
            break // KeyMappingStore.isEnabled didSet already notified the remapper
        case .inputSource:
            break // InputSourceStore.isEnabled didSet already reloaded the monitor
        case .brightness:
            BrightnessKeyInterceptor.shared.isEnabled =
                on && M1DDCBrightnessController.shared.interceptBrightnessKeys
            if on {
                M1DDCBrightnessController.shared.refreshDisplays()
                BrightnessStatusItemController.shared.start()
            } else {
                BrightnessStatusItemController.shared.stop()
            }
        case .mouseAccel:
            MouseAccelerationController.shared.reload()
        case .windowTiling:
            WindowTilingController.shared.start() // applies the enabled state
        case .systemMonitor:
            SystemMonitorStatusItems.shared.reload()
        case .smartPaste:
            if on { SmartPasteController.shared.start() } else { SmartPasteController.shared.stop() }
        case .deviceBattery:
            if on { DeviceBatteryStatusItemController.shared.start() } else { DeviceBatteryStatusItemController.shared.stop() }
        case .agentBridge:
            if on {
                AgentBridgeSetup.repairIfNeeded()   // 自愈:开关开但 hook 没了 → 重装
                AgentBridgeServer.shared.start()
                NotchPanelController.shared.start()
            } else {
                AgentBridgeServer.shared.stop()
                NotchPanelController.shared.stop()
            }
        }
    }

    /// Re-apply every feature's stored state (call once at launch after the
    /// controllers exist; safe because every apply path is idempotent).
    func applyAll() {
        for f in AppFeature.allCases { apply(f) }
    }
}
