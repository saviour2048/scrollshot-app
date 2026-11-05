import Foundation
import Combine

/// The monitored resources. Each gets its own menu-bar item + popover.
/// `.simulator` 特殊: 没有模拟器在跑时不占菜单栏(状态变化会触发重建)。
enum SysMetric: String, CaseIterable, Identifiable {
    case cpu, memory, network, temperature, fan, simulator
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:         return "CPU"
        case .memory:      return "内存"
        case .network:     return "网络"
        case .temperature: return "温度"
        case .fan:         return "风扇"
        case .simulator:   return "模拟器"
        }
    }
    var icon: String {
        switch self {
        case .cpu:         return "cpu"
        case .memory:      return "memorychip"
        case .network:     return "network"
        case .temperature: return "thermometer.medium"
        case .fan:         return "fanblades"
        case .simulator:   return "iphone"
        }
    }
}

/// User-configurable settings for the system monitor.
enum SystemMonitorSettings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "sysmon.enabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "sysmon.enabled") }
    }

    static func shows(_ m: SysMetric) -> Bool {
        // 新指标(风扇)默认关,老用户升级不会平白多出一个菜单栏项。
        d.object(forKey: "sysmon.show.\(m.rawValue)") as? Bool ?? (m != .fan)
    }
    static func setShows(_ m: SysMetric, _ value: Bool) {
        d.set(value, forKey: "sysmon.show.\(m.rawValue)")
    }

    /// 菜单栏空间不够（项被系统折叠/叠罗汉）时，自动把各指标合并成一个项。
    /// 默认开；关掉就永远保持「一个指标一个项」。**故意不进 SettingsSync**：
    /// 这是按机器屏幕状况自动决定的东西，两台机器不该互相覆盖。
    static var mergeWhenCrowded: Bool {
        get { d.object(forKey: "sysmon.mergeWhenCrowded") as? Bool ?? true }
        set { d.set(newValue, forKey: "sysmon.mergeWhenCrowded") }
    }

    /// 内存压力曲线菜单栏项(迷你面积图),默认关,与新增指标一样 opt-in。
    static var showsMemPressure: Bool {
        get { d.object(forKey: "sysmon.show.memPressure") as? Bool ?? false }
        set { d.set(newValue, forKey: "sysmon.show.memPressure") }
    }
}

/// Polls the sensor readers (2 s, off-main since SMC/HID reads are synchronous
/// mach_msg IPC) and, while a popover is open, the top-process readers (1 s,
/// off-main since they spawn `ps`/`top`/`nettop`).
@MainActor
final class SystemMonitorStore: ObservableObject {
    static let shared = SystemMonitorStore()

    @Published private(set) var stats = SystemStats()
    @Published private(set) var topCPU: [ProcInfo] = []
    @Published private(set) var topMemory: [ProcInfo] = []
    @Published private(set) var topNetwork: [ProcInfo] = []
    @Published private(set) var topSimulator: [ProcInfo] = []
    @Published private(set) var simDevices: [String] = []

    /// 内存压力历史(压力 = 100 - level,0–100,旧→新),环形缓冲保留最近
    /// `memPressureHistoryCapacity` 个样本(2s tick × 90 ≈ 3 分钟窗口)。
    @Published private(set) var memPressureHistory: [Int] = []
    static let memPressureHistoryCapacity = 90

    /// Called on the main thread after every sensor update (drives status-item titles).
    var onUpdate: ((SystemStats) -> Void)?

    /// Which popover is currently open (nil → none). Setting it starts/stops the
    /// heavier per-process polling.
    var openMetric: SysMetric? {
        didSet { openMetric == nil ? stopProcessTimer() : startProcessTimer() }
    }

    private var sensorTimer: Timer?
    private var processTimer: Timer?
    private let cpu = CPUReader()
    private let mem = MemoryReader()
    private let net = NetworkReader()
    private let memPressure = MemoryPressureReader()
    private let sensorQueue = DispatchQueue(label: "com.scrollshot.sysmon.sensor", qos: .utility)
    private let procQueue = DispatchQueue(label: "com.scrollshot.sysmon.proc", qos: .utility)

    private init() {}

    func start() {
        guard sensorTimer == nil else { return }
        sensorTick()
        sensorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sensorTick() }
        }
    }

    func stop() {
        sensorTimer?.invalidate(); sensorTimer = nil
        stopProcessTimer()
    }

    private func sensorTick() {
        let prev = stats
        sensorQueue.async { [weak self] in
            guard let self else { return }
            var s = prev
            if let c = self.cpu.read() { s.cpuPercent = c }
            if let m = self.mem.read() { s.memUsed = m.used; s.memTotal = m.total }
            if let n = self.net.read() { s.netUp = n.up; s.netDown = n.down }
            let sensors = SMCTemperature.shared.readAll()
            s.tempSensors = sensors
            s.tempC = sensors.first(where: { $0.name == "CPU" })?.value ?? sensors.first?.value
            if let fans = SMCTemperature.shared.readFans() {
                s.fanValues = fans.rpms
                s.fanRPM = fans.rpms.reduce(0, +) / Double(fans.rpms.count)
                s.fanMin = fans.minRPM
                s.fanMax = fans.maxRPM
            } else {
                s.fanValues = []
                s.fanRPM = nil
                s.fanMin = nil
                s.fanMax = nil
            }
            if let level = self.memPressure.read() { s.memPressureLevel = level }
            // 模拟器指标开关开着才读(ps 进程枚举有开销); 没跑模拟器时字段清空。
            if SystemMonitorSettings.shows(.simulator) {
                let sim = SimulatorReader.read()
                s.simRunning = sim.running
                s.simMemory = sim.running ? sim.memory : nil
                s.simCPU = sim.running ? sim.cpu : nil
            }
            Task { @MainActor in
                self.stats = s
                if let level = s.memPressureLevel {
                    self.memPressureHistory.append(100 - level)
                    let overflow = self.memPressureHistory.count - Self.memPressureHistoryCapacity
                    if overflow > 0 { self.memPressureHistory.removeFirst(overflow) }
                }
                self.onUpdate?(s)
            }
        }
    }

    // MARK: Process polling (only while a popover is open)

    private func startProcessTimer() {
        guard processTimer == nil else { return }
        processTick()
        processTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processTick() }
        }
    }

    private func stopProcessTimer() {
        processTimer?.invalidate()
        processTimer = nil
    }

    private func processTick() {
        guard let metric = openMetric else { return }
        procQueue.async { [weak self] in
            switch metric {
            case .cpu:
                let list = CPUProcessReader.read()
                Task { @MainActor in self?.topCPU = list }
            case .memory:
                let list = MemoryProcessReader.read()
                Task { @MainActor in self?.topMemory = list }
            case .network:
                let list = NetworkProcessReader.read()
                Task { @MainActor in self?.topNetwork = list }
            case .temperature:
                break   // no per-process temperature
            case .fan:
                break   // no per-process fan speed
            case .simulator:
                let st = SimulatorReader.read()
                let devices = SimulatorDeviceReader.bootedNames()
                Task { @MainActor in
                    self?.topSimulator = st.top
                    self?.simDevices = devices
                }
            }
        }
    }
}

// MARK: - Formatting

enum SysFormat {
    static func bytes(_ value: Double) -> String {
        switch value {
        case 1e9...:  return String(format: "%.1fG", value / 1e9)
        case 1e6...:  return String(format: "%.0fM", value / 1e6)
        case 1e3...:  return String(format: "%.0fK", value / 1e3)
        default:      return String(format: "%.0fB", value)
        }
    }

    /// Bytes-per-second with a `/s` suffix (for the popover), e.g. "1.2M/s".
    static func rate(_ value: Double) -> String {
        switch value {
        case 1e6...:  return String(format: "%.1fM/s", value / 1e6)
        case 1e3...:  return String(format: "%.0fK/s", value / 1e3)
        default:      return String(format: "%.0fB/s", value)
        }
    }

    /// Compact bytes-per-second for the menu bar (no `/s`; the ↑↓ arrow implies it).
    static func rateCompact(_ value: Double) -> String {
        switch value {
        case 1e6...:  return String(format: "%.0fM", value / 1e6)
        case 1e3...:  return String(format: "%.0fK", value / 1e3)
        default:      return String(format: "%.0f", value)
        }
    }
}
