import Foundation
import Darwin

/// One named temperature reading (CPU / GPU / 内存) from the SMC.
struct TempSensor: Equatable, Identifiable {
    let name: String
    let value: Double   // °C
    var id: String { name }
}

/// A snapshot of the machine's live system stats. Temperature comes from the SMC
/// reader; the rest use plain Mach / sysctl APIs.
struct SystemStats: Equatable {
    var cpuPercent: Double?     // 0–100, whole machine
    var memUsed: Double?        // bytes
    var memTotal: Double?       // bytes
    var netUp: Double?          // bytes / second
    var netDown: Double?        // bytes / second
    var tempC: Double?          // °C headline (CPU), nil if unreadable
    var tempSensors: [TempSensor] = []   // per-group breakdown for the popover
    var fanRPM: Double?         // 平均风扇转速(RPM),无风扇/读不到时 nil
    var fanValues: [Double] = []         // 每颗风扇的当前转速
    var fanMin: Double?         // 最低转速(通常 = 系统 idle 转速)
    var fanMax: Double?         // 最高转速
    var memPressureLevel: Int?  // 内存可用百分比 0–100(kern.memorystatus_level), 越高越宽松; 压力 = 100 - level
    var simRunning = false      // 有 iOS/tvOS/watchOS 模拟器已启动(运行时进程存在)或 Simulator.app 开着
    var simMemory: Double?      // 模拟器相关进程 RSS 合计(bytes), 未运行时 nil
    var simCPU: Double?         // 模拟器相关进程 CPU% 合计, 未运行时 nil
}

/// Whole-machine CPU usage from `host_statistics(HOST_CPU_LOAD_INFO)` — the delta
/// of (user+system) vs total ticks between reads. First read returns nil (no
/// previous sample yet).
final class CPUReader {
    private var previous: host_cpu_load_info?

    func read() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let prev = previous else { return nil }

        // cpu_ticks tuple: (user, system, idle, nice). `&-` guards counter wrap.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let sys  = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + sys + idle + nice
        guard total > 0 else { return nil }
        return (user + sys) / total * 100
    }
}

/// Memory usage via `host_statistics64(HOST_VM_INFO64)`, using the Activity
/// Monitor-style "used" formula. Total is `hw.memsize`.
final class MemoryReader {
    let total: Double = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Double(size)
    }()

    func read() -> (used: Double, total: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_page_size)
        let active      = Double(stats.active_count) * page
        let inactive    = Double(stats.inactive_count) * page
        let speculative = Double(stats.speculative_count) * page
        let wired       = Double(stats.wire_count) * page
        let compressed  = Double(stats.compressor_page_count) * page
        let purgeable   = Double(stats.purgeable_count) * page
        let external    = Double(stats.external_page_count) * page
        let used = active + inactive + speculative + wired + compressed - purgeable - external
        return (max(0, used), total)
    }
}

/// 内存压力等级 via `sysctlbyname("kern.memorystatus_level")` — 返回系统内存可用
/// 百分比(0–100,越高越宽松),与 `memory_pressure` 命令的 free percentage 一致,
/// 活动监视器的压力图即基于它。单次调用是廉价 syscall,随传感器 tick 读取即可。
final class MemoryPressureReader {
    func read() -> Int? {
        var level: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &len, nil, 0) == 0 else { return nil }
        return Int(level)
    }
}

/// Network up/down throughput: the per-second delta of cumulative interface byte
/// counters (summed over all non-loopback interfaces) via `getifaddrs`.
final class NetworkReader {
    private var prevUp: UInt64 = 0
    private var prevDown: UInt64 = 0
    private var prevTime: Date?

    func read() -> (up: Double, down: Double)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var up: UInt64 = 0
        var down: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo"), let raw = ifa.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    up += UInt64(data.ifi_obytes)
                    down += UInt64(data.ifi_ibytes)
                }
            }
            ptr = ifa.ifa_next
        }

        let now = Date()
        defer { prevUp = up; prevDown = down; prevTime = now }
        guard let t = prevTime, prevTime != nil else { return nil }
        let dt = now.timeIntervalSince(t)
        guard dt > 0 else { return nil }
        // Counter decrease (32-bit wrap / iface reset) → treat that tick as 0.
        let upDelta   = up   >= prevUp   ? Double(up - prevUp)     : 0
        let downDelta = down >= prevDown ? Double(down - prevDown) : 0
        return (upDelta / dt, downDelta / dt)
    }
}
