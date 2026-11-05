import Foundation

/// AirPods/Beats 耳机条目登记处。
///
/// 身份策略（对齐 AirBattery 的行为）：**系统蓝牙名是唯一身份**。广播里
/// 没有 MAC，peripheral UUID 又会被 macOS 轮换（同一副耳机可被暴露成多个
/// peripheral），所以——
/// - BLE 广播只在解析出系统蓝牙名时才建档/更新；无名的包直接丢弃，宁可
///   不显示也不产生重名幽灵条目或跨副误并。
/// - system_profiler 的 device_connected（已连接设备，有权威电量和名字）
///   是一等数据源，同样按名字 upsert。
/// - 不存在任何"按电量数值相似度猜测同一设备"的合并。
///
/// 每条 gauge 带自己的写入时间：整条目还在被刷新时，单个失联/被过滤的
/// gauge 也会按自己的 TTL 过期（上一轮"旧 gauge 永远续命"就是菜单栏幻影
/// 电量的根因）。
struct HeadphoneRegistry {

    struct DatedReading: Equatable {
        enum Source: Equatable { case broadcast, systemProfiler }
        var percent: Int
        var isCharging: Bool
        /// 充电标志是瞬态信息：电量可以留很久，但⚡只能信最近几分钟的。
        /// SP 不报告充电状态，它刷新 gauge 时保留这个字段的原值和原时间。
        var chargingUpdatedAt: Date
        var source: Source
        var updatedAt: Date

        /// 当前时刻这个⚡还有效吗（过期即视为不在充电）。
        func liveCharging(now: Date, ttl: TimeInterval) -> Bool {
            isCharging && now.timeIntervalSince(chargingUpdatedAt) < ttl
        }
    }

    struct Entry: Equatable {
        var name: String
        var model: String?
        var left: DatedReading?
        var right: DatedReading?
        var caseBattery: DatedReading?
        /// 是否在当前 system_profiler 快照里（已连接）。从快照消失后降级，
        /// 走普通 TTL——BLE 还在广播就会续期，都没有就消失。
        var inSystemProfiler: Bool
        var updatedAt: Date
    }

    /// system_profiler 报来的一台耳机（device_connected 里的电量字段）。
    struct SystemProfilerReading: Equatable {
        var name: String
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var productID: UInt16?
    }

    /// 广播 gauge 过期时间：身份改为系统蓝牙名后幽灵条目已不可能堆积，
    /// TTL 可以放宽——合盖/闲置的 AirPods 广播很稀疏，3 分钟会把第二副
    /// 耳机的条目在扫描间隙清掉（AirBattery 默认 20 分钟）。取 10 分钟。
    /// SP 快照 5 分钟才刷一次，其 gauge 给 8 分钟余量防闪烁。
    static let broadcastTTL: TimeInterval = 600
    static let systemProfilerTTL: TimeInterval = 480
    /// 充电标志的保鲜期：拔掉电源后最多再显示 3 分钟⚡。
    static let chargingTTL: TimeInterval = 180

    private(set) var entries: [String: Entry] = [:]

    /// 「查找」网络影子记录：macOS 会为「查找」网络单独注册一条蓝牙记录，
    /// 名字形如 `Tony's AirPods Pro - Find My`，**一条电量都没有**（也没序列号）。
    /// 它不是一副新耳机，和真配对记录重复——不建档。
    /// ⚠️ 判据必须带上「没有电量」：实测有用户的真耳机被注册成 `AirPods Pro - Find My`
    /// 且**有电量有序列号**，只按名字后缀过滤会把真设备藏掉（0.8.67 的 bug，0.8.68 修）。
    /// - Parameter hasBattery: 这条记录自己有没有报电量（左/右/盒任一）。
    ///   实测（2026-10-27）：有的真耳机就被注册成 `AirPods Pro - Find My`，有序列号、
    ///   有电量（L/R 90%），只是名字带 Find My；把它当影子藏掉是错的。
    ///   真正的影子只有「名字带 Find My + 一条电量都没有」。
    static func isFindMyShadow(_ name: String, hasBattery: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasSuffix("find my") && !hasBattery
    }

    /// 采纳一条 BLE 广播。没有系统蓝牙名的包直接丢弃（无法可靠归属）。
    mutating func ingest(_ advertisement: HeadphoneAdvertisement, name: String?, now: Date = Date()) {
        let advertHasBattery = (advertisement.left?.isPlausible ?? false)
            || (advertisement.right?.isPlausible ?? false)
            || (advertisement.caseBattery?.isPlausible ?? false)
        guard let name, !name.isEmpty,
              !Self.isFindMyShadow(name, hasBattery: advertHasBattery) else { return }
        var entry = entries[name] ?? Entry(
            name: name, model: nil, left: nil, right: nil, caseBattery: nil,
            inSystemProfiler: false, updatedAt: now
        )
        if let modelID = advertisement.modelID, let model = HeadphoneModelCatalog.name(for: modelID) {
            entry.model = model
        }
        if let reading = advertisement.left, reading.isPlausible {
            entry.left = DatedReading(percent: reading.percent, isCharging: reading.isCharging,
                                      chargingUpdatedAt: now, source: .broadcast, updatedAt: now)
        }
        if let reading = advertisement.right, reading.isPlausible {
            entry.right = DatedReading(percent: reading.percent, isCharging: reading.isCharging,
                                       chargingUpdatedAt: now, source: .broadcast, updatedAt: now)
        }
        if let reading = advertisement.caseBattery, reading.isPlausible {
            entry.caseBattery = DatedReading(percent: reading.percent, isCharging: reading.isCharging,
                                             chargingUpdatedAt: now, source: .broadcast, updatedAt: now)
        }
        entry.updatedAt = now
        entries[name] = entry
    }

    /// 应用一份 system_profiler 快照：按名字 upsert 已连接耳机的权威电量；
    /// 从快照里消失的条目标记降级（不断电消失，交给 TTL 判断）。
    mutating func applySystemProfiler(_ allReadings: [SystemProfilerReading], now: Date = Date()) {
        let readings = allReadings.filter {
            let hasBattery = $0.left != nil || $0.right != nil || $0.caseLevel != nil
            return !Self.isFindMyShadow($0.name, hasBattery: hasBattery)
        }
        let liveNames = Set(readings.map(\.name))
        for reading in readings {
            var entry = entries[reading.name] ?? Entry(
                name: reading.name, model: nil, left: nil, right: nil, caseBattery: nil,
                inSystemProfiler: true, updatedAt: now
            )
            entry.inSystemProfiler = true
            if let productID = reading.productID, let model = HeadphoneModelCatalog.name(for: productID) {
                entry.model = model
            }
            // SP 不报充电状态：保留该 gauge 已有的充电标记，但保留的是它
            // 原本的 chargingUpdatedAt——⚡的保鲜期从最后一次广播读数算起，
            // SP 刷新不会给旧⚡续命。
            if let left = reading.left {
                entry.left = DatedReading(percent: left, isCharging: entry.left?.isCharging ?? false,
                                          chargingUpdatedAt: entry.left?.chargingUpdatedAt ?? .distantPast,
                                          source: .systemProfiler, updatedAt: now)
            }
            if let right = reading.right {
                entry.right = DatedReading(percent: right, isCharging: entry.right?.isCharging ?? false,
                                           chargingUpdatedAt: entry.right?.chargingUpdatedAt ?? .distantPast,
                                           source: .systemProfiler, updatedAt: now)
            }
            if let caseLevel = reading.caseLevel {
                entry.caseBattery = DatedReading(percent: caseLevel, isCharging: entry.caseBattery?.isCharging ?? false,
                                                 chargingUpdatedAt: entry.caseBattery?.chargingUpdatedAt ?? .distantPast,
                                                 source: .systemProfiler, updatedAt: now)
            }
            entry.updatedAt = now
            entries[reading.name] = entry
        }
        for key in entries.keys where entries[key]?.inSystemProfiler == true && !liveNames.contains(key) {
            entries[key]?.inSystemProfiler = false
        }
    }

    /// 过期清理：gauge 按各自来源的 TTL 独立过期；条目在所有 gauge 都没了
    /// 或整体超过 TTL 后移除。
    mutating func prune(now: Date = Date()) {
        func expired(_ reading: DatedReading?) -> Bool {
            guard let reading else { return false }
            let ttl = reading.source == .systemProfiler ? Self.systemProfilerTTL : Self.broadcastTTL
            return now.timeIntervalSince(reading.updatedAt) > ttl
        }
        for (key, var entry) in entries {
            if expired(entry.left) { entry.left = nil }
            if expired(entry.right) { entry.right = nil }
            if expired(entry.caseBattery) { entry.caseBattery = nil }
            let entryTTL = entry.inSystemProfiler ? Self.systemProfilerTTL : Self.broadcastTTL
            let allGaugesGone = entry.left == nil && entry.right == nil && entry.caseBattery == nil
            if allGaugesGone || now.timeIntervalSince(entry.updatedAt) > entryTTL {
                entries.removeValue(forKey: key)
            } else {
                entries[key] = entry
            }
        }
    }

    /// 生成展示模型（按名字排序）。caseLabel 传本地化后的「充电盒」。
    /// 充电标记按 chargingTTL 现算：过期的⚡一律视为不在充电。
    func infos(caseLabel: String, now: Date = Date()) -> [DeviceBatteryInfo] {
        entries.values.sorted { $0.name < $1.name }.map { entry in
            var gauges: [DeviceBatteryInfo.Gauge] = []
            if let left = entry.left {
                gauges.append(.init(label: "L", percent: left.percent,
                                    isCharging: left.liveCharging(now: now, ttl: Self.chargingTTL)))
            }
            if let right = entry.right {
                gauges.append(.init(label: "R", percent: right.percent,
                                    isCharging: right.liveCharging(now: now, ttl: Self.chargingTTL)))
            }
            if let caseBattery = entry.caseBattery {
                gauges.append(.init(label: caseLabel, percent: caseBattery.percent,
                                    isCharging: caseBattery.liveCharging(now: now, ttl: Self.chargingTTL)))
            }
            return DeviceBatteryInfo(
                id: "airpods-\(entry.name)",
                category: .headphones,
                name: entry.name,
                model: entry.model,
                gauges: gauges,
                detail: nil,
                updatedAt: entry.updatedAt
            )
        }
    }
}
