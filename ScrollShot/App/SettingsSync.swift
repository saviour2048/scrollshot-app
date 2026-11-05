import Foundation
import AppKit

/// Syncs the user's personal ScrollShot settings across their Macs.
///
/// ScrollShot is a non-sandboxed Developer-ID app, so instead of the iCloud
/// key-value store — which would need an iCloud entitlement plus a Developer-ID
/// provisioning profile that's re-validated at every launch and can EXPIRE and
/// block the app from opening — we write a small JSON file into the user's
/// iCloud Drive folder. iCloud Drive syncs it across their Macs under their own
/// Apple ID: no login, no entitlement, no portal setup. When iCloud Drive is
/// turned off we fall back to Application Support (settings still persist
/// locally, just not cross-device).
///
/// Conflict policy is last-write-wins on the whole payload by `updatedAt`, which
/// is fine for personal settings that are rarely edited on two Macs at once.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    /// The UserDefaults keys that make up "my ScrollShot settings".
    private static let syncedKeys = [
        "appearance.mode",                  // 浅色 / 深色 / 跟随系统
        "menubar.showCamera",              // 菜单栏相机图标
        "usage.enabled",                   // Claude 用量监控开关
        "usage.menuBarSource",             // 菜单栏用量数据来源(旧版单选,保留兼容)
        "usage.menuBarLeft",               // 菜单栏用量表左列来源
        "usage.menuBarRight",              // 菜单栏用量表右列来源
        "usage.menuBarMetric",             // 菜单栏显示的指标
        "usage.refreshInterval",           // 用量刷新间隔
        "KeyMappingStore.enabled",         // 键盘映射开关
        "KeyMappingStore.rules",           // 键盘映射规则(JSON Data)
        "saveDirectoryPath",               // 截图保存位置
        "KeyboardShortcuts_captureRegion", // 截图快捷键
        "clipboard.enabled",               // 剪贴板历史开关
        "KeyboardShortcuts_clipboardHistory", // 剪贴板快捷键
        "KeyboardShortcuts_launcher",      // 启动器快捷键
        "launcher.quicklinks",             // 自定义搜索快链
        "llm.baseURL",                     // AI 对话接口地址(Key 在钥匙串,绝不同步)
        "llm.model",                       // AI 对话模型名
        "KeyboardShortcuts_aiChat",        // AI 对话快捷键
        "KeyboardShortcuts_shelf",         // 暂存架快捷键
        "shelf.autoPresent",               // 暂存架拖拽自动浮现
        "kimi.baseURL",                    // Kimi 用量接口地址(Key 在钥匙串,绝不同步)
        "inputStats.enabled",              // 输入统计开关
        "inputStats.showInMenuBar",        // 输入统计菜单栏显示
        "mouseAccel.disableAcceleration",  // 关闭鼠标加速开关
        "mouseAccel.speed",              // 精准鼠标跟踪速度
        "mouseAccel.speedCustomized",    // 是否接管鼠标速度(否则留给系统/Options+)
        "InputSourceStore.enabled",          // 输入法自动切换开关
        "InputSourceStore.domainEnabled",    // 输入法按网站域名切换开关
        "InputSourceStore.rules",            // 输入法自动切换规则(JSON Data)
        "shiftToggle.enabled",               // Shift 单击切换中英开关
        "shiftToggle.side",                  // Shift 触发键(left/right/any)
        "shiftToggle.latinSourceID",         // 英文输入法
        "shiftToggle.cjkSourceID",           // 中文输入法
        "capsLock.delayOverride",            // Caps Lock 去长按延迟开关
        "windowTiling.enabled",              // 键盘窗口分屏开关
        "KeyboardShortcuts_tileLeftHalf",    // 分屏:左半屏
        "KeyboardShortcuts_tileRightHalf",   // 分屏:右半屏
        "KeyboardShortcuts_tileTopHalf",     // 分屏:上半屏
        "KeyboardShortcuts_tileBottomHalf",  // 分屏:下半屏
        "KeyboardShortcuts_tileTopLeft",     // 分屏:左上角
        "KeyboardShortcuts_tileTopRight",    // 分屏:右上角
        "KeyboardShortcuts_tileBottomLeft",  // 分屏:左下角
        "KeyboardShortcuts_tileBottomRight", // 分屏:右下角
        "KeyboardShortcuts_tileMaximize",    // 分屏:最大化
        "KeyboardShortcuts_tileCenter",      // 分屏:居中
        "KeyboardShortcuts_tileNextDisplay",     // 分屏:移到下一屏
        "KeyboardShortcuts_tilePreviousDisplay", // 分屏:移到上一屏
        "sysmon.enabled",                    // 系统监控总开关
        "sysmon.show.cpu",                   // 系统监控:显示 CPU
        "sysmon.show.memory",                // 系统监控:显示内存
        "sysmon.show.network",               // 系统监控:显示网速
        "sysmon.show.temperature",           // 系统监控:显示温度
        "sysmon.show.fan",                   // 系统监控:显示风扇转速
        "sysmon.show.memPressure",           // 系统监控:显示内存压力曲线
        "shelf.enabled",                     // 暂存架总开关(侧栏功能开关)
        "launcher.enabled",                  // 启动器总开关(侧栏功能开关)
        "aiChat.enabled",                    // AI 对话总开关(侧栏功能开关)
        "brightness.enabled",                // 外接显示器亮度总开关(侧栏功能开关)
        "smartPaste.enabled",                // 智能粘贴(终端 Ctrl+V)总开关
        "deviceBattery.enabled",             // 设备电量监控总开关(侧栏功能开关)
        "deviceBattery.refreshInterval",     // 设备电量采集间隔(秒)
        "deviceBattery.menuBarSource",       // 设备电量:状态栏显示哪台设备
        "agentBridge.enabled",               // 刘海审批(AI agent 权限卡片)总开关
    ]

    /// Private bookkeeping: the `updatedAt` of the last payload we wrote or
    /// applied, so we ignore our own writes and stale snapshots.
    private static let lastSyncedAtKey = "settingsSync.lastAppliedAt"

    private let defaults = UserDefaults.standard
    private var applyingRemote = false
    private var pushDebounce: DispatchWorkItem?
    private var pollTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Adopt newer remote settings BEFORE the app's singletons initialize, so a
    /// fresh Mac reads the synced values on first launch. Call at the very top
    /// of `applicationDidFinishLaunching`.
    func adoptRemoteIfNewer() {
        pull(applyLive: false)
    }

    /// Once the singletons are up: make sure the file reflects our state, then
    /// watch both directions. Call near the end of `applicationDidFinishLaunching`.
    func startSyncing() {
        pushSnapshot()
        // Block observer on the main queue: didChangeNotification can be posted
        // off-main (external / iCloud-driven changes), and we touch main-actor
        // state, so force delivery onto main.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.localDefaultsChanged() }
        }
        // Light poll for remote (iCloud) changes; the file is tiny + low-churn.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pull(applyLive: true) }
        }
    }

    /// Whether cross-device (iCloud Drive) sync is actually active, vs the
    /// local-only fallback. Surface this in Preferences.
    var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.cloudDocsDir.path)
    }

    // MARK: - File location

    private static var cloudDocsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    /// Resolved once on first access: the location only depends on directory
    /// constants, and recomputing it hit the file system on every 30s poll.
    /// Note: enabling iCloud Drive while the app is already running won't
    /// migrate the file until the next launch.
    private lazy var settingsFileURL: URL = {
        let fm = FileManager.default
        let base = fm.fileExists(atPath: Self.cloudDocsDir.path)
            ? Self.cloudDocsDir.appendingPathComponent("ScrollShot")
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScrollShot")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }()

    // MARK: - Payload

    private struct Payload: Codable {
        var updatedAt: Date
        var values: [String: SyncValue]
    }

    /// A type-tagged UserDefaults value, so Bool/Int/Double/String/Data all
    /// round-trip through JSON without collapsing (JSON has no Data, and NSNumber
    /// would lose the Bool-vs-Int distinction).
    private enum SyncValue: Codable, Equatable {
        case bool(Bool), int(Int), double(Double), string(String), data(Data)

        private enum CodingKeys: String, CodingKey { case t, v }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .t) {
            case "b": self = .bool(try c.decode(Bool.self, forKey: .v))
            case "i": self = .int(try c.decode(Int.self, forKey: .v))
            case "d": self = .double(try c.decode(Double.self, forKey: .v))
            case "s": self = .string(try c.decode(String.self, forKey: .v))
            case "x": self = .data(try c.decode(Data.self, forKey: .v))
            case let t: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "bad type \(t)")
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bool(let b):   try c.encode("b", forKey: .t); try c.encode(b, forKey: .v)
            case .int(let i):    try c.encode("i", forKey: .t); try c.encode(i, forKey: .v)
            case .double(let x): try c.encode("d", forKey: .t); try c.encode(x, forKey: .v)
            case .string(let s): try c.encode("s", forKey: .t); try c.encode(s, forKey: .v)
            case .data(let d):   try c.encode("x", forKey: .t); try c.encode(d, forKey: .v)
            }
        }
    }

    /// Convert a raw UserDefaults value to a typed `SyncValue`. Bool is detected
    /// via CFBoolean so it isn't mistaken for an Int.
    private func syncValue(from any: Any) -> SyncValue? {
        if CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool((any as? NSNumber)?.boolValue ?? false)
        }
        switch any {
        case let d as Data:   return .data(d)
        case let s as String: return .string(s)
        case let n as NSNumber:
            let objcType = String(cString: n.objCType)
            return (objcType == "d" || objcType == "f") ? .double(n.doubleValue) : .int(n.intValue)
        default:              return nil
        }
    }

    // MARK: - Push (local → file)

    private func localDefaultsChanged() {
        guard !applyingRemote else { return }
        pushDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushSnapshot() }
        pushDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func currentValues() -> [String: SyncValue] {
        var values: [String: SyncValue] = [:]
        for key in Self.syncedKeys {
            if let raw = defaults.object(forKey: key), let v = syncValue(from: raw) {
                values[key] = v
            }
        }
        return values
    }

    private func pushSnapshot() {
        let values = currentValues()
        let url = settingsFileURL

        // Only write when the CONTENT actually changed — otherwise a pull that
        // applies identical values would bump the timestamp, the other Mac would
        // pull it, re-push, and the two would ping-pong timestamps forever.
        if let existing = try? Data(contentsOf: url),
           let prior = try? JSONDecoder().decode(Payload.self, from: existing),
           prior.values == values {
            return
        }

        let payload = Payload(updatedAt: Date(), values: values)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try data.write(to: url, options: .atomic)
            defaults.set(payload.updatedAt, forKey: Self.lastSyncedAtKey)
        } catch {
            NSLog("SettingsSync push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull (file → local)

    private func pull(applyLive: Bool) {
        let url = settingsFileURL
        try? FileManager.default.startDownloadingUbiquitousItem(at: url) // materialize if a placeholder
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        let lastApplied = defaults.object(forKey: Self.lastSyncedAtKey) as? Date ?? .distantPast
        guard payload.updatedAt > lastApplied else { return }  // our own write or stale

        applyingRemote = true
        for (key, value) in payload.values {
            switch value {
            case .bool(let b):   defaults.set(b, forKey: key)
            case .int(let i):    defaults.set(i, forKey: key)
            case .double(let x): defaults.set(x, forKey: key)
            case .string(let s): defaults.set(s, forKey: key)
            case .data(let d):   defaults.set(d, forKey: key)
            }
        }
        defaults.set(payload.updatedAt, forKey: Self.lastSyncedAtKey)
        applyingRemote = false

        if applyLive { reloadLiveObjects() }
    }

    /// Re-apply freshly-synced settings to the already-running singletons.
    private func reloadLiveObjects() {
        KeyMappingStore.shared.reload()
        InputSourceStore.shared.reload()
        ShiftInputToggle.shared.updateRegistration()
        CapsLockDelayOverride.applyNow()
        MouseAccelerationController.shared.reload()
        FeatureSwitches.shared.apply(.smartPaste)   // smartPaste.enabled 可能刚被同步改写
        FeatureSwitches.shared.apply(.deviceBattery) // deviceBattery.enabled 同理
        UsageStatusItemController.shared.reload()
        MainMenuBarController.shared.reload()
        AppTheme.applyStored()
        NotificationCenter.default.post(name: .scrollShotSettingsDidSync, object: nil)
    }
}

extension Notification.Name {
    static let scrollShotSettingsDidSync = Notification.Name("scrollShotSettingsDidSync")
}
