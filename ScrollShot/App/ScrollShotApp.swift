import SwiftUI
import AppKit
import KeyboardShortcuts
import CoreGraphics

@main
struct ScrollShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar items are AppKit NSStatusItems (MainMenuBarController +
        // UsageStatusItemController) — a SwiftUI MenuBarExtra can't be hidden
        // without the isInserted re-render hang. Only Settings stays in SwiftUI.
        Settings {
            PreferencesView()
        }
    }
}

/// Brings the Settings window above every other window — including windows of
/// other apps and on the currently active Space — which an accessory app does
/// not get for free. Retried briefly because the window may not exist yet on the
/// runloop tick when Settings is first opened.
@MainActor
enum SettingsWindowOpener {
    /// SwiftUI gives its Settings scene window this stable identifier.
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    static func raiseSoon() {
        raise()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { raise() }
    }

    private static func raise() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == settingsWindowID {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app process is hosting the XCTest bundle. Test builds are
    /// signed with the development certificate, which has a different code-
    /// signing identity than the released /Applications copy; that causes macOS
    /// to treat accessibility grants as separate and repeatedly prompt the user.
    /// In test mode we skip all permission-touching services so tests can run
    /// without prompts. See TESTING.md for details.
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar background app: no Dock icon, but can still show windows.
        NSApp.setActivationPolicy(.accessory)

        // Initialize the runtime language switcher before any UI (menu bar,
        // status items, windows) is built, so NSLocalizedString resolves to the
        // user's chosen language instead of falling back to raw keys.
        _ = LocalizationManager.shared

        // Pull newer settings synced from the user's other Macs (iCloud Drive)
        // into UserDefaults FIRST, so the singletons below initialize from the
        // synced values on a fresh install.
        SettingsSync.shared.adoptRemoteIfNewer()
        AppTheme.applyStored()

        // Launch diagnostic: version + whether macOS currently recognizes the
        // screen-recording grant for THIS binary's signing identity. If this logs
        // `false` right after you've granted it, the grant is keyed to a different
        // signature (e.g. a dev build vs the released Developer-ID build).
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        Diag.permission.info("launch ScrollShot \(version, privacy: .public) (\(build, privacy: .public)) — screen-recording preflight = \(CGPreflightScreenCaptureAccess(), privacy: .public)")

        guard !isRunningUnitTests else {
            // In unit-test mode we only do the bare minimum: the app process must
            // exist so the XCTest bundle can load, but we skip every service that
            // touches permissions, the menu bar, global hotkeys, or iCloud files.
            Diag.permission.info("launch in unit-test host mode — skipping services")
            return
        }

        // Single instance: replace any other running copy (e.g. the installed
        // /Applications one while testing a build/export one). Two copies both
        // register the hotkeys and each opens its own picker windows — the user
        // saw stacked, seemingly frozen search windows. Must stay BELOW the
        // unit-test guard: the test host launches this app too, and it must not
        // kill the user's running installed copy on every `xcodebuild test`.
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.scrollshot.app")
        where app.processIdentifier != myPID {
            app.terminate()
        }

        // Start Sparkle now so scheduled background update checks run even if the
        // menu is never opened.
        _ = UpdaterController.shared

        // Warm up ScreenCaptureKit so the first screenshot isn't delayed by the
        // cold SCShareableContent query.
        CaptureController.shared.prewarm()

        // Warn if another screenshot utility is running; they often hook global
        // mouse/keyboard events and can steal the first drag from ScrollShot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ConflictDetector.showConflictAlertIfNeeded()
        }

        // Start the keyboard remapper if the user has enabled it and granted
        // Accessibility access. The store loads persisted rules and presets.
        // Start the keyboard remapper from its persisted state. `reload()` also
        // re-reads UserDefaults, so it picks up any rules just adopted from
        // iCloud even if the store initialized before the pull above.
        KeyMappingStore.shared.reload()

        // Start the Input Source Pro-style auto-switcher from its persisted state.
        // `activate()` is required because `init` assignments don't fire didSet.
        InputSourceStore.shared.activate()

        // Shift-tap 中/EN toggle: register with the shared event tap if enabled.
        ShiftInputToggle.shared.updateRegistration()

        // 智能粘贴：终端里 Ctrl+V 按剪贴板内容自动决定贴图/贴字（默认开）。
        if FeatureSwitches.shared.isEnabled(.smartPaste) { SmartPasteController.shared.start() }

        // Caps Lock 去延迟：若用户开启，重应用 hidutil 覆盖（重启后失效需重刷）。
        CapsLockDelayOverride.applyNow()

        // Primary menu-bar item (camera + main menu), honouring the "显示相机图标"
        // setting. AppKit, so it can actually be hidden without a SwiftUI hang.
        MainMenuBarController.shared.reload()

        // Show the Claude usage status item if enabled (CodexBar-style live meter).
        UsageStatusItemController.shared.start()

        // Input statistics (keyboard/mouse/scroll) — starts the menu-bar item and,
        // if accessibility is already granted, installs its NSEvent monitors.
        InputStatsStatusItemController.shared.reload()
        InputStatsEventMonitor.shared.updateMonitors()

        // External display brightness: discover DDC-compatible monitors and show
        // the sun status item when any are found. Both calls self-guard on the
        // feature switch; skip touching the singletons entirely when it's off.
        if FeatureSwitches.shared.isEnabled(.brightness) {
            M1DDCBrightnessController.shared.refreshDisplays()
            BrightnessStatusItemController.shared.start()
        }

        // Mouse acceleration off (1:1 precise, ExactMouse-style) if enabled.
        MouseAccelerationController.shared.reload()

        // Keyboard window tiling (opt-in): register shortcut handlers.
        WindowTilingController.shared.start()

        // System monitor menu-bar item (opt-in): CPU / mem / net / temp.
        SystemMonitorStatusItems.shared.start()

        // 设备电量菜单栏项：本机电池 + Magic 外设 + AirPods/Beats 蓝牙广播。
        if FeatureSwitches.shared.isEnabled(.deviceBattery) {
            DeviceBatteryStatusItemController.shared.start()
        }

        // 刘海审批：AI agent 权限/提问卡片（默认关，开关打开时启动 socket
        // 服务 + 刘海面板；apply 幂等，关闭时是空操作）。
        FeatureSwitches.shared.apply(.agentBridge)

        // Anonymous, opt-in usage heartbeat (OFF by default; no-op until the
        // user turns it on AND an endpoint is configured).
        AnalyticsReporter.shared.reportLaunch()

        // Clipboard history (Raycast-style). Poll the pasteboard if recording is on.
        if ClipboardMonitor.isEnabled { ClipboardMonitor.shared.start() }

        KeyboardShortcuts.onKeyUp(for: .captureRegion) {
            // KeyboardShortcuts invokes handlers on the main thread.
            MainActor.assumeIsolated {
                CaptureController.shared.trigger()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .clipboardHistory) {
            MainActor.assumeIsolated {
                ClipboardWindowController.shared.toggle()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .launcher) {
            MainActor.assumeIsolated {
                LauncherWindowController.shared.toggle()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .aiChat) {
            MainActor.assumeIsolated {
                ChatWindowController.shared.show()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .shelf) {
            MainActor.assumeIsolated {
                ShelfWindowController.shared.toggle()
            }
        }
        // Hotkey-only features honour their master switches from the sidebar.
        if !FeatureSwitches.shared.isEnabled(.launcher) { KeyboardShortcuts.disable(.launcher) }
        if !FeatureSwitches.shared.isEnabled(.aiChat) { KeyboardShortcuts.disable(.aiChat) }
        if !FeatureSwitches.shared.isEnabled(.shelf) { KeyboardShortcuts.disable(.shelf) }
        // Yoink-style shelf: watch for drags so it can auto-present (if enabled).
        if FeatureSwitches.shared.isEnabled(.shelf), ShelfSettings.autoPresent {
            ShelfWindowController.shared.startAutoPresent()
        }

        // Warm the app index so the first ⌥Space is instant.
        DispatchQueue.main.async { AppIndex.shared.buildIfNeeded() }

        // Now that our state is loaded, keep it synced with the user's other
        // Macs (push local changes, pull remote ones).
        SettingsSync.shared.startSyncing()
        InputStatsSync.shared.startSyncing()

        // 内存水位看门狗：兜底 macOS 26 SkyLight 事件 tap 泄漏，超阈值时自重启。
        MemoryWatchdog.shared.start()
    }

    /// Escape hatch: if the user hides BOTH menu-bar icons there's no way back
    /// in, so re-opening the app (double-click it in Finder) reopens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.show()
        return true
    }
}
