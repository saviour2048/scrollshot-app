import XCTest
@testable import ScrollShot

final class HeadphoneRegistryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func advert(modelID: UInt16? = 0x2014, left: HeadphoneBatteryReading? = nil,
                        right: HeadphoneBatteryReading? = nil, caseBattery: HeadphoneBatteryReading? = nil) -> HeadphoneAdvertisement {
        HeadphoneAdvertisement(modelID: modelID, lidOpen: true, left: left, right: right, caseBattery: caseBattery)
    }

    /// 用户真实场景：两副同型号 AirPods Pro 2，名字不同，电量必须各自独立。
    func testTwoPairsWithSameModelStaySeparate() {
        var registry = HeadphoneRegistry()
        registry.ingest(advert(left: .init(percent: 91, isCharging: false),
                               right: .init(percent: 93, isCharging: false),
                               caseBattery: .init(percent: 89, isCharging: false)),
                        name: "tony's AirPods Pro newest", now: t0)
        registry.ingest(advert(left: .init(percent: 54, isCharging: false),
                               right: .init(percent: 68, isCharging: false),
                               caseBattery: .init(percent: 9, isCharging: true)),
                        name: "tony's AirPods Pro", now: t0)

        let infos = registry.infos(caseLabel: "Case", now: t0 + 2)
        XCTAssertEqual(infos.count, 2)
        let newest = infos.first { $0.name == "tony's AirPods Pro newest" }
        let old = infos.first { $0.name == "tony's AirPods Pro" }
        XCTAssertEqual(newest?.model, "AirPods Pro 2")
        XCTAssertEqual(old?.model, "AirPods Pro 2")
        XCTAssertEqual(newest?.gauges.map(\.percent), [91, 93, 89])
        XCTAssertEqual(old?.gauges.map(\.percent), [54, 68, 9])
        XCTAssertEqual(old?.gauges.last?.isCharging, true)
    }

    /// 没有系统蓝牙名的广播无法可靠归属，直接丢弃（不产生幽灵条目）。
    func testNamelessBroadcastIsDropped() {
        var registry = HeadphoneRegistry()
        registry.ingest(advert(left: .init(percent: 54, isCharging: false)), name: nil, now: t0)
        registry.ingest(advert(right: .init(percent: 68, isCharging: false)), name: "", now: t0)
        XCTAssertTrue(registry.infos(caseLabel: "Case", now: t0 + 2).isEmpty)
    }

    /// system_profiler 是已连接耳机的权威电量源；同名 BLE 广播合流进同一条目。
    func testSystemProfilerCreatesAndMergesByName() {
        var registry = HeadphoneRegistry()
        registry.applySystemProfiler([
            .init(name: "tony's AirPods Pro", left: 54, right: 68, caseLevel: 9, productID: 0x2014),
        ], now: t0)
        registry.ingest(advert(caseBattery: .init(percent: 12, isCharging: true)),
                        name: "tony's AirPods Pro", now: t0 + 1)

        let infos = registry.infos(caseLabel: "Case", now: t0 + 2)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].model, "AirPods Pro 2")
        XCTAssertEqual(infos[0].gauges.map(\.percent), [54, 68, 12])
        XCTAssertEqual(infos[0].gauges.last?.isCharging, true)
    }

    /// 不同名的 SP 条目和 BLE 条目绝不合并。
    func testDifferentNamesNeverMerge() {
        var registry = HeadphoneRegistry()
        registry.applySystemProfiler([
            .init(name: "A 的耳机", left: 91, right: 93, caseLevel: 89, productID: nil),
        ], now: t0)
        registry.ingest(advert(left: .init(percent: 50, isCharging: false)), name: "B 的耳机", now: t0)
        XCTAssertEqual(registry.infos(caseLabel: "Case", now: t0 + 2).count, 2)
    }

    /// 0%⚡ 占位读数被过滤；gauge 按各自时间独立过期（菜单栏幻影电量根因）。
    func testImplausibleReadingDroppedAndGaugesExpireIndependently() {
        var registry = HeadphoneRegistry()
        registry.ingest(advert(left: .init(percent: 0, isCharging: true),
                               right: .init(percent: 68, isCharging: false)),
                        name: "pods", now: t0)
        var infos = registry.infos(caseLabel: "Case", now: t0 + 2)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].gauges.map(\.label), ["R"])   // L 0%⚡ 未采纳

        // 右耳 gauge 过期后整条目移除。
        registry.prune(now: t0 + HeadphoneRegistry.broadcastTTL + 1)
        infos = registry.infos(caseLabel: "Case", now: t0 + 2)
        XCTAssertTrue(infos.isEmpty)
    }

    /// SP 条目从快照消失后降级，靠 BLE 续期；BLE 也没有就过期消失。
    func testSystemProfilerEntryDemotedWhenDisconnected() {
        var registry = HeadphoneRegistry()
        registry.applySystemProfiler([
            .init(name: "pods", left: 80, right: 80, caseLevel: 80, productID: nil),
        ], now: t0)
        // 下一次快照里没有了 → 降级
        registry.applySystemProfiler([], now: t0 + 10)
        // SP gauge TTL 内仍在
        XCTAssertEqual(registry.infos(caseLabel: "Case", now: t0 + 2).count, 1)
        // 超过广播 TTL 但 BLE 没来 → 消失（gauge 源是 SP？这里 gauge 是 SP 写的，用 SP TTL）
        registry.prune(now: t0 + HeadphoneRegistry.systemProfilerTTL + 1)
        XCTAssertTrue(registry.infos(caseLabel: "Case", now: t0 + 2).isEmpty)
    }
}

extension HeadphoneRegistryTests {
    /// 合盖/闲置 AirPods 广播稀疏：放宽 TTL 后，10 分钟内的旧读数保留，
    /// 超过才过期（第二副耳机不再在扫描间隙消失）。
    func testBroadcastGaugeSurvivesSparseBroadcasts() {
        var registry = HeadphoneRegistry()
        registry.ingest(advert(left: .init(percent: 54, isCharging: false)), name: "pods", now: t0)
        registry.prune(now: t0 + HeadphoneRegistry.broadcastTTL - 1)
        XCTAssertEqual(registry.infos(caseLabel: "Case", now: t0 + 2).count, 1)
        registry.prune(now: t0 + HeadphoneRegistry.broadcastTTL + 1)
        XCTAssertTrue(registry.infos(caseLabel: "Case", now: t0 + 2).isEmpty)
    }
}

extension HeadphoneRegistryTests {
    /// 充电标志是瞬态信息：电量保留，但⚡过 chargingTTL 后必须消失；
    /// SP 刷新（不报充电状态）不能给旧⚡续命。
    func testChargingFlagExpiresWhileLevelStays() {
        var registry = HeadphoneRegistry()
        registry.ingest(advert(left: .init(percent: 100, isCharging: true),
                               caseBattery: .init(percent: 93, isCharging: false)),
                        name: "pods", now: t0)
        // 新鲜时：L 有⚡，盒没有
        var infos = registry.infos(caseLabel: "Case", now: t0 + 1)
        XCTAssertEqual(infos[0].gauges.map(\.isCharging), [true, false])

        // SP 刷新一轮（不报告充电状态）
        registry.applySystemProfiler([
            .init(name: "pods", left: 100, right: nil, caseLevel: 93, productID: nil),
        ], now: t0 + 60)

        // chargingTTL 后：电量还在，⚡已消失（SP 没给旧⚡续命）
        infos = registry.infos(caseLabel: "Case", now: t0 + HeadphoneRegistry.chargingTTL + 1)
        XCTAssertEqual(infos[0].gauges.map(\.percent), [100, 93])
        XCTAssertEqual(infos[0].gauges.map(\.isCharging), [false, false])
    }

    // MARK: - 查找网络影子记录（2026-10-27）

    /// 用户实际遇到「面板显示三个 AirPods Pro」：其中一条是「查找」网络的
    /// 影子设备（名字以 `Find My` 结尾、只有左右耳没有充电盒），它不是一副
    /// 新耳机，两个数据源都必须忽略它。
    func testFindMyShadowWithoutBatteryIsIgnoredFromBothSources() {
        var registry = HeadphoneRegistry()
        // 广播里没有电量 → 纯影子，丢弃
        registry.ingest(advert(modelID: 0x200E), name: "Tony's AirPods Pro - Find My", now: t0)
        // 快照里也没有电量 → 同样丢弃；有电量的那条是真设备，必须保留
        registry.applySystemProfiler([
            .init(name: "AirPods Pro - Find My", left: 90, right: 90, caseLevel: nil, productID: 0x2024),
            .init(name: "Tony's AirPods Pro - Find My", left: nil, right: nil, caseLevel: nil, productID: 0x200E),
        ], now: t0)

        let infos = registry.infos(caseLabel: "Case", now: t0)
        XCTAssertEqual(infos.map(\.name), ["AirPods Pro - Find My"],
                       "有电量的 Find My 名字条目是真耳机，必须保留")
    }

    /// 0.8.67 的回归：真耳机被注册成 `... - Find My` 且带电量时，不能被当成影子藏掉。
    func testFindMyNamedEntryWithBatteryIsKept() {
        var registry = HeadphoneRegistry()
        registry.applySystemProfiler([
            .init(name: "AirPods Pro - Find My", left: 90, right: 90, caseLevel: nil, productID: 0x2024),
        ], now: t0)

        let infos = registry.infos(caseLabel: "Case", now: t0)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].gauges.map(\.percent), [90, 90])
    }

    /// 纯影子（无电量）不能把真配对记录挤掉；有电量的 `... - Find My` 是真设备，照常显示。
    /// 实测场景（2026-10-27）：机上有 3 副实体 AirPods（3 个不同序列号），
    /// 其中一副就叫 `AirPods Pro - Find My`（L/R 90%），还有一条同名但无电量的纯影子。
    func testRealPairSurvivesShadowFiltering() {
        var registry = HeadphoneRegistry()
        registry.applySystemProfiler([
            .init(name: "tony's AirPods Pro newest", left: 100, right: 100, caseLevel: 95, productID: 0x2024),
            .init(name: "AirPods Pro - Find My", left: 90, right: 90, caseLevel: nil, productID: 0x2024),
            .init(name: "Tony's AirPods Pro - Find My", left: nil, right: nil, caseLevel: nil, productID: 0x200E),
        ], now: t0)

        let infos = registry.infos(caseLabel: "Case", now: t0)
        XCTAssertEqual(infos.map(\.name).sorted(), ["AirPods Pro - Find My", "tony's AirPods Pro newest"])
        let newest = infos.first { $0.name == "tony's AirPods Pro newest" }
        XCTAssertEqual(newest?.gauges.map(\.percent), [100, 100, 95])
        let findMyNamed = infos.first { $0.name == "AirPods Pro - Find My" }
        XCTAssertEqual(findMyNamed?.gauges.map(\.percent), [90, 90])
    }

    /// 判定函数本身：大小写/空白不敏感，正常名字不误伤。
    func testIsFindMyShadow() {
        XCTAssertTrue(HeadphoneRegistry.isFindMyShadow("AirPods Pro - Find My", hasBattery: false))
        XCTAssertTrue(HeadphoneRegistry.isFindMyShadow("  Tony's AirPods Pro - find my  ", hasBattery: false))
        XCTAssertFalse(HeadphoneRegistry.isFindMyShadow("AirPods Pro - Find My", hasBattery: true))
        XCTAssertFalse(HeadphoneRegistry.isFindMyShadow("tony's AirPods Pro", hasBattery: false))
        XCTAssertFalse(HeadphoneRegistry.isFindMyShadow("tony's AirPods Pro newest", hasBattery: true))
    }
}
