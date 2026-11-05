import XCTest
@testable import ScrollShot

final class DeviceBatteryParserTests: XCTestCase {

    /// 29 字节开盖包：data[2]=7，型号在字节 5/6（小端），电量在 14/15/16。
    private func makeOpenPacket(
        modelID: UInt16 = 0x2014,
        flip: Bool = false,
        left: UInt8, right: UInt8, caseLevel: UInt8
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x07
        bytes[5] = UInt8(modelID & 0xFF)
        bytes[6] = UInt8(modelID >> 8)
        bytes[7] = flip ? 0x20 : 0x00
        // flip 位(字节 7 的 0x20)置位时左耳在 14、右耳在 15，否则相反。
        bytes[14] = flip ? left : right
        bytes[15] = flip ? right : left
        bytes[16] = caseLevel
        return Data(bytes)
    }

    /// 25 字节合盖包：data[2]=18，电量在 13/14/12，无型号。
    private func makeClosedPacket(left: UInt8, right: UInt8, caseLevel: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x12
        bytes[12] = caseLevel
        bytes[13] = left
        bytes[14] = right
        return Data(bytes)
    }

    func testRejectsNonAppleManufacturer() {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0xE0
        bytes[1] = 0x00
        bytes[2] = 0x07
        XCTAssertNil(AirPodsAdvertisementParser.parse(Data(bytes)))
    }

    func testRejectsUnknownPacketLayout() {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x09   // 既不是开盖(7)也不是合盖(18)
        XCTAssertNil(AirPodsAdvertisementParser.parse(Data(bytes)))
        XCTAssertNil(AirPodsAdvertisementParser.parse(Data([0x4C, 0x00])))
    }

    func testOpenPacketDecodesLevelsAndModel() {
        // 左耳 80% 不充电，右耳 70% 充电中，盒 55%。
        let packet = makeOpenPacket(modelID: 0x2014, left: 80, right: 0x80 + 70, caseLevel: 55)
        let reading = AirPodsAdvertisementParser.parse(packet)
        XCTAssertEqual(reading?.modelID, 0x2014)
        XCTAssertEqual(reading?.lidOpen, true)
        XCTAssertEqual(reading?.left, HeadphoneBatteryReading(percent: 80, isCharging: false))
        XCTAssertEqual(reading?.right, HeadphoneBatteryReading(percent: 70, isCharging: true))
        XCTAssertEqual(reading?.caseBattery, HeadphoneBatteryReading(percent: 55, isCharging: false))
        XCTAssertEqual(HeadphoneModelCatalog.name(for: reading?.modelID ?? 0), "AirPods Pro 2")
    }

    func testOpenPacketFlipBitSwapsLeftRight() {
        let packet = makeOpenPacket(flip: true, left: 30, right: 90, caseLevel: 0xFF)
        let reading = AirPodsAdvertisementParser.parse(packet)
        XCTAssertEqual(reading?.left?.percent, 30)
        XCTAssertEqual(reading?.right?.percent, 90)
        XCTAssertNil(reading?.caseBattery)   // 0xFF = 失联
    }

    func testClosedPacketLayout() {
        let packet = makeClosedPacket(left: 0xFF, right: 60, caseLevel: 0x80 + 40)
        let reading = AirPodsAdvertisementParser.parse(packet)
        XCTAssertEqual(reading?.lidOpen, false)
        XCTAssertNil(reading?.modelID)
        XCTAssertNil(reading?.left)          // 左耳被取出 = 0xFF
        XCTAssertEqual(reading?.right, HeadphoneBatteryReading(percent: 60, isCharging: false))
        XCTAssertEqual(reading?.caseBattery, HeadphoneBatteryReading(percent: 40, isCharging: true))
    }

    func testDecodeLevelBoundaries() {
        XCTAssertNil(AirPodsAdvertisementParser.decodeLevel(0xFF))          // 失联
        XCTAssertEqual(AirPodsAdvertisementParser.decodeLevel(0x00),
                       HeadphoneBatteryReading(percent: 0, isCharging: false))
        XCTAssertEqual(AirPodsAdvertisementParser.decodeLevel(0x64),        // 100% 不充电
                       HeadphoneBatteryReading(percent: 100, isCharging: false))
        XCTAssertEqual(AirPodsAdvertisementParser.decodeLevel(0x81),        // 充电下限 = 1%
                       HeadphoneBatteryReading(percent: 1, isCharging: true))
        XCTAssertEqual(AirPodsAdvertisementParser.decodeLevel(0xE4),        // 100% 充电中
                       HeadphoneBatteryReading(percent: 100, isCharging: true))
        // 无效区间一律丢弃，不能解出假充电位/假电量。
        for raw: UInt8 in [0x65, 0x6F, 0x7F, 0x80, 0xE5, 0xF0, 0xFE] {
            XCTAssertNil(AirPodsAdvertisementParser.decodeLevel(raw), "0x\(String(raw, radix: 16)) 应为无效")
        }
    }
}

/// 本机电池充电标记：接着适配器就显示⚡，即使 100% 已充满（IsCharging=false）。
final class InternalBatteryChargingTests: XCTestCase {
    func testFullOnAdapterShowsBolt() {
        XCTAssertTrue(InternalBatteryCharging.showsCharging(isCharging: false, externalConnected: true, acPowered: true))
    }
    func testFullOnBatteryShowsNoBolt() {
        XCTAssertFalse(InternalBatteryCharging.showsCharging(isCharging: false, externalConnected: false, acPowered: false))
    }
    func testChargingOnAdapterShowsBolt() {
        XCTAssertTrue(InternalBatteryCharging.showsCharging(isCharging: true, externalConnected: true, acPowered: true))
    }
    func testDischargingOnBatteryShowsNoBolt() {
        XCTAssertFalse(InternalBatteryCharging.showsCharging(isCharging: false, externalConnected: false, acPowered: false))
    }

    /// 手动隐藏：按名字过滤，且不改变原有顺序（纯函数）。
    func testVisibleDevicesFiltersHiddenNames() {
        let mac = DeviceBatteryInfo(id: "mac", category: .thisMac, name: "Mac", model: nil,
                                    gauges: [], detail: nil, updatedAt: Date())
        let a = DeviceBatteryInfo(id: "airpods-a", category: .headphones, name: "A - Find My", model: nil,
                                  gauges: [], detail: nil, updatedAt: Date())
        let b = DeviceBatteryInfo(id: "airpods-b", category: .headphones, name: "B", model: nil,
                                  gauges: [], detail: nil, updatedAt: Date())

        XCTAssertEqual(DeviceBatteryStore.visible([mac, a, b], hidden: []).map(\.name), ["Mac", "A - Find My", "B"])
        XCTAssertEqual(DeviceBatteryStore.visible([mac, a, b], hidden: ["A - Find My"]).map(\.name), ["Mac", "B"])
        XCTAssertEqual(DeviceBatteryStore.visible([mac, a, b], hidden: ["Mac", "B"]).map(\.name), ["A - Find My"])
    }
}
