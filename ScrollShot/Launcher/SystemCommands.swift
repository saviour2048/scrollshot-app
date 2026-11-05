import AppKit
import ApplicationServices
import CoreAudio
import IOKit.pwr_mgt

/// macOS system-level commands exposed in the ⌥Space launcher.
/// Kept in a dedicated file so the main launcher list stays readable.
enum SystemCommands {
    static var all: [LauncherCommand] {
        [
            LauncherCommand(id: "empty-trash", title: L("cmd.emptyTrash"),
                            systemImage: "trash", keywords: ["empty", "trash", L("cmd.emptyTrash")]) {
                emptyTrash()
            },
            LauncherCommand(id: "sleep", title: L("cmd.sleep"),
                            systemImage: "moon", keywords: ["sleep", L("cmd.sleep")]) {
                sleepSystem()
            },
            LauncherCommand(id: "lock-screen", title: L("cmd.lockScreen"),
                            systemImage: "lock", keywords: ["lock", L("cmd.lockScreen"), "screen"]) {
                lockScreen()
            },
            LauncherCommand(id: "restart", title: L("cmd.restart"),
                            systemImage: "arrow.clockwise", keywords: ["restart", L("cmd.restart")]) {
                runAppleScript("tell application \"System Events\" to restart", action: "重启")
            },
            LauncherCommand(id: "shutdown", title: L("cmd.shutdown"),
                            systemImage: "power", keywords: ["shutdown", L("cmd.shutdown")]) {
                runAppleScript("tell application \"System Events\" to shut down", action: "关机")
            },
            LauncherCommand(id: "logout", title: L("cmd.logout"),
                            systemImage: "person.crop.circle.badge.minus", keywords: ["logout", L("cmd.logout")]) {
                runAppleScript("tell application \"System Events\" to log out", action: "注销")
            },
            LauncherCommand(id: "show-desktop", title: L("cmd.showDesktop"),
                            systemImage: "menubar.dock.rectangle", keywords: ["desktop", L("cmd.showDesktop")]) {
                showDesktop()
            },
            LauncherCommand(id: "system-settings", title: L("cmd.systemSettings"),
                            systemImage: "gear", keywords: ["settings", L("cmd.systemSettings"), "system"]) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
            },
            LauncherCommand(id: "activity-monitor", title: L("cmd.activityMonitor"),
                            systemImage: "cpu", keywords: ["activity", "monitor", L("cmd.activityMonitor"), "cpu"]) {
                openApp(bundleIdentifier: "com.apple.ActivityMonitor")
            },
            LauncherCommand(id: "mute-volume", title: L("cmd.mute"),
                            systemImage: "speaker.slash", keywords: ["mute", L("cmd.mute"), "volume", "unmute", "静音", "取消静音"]) {
                toggleMute()
            },
        ]
    }

    // MARK: - Helpers

    private static func openApp(bundleIdentifier: String) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        if let url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    /// Runs an AppleScript that controls another app (Finder / System Events)
    /// IN-PROCESS. Controlling another app needs the AUTOMATION permission, not
    /// Accessibility — so we do NOT gate on AXIsProcessTrusted here. A hardened-
    /// runtime app also needs the `com.apple.security.automation.apple-events`
    /// entitlement; without it the event is dropped SILENTLY (no effect, no
    /// error — that was the sleep bug). We send in-process (NSAppleScript) so the
    /// entitlement applies and TCC attributes the request to ScrollShot (clean
    /// first-run prompt), rather than spawning osascript (attribution is murky).
    /// Returns true on success.
    @discardableResult
    private static func runAppleScript(_ source: String, action: String = "系统命令") -> Bool {
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let err = errorInfo else { return true }

        let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            // Not authorized to send Apple events → Automation not granted.
            showCommandFailedAlert(message:
                "\(action)需要「自动化」权限。请到 系统设置 → 隐私与安全性 → 自动化,允许 ScrollShot 控制「\(source.contains("Finder") ? "访达" : "系统事件")」,然后重试。")
        } else {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "错误码 \(code)"
            showCommandFailedAlert(message: "\(action)失败:\(msg)")
        }
        return false
    }

    private static func emptyTrash() {
        // Finder FIRST — it is the canonical way to empty the Trash on macOS.
        // There is no public API for it, and a non-sandboxed app WITHOUT Full
        // Disk Access cannot even read ~/.Trash (verified: `ls ~/.Trash` →
        // "Operation not permitted"), so a FileManager-first approach always
        // fails on the home trash. Finder owns the permission and does the work.
        if runAppleScript("tell application \"Finder\" to empty trash", action: "清空废纸篓") {
            // Home trash done; also sweep any external-volume trashes we CAN
            // reach directly (those aren't TCC-protected like ~/.Trash).
            emptyExternalVolumeTrashes()
        }
    }

    /// Delete contents of reachable external-volume trashes (`/Volumes/*/.Trashes/<uid>`).
    /// These aren't behind the same TCC wall as the home `~/.Trash`.
    private static func emptyExternalVolumeTrashes() {
        let uid = String(getuid())
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for volume in volumes {
            let trash = volume.appendingPathComponent(".Trashes").appendingPathComponent(uid)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: nil, options: []) else { continue }
            for url in contents where url.lastPathComponent != ".DS_Store" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func sleepSystem() {
        // Canonical no-root sleep, matching maintained open-source sleep apps
        // (e.g. github.com/DannyShy/sleeptimer): get the power-management port
        // via IOPMFindPowerManagement — VERIFIED to return a valid port for a
        // normal user with no root — then IOPMSleepSystem. No permission prompt,
        // no AppleScript. The earlier bug used IOServiceOpen(IOPMrootDomain),
        // which DOES need root and returned -536870174 (kIOReturnNotPrivileged).
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else {
            showCommandFailedAlert(message: "无法进入睡眠状态:连接电源管理失败")
            return
        }
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess {
            showCommandFailedAlert(message: "无法进入睡眠状态 (IOKit \(result))")
        }
    }

    private static func lockScreen() {
        // Use the private loginwindow API. This is the same mechanism used by
        // ⌃⌘Q and works without Accessibility access.
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/loginwindow.framework/loginwindow",
            RTLD_LAZY
        ) else {
            // Fallback to the keyboard shortcut if the private symbol is unavailable.
            sendKeyCode(12, modifiers: [.maskCommand, .maskControl])
            return
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            sendKeyCode(12, modifiers: [.maskCommand, .maskControl])
            return
        }
        typealias LockScreenFunc = @convention(c) () -> Void
        let lock = unsafeBitCast(symbol, to: LockScreenFunc.self)
        lock()
    }

    private static func showDesktop() {
        guard ensureAccessibilityGranted() else { return }
        // "Show Desktop" is bound to F11 + Fn (verified in symbolichotkeys id 36:
        // keycode 103, modifier 0x800000 = Fn). A bare F11 doesn't match the
        // hotkey, so include the Fn flag.
        sendKeyCode(103, modifiers: [.maskSecondaryFn])
    }

    private static func sendKeyCode(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Toggle mute on the default output device (mute ⇄ unmute), so one command
    /// serves both directions. Uses CoreAudio directly (no Accessibility needed).
    private static func toggleMute() {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &dataSize, &deviceID) == noErr else {
            return
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // Some outputs (aggregate devices, certain DACs) don't support mute.
        guard AudioObjectHasProperty(deviceID, &muteAddress) else {
            showCommandFailedAlert(message: "当前输出设备不支持静音开关。")
            return
        }
        var current: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &sz, &current)
        var newValue: UInt32 = current == 0 ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &newValue)
    }

    // MARK: - Accessibility permission

    private static func ensureAccessibilityGranted() -> Bool {
        if AXIsProcessTrusted() { return true }

        if AppConfig.suppressesPermissionPrompts {
            showCommandFailedAlert(message: "系统命令需要辅助功能权限。请关闭 SCROLLSHOT_SKIP_PERMISSION_PROMPTS 后重试，或手动在系统设置中授权。")
            return false
        }

        // Surface the system Accessibility prompt.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        showPermissionRequiredAlert()
        return false
    }

    private static func showPermissionRequiredAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText = "请在 系统设置 ▸ 隐私与安全性 ▸ 辅助功能 中勾选 ScrollShot，然后重新运行该命令。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = AppConfig.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func showCommandFailedAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "命令未执行"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
