import AppKit

/// 内存水位看门狗：兜底 macOS 26 SkyLight CGEventTap 系统泄漏（键盘事件
/// 每个漏 ~1 KB，一天 10–30 MB 进 swap，是系统 bug，代码侧无法修复，
/// 详见 HANDOFF_MACOS26_INPUT_LEAKS.md）。做法：每 60 s 检查一次自身
/// phys_footprint，超过阈值且当前没有敏感操作（截图/窗口）时拉起一个新
/// 实例并退出自己，让泄漏的内存随进程释放。
@MainActor
final class MemoryWatchdog {
    static let shared = MemoryWatchdog()

    /// UserDefaults 键：阈值（MB）。未设置用 defaultThresholdMB；≤ 0 表示禁用。
    private static let thresholdKey = "memoryWatchdog.thresholdMB"
    /// UserDefaults 键：上一次看门狗自重启的时间，新进程启动时据此补打「重启后」日志。
    private static let lastRestartKey = "memoryWatchdog.lastRestartAt"

    private let defaultThresholdMB = 800.0
    private let checkInterval: TimeInterval = 60
    /// 启动后短时间内不自重启：泄漏要累积数周才到阈值，若刚启动就超限说明是
    /// 正常占用或异常情况，此时重启只会形成「重启→超限→再重启」的死循环。
    private let minimumUptime: TimeInterval = 30 * 60

    private var timer: Timer?
    private let launchDate = Date()
    private var restarting = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        // 若本进程是上一次看门狗自重启拉起的，补打「重启后」日志（「重启前」
        // 那条在旧进程里打的，含当时的 footprint）。
        let d = UserDefaults.standard
        if let last = d.object(forKey: Self.lastRestartKey) as? Date,
           abs(last.timeIntervalSinceNow) < 5 * 60 {
            NSLog("ScrollShot MemoryWatchdog: 自重启完成，新实例 footprint = %.0f MB", footprintMB() ?? -1)
            d.removeObject(forKey: Self.lastRestartKey)
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: 检查

    private func check() {
        guard !restarting else { return }
        let threshold = thresholdMB()
        guard threshold > 0 else { return }   // ≤ 0 = 禁用
        guard Date().timeIntervalSince(launchDate) >= minimumUptime else { return }
        guard let footprint = footprintMB(), footprint >= threshold else { return }
        guard isSafeToRestart else {
            NSLog("ScrollShot MemoryWatchdog: footprint %.0f MB 已超阈值 %.0f MB，但当前有可见窗口或 app 处于活跃状态，推迟自重启", footprint, threshold)
            return
        }
        restart(footprint: footprint, threshold: threshold)
    }

    /// 最保守的安全判断：CaptureController.isRunning / LongCaptureController.active
    /// 都是私有状态无法直接读取，但截图 overlay 和长截图面板在会话期间必然有
    /// 可见窗口，所以「app 非活跃 + 无任何可见窗口」即可保证没有截图/标注/
    /// 剪贴板等交互正在进行。
    private var isSafeToRestart: Bool {
        guard !NSApp.isActive else { return false }
        return !NSApp.windows.contains { $0.isVisible }
    }

    // MARK: 自重启

    private func restart(footprint: Double, threshold: Double) {
        restarting = true
        NSLog("ScrollShot MemoryWatchdog: footprint %.0f MB 超过阈值 %.0f MB，准备自重启", footprint, threshold)
        UserDefaults.standard.set(Date(), forKey: Self.lastRestartKey)

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            // completion 所在队列没有文档保证，切回主线程再动 NSApp。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        NSLog("ScrollShot MemoryWatchdog: 拉起新实例失败：\(error.localizedDescription)")
                        self.restarting = false
                        UserDefaults.standard.removeObject(forKey: Self.lastRestartKey)
                        return
                    }
                    // 新实例已启动。它在 applicationDidFinishLaunching 里的单实例
                    // 逻辑会 terminate 掉本进程（ScrollShotApp.swift 开头），这里再
                    // 主动 terminate 一次兜底，保证任何时序下都不会留下两个常驻实例。
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: 内存读取

    /// 进程物理内存占用（phys_footprint，与活动监视器口径一致），单位 MB。
    /// proc_pid_rusage 自 macOS 10.10 起可用。
    private func footprintMB() -> Double? {
        var info = rusage_info_v4()
        let err = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard err == 0 else { return nil }
        return Double(info.ri_phys_footprint) / (1024 * 1024)
    }

    /// 当前生效阈值：未设置用默认值，≤ 0 表示禁用。
    private func thresholdMB() -> Double {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.thresholdKey) != nil else { return defaultThresholdMB }
        return d.double(forKey: Self.thresholdKey)
    }
}
