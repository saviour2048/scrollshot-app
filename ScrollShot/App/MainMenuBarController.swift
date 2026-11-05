import AppKit

/// The app's primary menu-bar item (camera icon + main menu), in AppKit.
///
/// This replaces the SwiftUI `MenuBarExtra`. `MenuBarExtra(isInserted:)` — the
/// only way to hide a SwiftUI menu-bar item — triggers an infinite re-render
/// loop (the 99% CPU "Not Responding" hang we hit), so it can't come back. An
/// `NSStatusItem` we add/remove directly is safe and honours the "显示截图相机
/// 图标" switch. The same menu is offered on the usage meter's right-click, so
/// Settings / Quit stay reachable even when this icon is hidden.
@MainActor
final class MainMenuBarController: NSObject, NSMenuDelegate {
    static let shared = MainMenuBarController()
    private var statusItem: NSStatusItem?
    private override init() { super.init() }

    /// Show or hide the camera status item per the setting. Call at launch and
    /// whenever "显示截图相机图标" changes.
    func reload() {
        let show = UserDefaults.standard.object(forKey: "menubar.showCamera") as? Bool ?? true
        if show {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                         accessibilityDescription: AppConfig.appName)
            item.menu = makeMainMenu()
            statusItem = item
        } else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
        }
    }

    /// The full main menu. Also reused by the usage meter's right-click.
    func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        add(menu, L("menu.launcher"), #selector(openLauncher))
        add(menu, L("menu.capture"), #selector(triggerCapture))
        add(menu, L("menu.aiChat"), #selector(openChat))
        add(menu, L("menu.clipboard"), #selector(openClipboard))
        add(menu, L("menu.shelf"), #selector(openShelf))
        add(menu, L("menu.diskScan"), #selector(openDiskScan))
        add(menu, L("menu.keyChatter"), #selector(openKeyChatter))
        menu.addItem(.separator())
        add(menu, L("menu.keyMapping"), #selector(toggleKeyMapping))
        add(menu, L("menu.inputSource"), #selector(toggleInputSource))
        add(menu, L("menu.usage"), #selector(toggleUsage))
        add(menu, L("menu.inputStats"), #selector(toggleInputStats))
        add(menu, L("menu.deviceBattery"), #selector(toggleDeviceBattery))
        menu.addItem(.separator())
        add(menu, L("menu.preferences"), #selector(openSettings))
        add(menu, L("menu.checkUpdates"), #selector(checkUpdates))
        add(menu, String(format: L("menu.about"), AppConfig.appName), #selector(showAbout))
        menu.addItem(.separator())
        add(menu, String(format: L("menu.quit"), AppConfig.appName), #selector(quit)).keyEquivalent = "q"
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    /// Refresh the two toggle checkmarks each time a menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleKeyMapping):  item.state = KeyMappingStore.shared.isEnabled ? .on : .off
            case #selector(toggleInputSource): item.state = InputSourceStore.shared.isEnabled ? .on : .off
            case #selector(toggleUsage):       item.state = UsageMonitorSettings.enabled ? .on : .off
            case #selector(toggleInputStats):  item.state = InputStatsSettings.enabled ? .on : .off
            case #selector(toggleDeviceBattery): item.state = FeatureSwitches.shared.isEnabled(.deviceBattery) ? .on : .off
            // Features switched off in Settings drop out of the menu entirely.
            case #selector(openLauncher):      item.isHidden = !FeatureSwitches.shared.isEnabled(.launcher)
            case #selector(openChat):          item.isHidden = !FeatureSwitches.shared.isEnabled(.aiChat)
            case #selector(openShelf):         item.isHidden = !FeatureSwitches.shared.isEnabled(.shelf)
            default: break
            }
        }
    }

    // MARK: Actions

    @objc private func openLauncher() { LauncherWindowController.shared.show() }
    @objc private func openChat() { ChatWindowController.shared.show() }
    @objc private func triggerCapture() { CaptureController.shared.trigger() }
    @objc private func openClipboard() { ClipboardWindowController.shared.show() }
    @objc private func openShelf() { ShelfWindowController.shared.toggle() }
    @objc private func openDiskScan() { DiskScanWindowController.shared.open() }
    @objc private func openKeyChatter() { KeyChatterWindowController.shared.show() }
    @objc private func toggleKeyMapping() { KeyMappingStore.shared.isEnabled.toggle() }
    @objc private func toggleInputSource() { InputSourceStore.shared.isEnabled.toggle() }
    @objc private func toggleUsage() {
        FeatureSwitches.shared.setEnabled(.usage, !FeatureSwitches.shared.isEnabled(.usage))
    }
    @objc private func toggleInputStats() {
        let on = !FeatureSwitches.shared.isEnabled(.inputStats)
        FeatureSwitches.shared.setEnabled(.inputStats, on)
        if on, !InputEventTap.shared.isAccessibilityGranted() {
            _ = InputEventTap.shared.promptAccessibilityTrust()
        }
    }
    @objc private func toggleDeviceBattery() {
        FeatureSwitches.shared.setEnabled(.deviceBattery, !FeatureSwitches.shared.isEnabled(.deviceBattery))
    }
    @objc private func openSettings() { PreferencesWindowController.shared.show() }
    @objc private func checkUpdates() { UpdaterController.shared.checkForUpdates() }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
