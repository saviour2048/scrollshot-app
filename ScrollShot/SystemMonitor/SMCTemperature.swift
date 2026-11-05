import Foundation
import IOKit

/// Reads a representative CPU temperature from the SMC (Apple's sensor chip).
///
/// Approach adapted from SMCKit / Stats (MIT). The struct layout must be
/// byte-exact with what the `AppleSMC` kernel service expects. Intel temps come
/// back as `sp78` (signed 8.8 fixed point); Apple Silicon as `flt ` (IEEE float).
/// Apple Silicon has no single package sensor and every chip generation uses
/// different 4-char keys, so we pick a per-generation list and average it.
///
/// Fragile by nature: a newer/unrecognized chip, or a Mac that simply doesn't
/// populate these keys, yields nil → the UI shows "—°".
final class SMCTemperature {
    static let shared = SMCTemperature()

    private var conn: io_connect_t = 0
    private var didOpen = false
    private lazy var brand = Self.sysctlString("machdep.cpu.brand_string") ?? ""

    private init() {}

    /// All readable temperature groups (CPU / GPU / 内存) in °C. First entry (CPU)
    /// is the menu-bar headline. Empty if nothing is readable on this machine.
    func readAll() -> [TempSensor] {
        var out: [TempSensor] = []
        if open() {
            if let cpu = cpuValue()             { out.append(TempSensor(name: "CPU", value: cpu)) }
            if let gpu = averageValid(gpuKeys)  { out.append(TempSensor(name: "GPU", value: gpu)) }
            if let mem = averageValid(memKeys)  { out.append(TempSensor(name: "内存", value: mem)) }
        }
        // On Apple Silicon the SMC keys often come back zeroed (verified on
        // M1 / macOS 26) — fall back to the HID sensor services.
        if out.isEmpty { out = hidReadAll() }
        return out
    }

    // MARK: Fans

    /// 风扇转速:每颗的当前值 + 全部风扇的 min/max。Apple Silicon 的 fan 键同样
    /// 是 `F0Ac`(类型 `flt `);Intel 是 `fpe2`。无风扇机型 `FNum` = 0 → nil。
    func readFans() -> (rpms: [Double], minRPM: Double?, maxRPM: Double?)? {
        guard open() else { return nil }
        guard let rawCount = value("FNum"), rawCount > 0 else { return nil }
        let count = min(Int(rawCount), 8)

        var rpms: [Double] = []
        var mins: [Double] = []
        var maxs: [Double] = []
        for i in 0..<count {
            if let v = value("F\(i)Ac"), v >= 0 { rpms.append(v) }
            if let v = value("F\(i)Mn"), v > 0 { mins.append(v) }
            if let v = value("F\(i)Mx"), v > 0 { maxs.append(v) }
        }
        guard !rpms.isEmpty else { return nil }
        return (rpms, mins.min(), maxs.max())
    }

    // MARK: IOHID fallback (Apple Silicon)

    /// CPU = average of the pACC/eACC cluster sensors, GPU = GPU MTR sensors.
    /// No unified-memory sensor exists, so 内存 is omitted here.
    private func hidReadAll() -> [TempSensor] {
        let sensors = HIDSensors.temperatures()
        var out: [TempSensor] = []
        let cpu = Self.average(sensors, matching: { $0.contains("pACC MTR") || $0.contains("eACC MTR") })
        if let cpu { out.append(TempSensor(name: "CPU", value: cpu)) }
        let gpu = Self.average(sensors, matching: { $0.contains("GPU MTR") })
        if let gpu { out.append(TempSensor(name: "GPU", value: gpu)) }
        return out
    }

    private static func average(_ sensors: [(name: String, value: Double)], matching match: (String) -> Bool) -> Double? {
        let values = sensors.filter { match($0.name) }.map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func cpuValue() -> Double? {
        if brand.contains("Apple") { return averageValid(appleSiliconKeys) }
        for key in ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"] {
            if let v = value(key), v > 0, v < 110 { return v }
        }
        return nil
    }

    private func averageValid(_ keys: [String]) -> Double? {
        var sum = 0.0, count = 0.0
        for k in keys {
            if let v = value(k), v > 0, v < 120 { sum += v; count += 1 }
        }
        return count > 0 ? sum / count : nil
    }

    /// GPU / memory keys are tried across Apple Silicon (Tg…/Tm…) + Intel (TG…/Ts…);
    /// nonexistent keys just fail silently, so a broad superset is fine.
    private let gpuKeys = ["Tg05", "Tg0D", "Tg0f", "Tg0G", "Tg0H", "Tg0L", "Tg0P",
                           "Tg0V", "Tg1U", "Tg0j", "Tg0n", "TCGC", "TG0D", "TG0P", "TGDD"]
    private let memKeys = ["Tm02", "Tm06", "Tm08", "Tm09", "Tm00", "Tm04",
                           "Tm0p", "Tm1p", "Ts0S", "TM0P"]

    private var appleSiliconKeys: [String] {
        if brand.contains("M1") { return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"] }
        if brand.contains("M2") { return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"] }
        if brand.contains("M3") { return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"] }
        if brand.contains("M4") { return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"] }
        if brand.contains("M5") { return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d"] }
        return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D"]   // unknown → recent default
    }

    // MARK: SMC transport

    private func open() -> Bool {
        if didOpen { return conn != 0 }
        didOpen = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        return result == kIOReturnSuccess
    }

    private func value(_ key: String) -> Double? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        // 1. key info (size + type)
        input.key = Self.fourChar(key)
        input.data8 = 9   // kSMCGetKeyInfo
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }
        let dataType = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize

        // 2. bytes
        input = SMCParamStruct()
        input.key = Self.fourChar(key)
        input.keyInfo.dataSize = dataSize
        input.data8 = 5   // kSMCReadKey
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }

        return decode(dataType: dataType, bytes: output.bytes)
    }

    private func callSMC(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize)
    }

    private func decode(dataType: UInt32, bytes: SMCBytes) -> Double? {
        let b = (bytes.0, bytes.1, bytes.2, bytes.3)
        switch Self.fourCharString(dataType) {
        case "sp78":
            let raw = Int(b.0) << 8 | Int(b.1)
            return Double(raw) / 256.0
        case "flt ", "flt":
            let bits = UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            // Intel fan keys: unsigned 14.2 fixed point.
            return Double(UInt16(b.0) << 8 | UInt16(b.1)) / 4.0
        case "ui8 ", "ui8":
            return Double(b.0)
        case "ui16":
            return Double(UInt16(b.0) << 8 | UInt16(b.1))
        default:
            return nil
        }
    }

    // MARK: Helpers

    private static func fourChar(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func fourCharString(_ v: UInt32) -> String {
        let chars: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                              UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

// MARK: - SMC struct layout (byte-exact with the AppleSMC kernel service)

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - IOHID temperature sensors (private IOKit API, resolved at runtime)

/// Reads the HID "temperature sensor" services (Apple Silicon: "pACC/eACC/GPU
/// MTR Temp Sensor…"). The needed IOHIDFamily symbols are private and absent
/// from the macOS SDK, so they are dlsym'd at runtime — the approach used by
/// Stats / SensorsKit (MIT). Any missing symbol just yields no readings.
private enum HIDSensors {
    private typealias CreateFn       = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn  = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn    = @convention(c) (CFTypeRef, Int64, Int64, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventFloatFn   = @convention(c) (CFTypeRef, Int64) -> Double

    /// kHIDPage_AppleVendor / kHIDUsage_AV_TemperatureSensor / kIOHIDEventTypeTemperature
    private static let page: Int = 0xFF00
    private static let usage: Int = 0x0005
    private static let eventType: Int64 = 15

    /// The dlsym'd entry points plus a single long-lived client: creating an
    /// IOHIDEventSystemClient (and its service cache) on every poll showed up in
    /// sampling as per-tick IOHIDEventSystemClientCreate → SetMatching →
    /// CacheMatchingServices. Nil when the private symbols are unavailable.
    private struct Session {
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let eventFloat: EventFloatFn
        let client: CFTypeRef
    }

    private static let session = makeSession()

    /// IOHIDEventSystemClient thread-safety is undocumented and reads now happen
    /// off the main thread, so serialize them.
    private static let lock = NSLock()

    private static func makeSession() -> Session? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create       = sym("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching  = sym("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent    = sym("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let eventFloat   = sym("IOHIDEventGetFloatValue", as: EventFloatFn.self),
              let client       = create(nil)?.takeRetainedValue()
        else { return nil }

        setMatching(client, ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary)
        return Session(copyServices: copyServices, copyProperty: copyProperty,
                       copyEvent: copyEvent, eventFloat: eventFloat, client: client)
    }

    /// All temperature readings (name, °C), bogus values (≤0 / ≥120) dropped.
    static func temperatures() -> [(name: String, value: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return [] }
        guard let services = session.copyServices(session.client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }

        var out: [(name: String, value: Double)] = []
        for service in services {
            guard let name = session.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = session.copyEvent(service, eventType, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = session.eventFloat(event, eventType << 16)
            if value > 0, value < 120 { out.append((name, value)) }
        }
        return out
    }
}
