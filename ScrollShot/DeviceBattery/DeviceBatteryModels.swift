import Foundation

/// 本机电池"充电中"标记的判定。macOS 在 100% 充满后把 IsCharging 上报为
/// false，但只要还接着适配器（注册表 ExternalConnected / IOPS 电源状态
/// "AC Power"），系统菜单栏电池和 AirBattery 都显示⚡——对齐这个行为。
enum InternalBatteryCharging {
    static func showsCharging(isCharging: Bool, externalConnected: Bool, acPowered: Bool) -> Bool {
        isCharging || externalConnected || acPowered
    }
}

/// 一台设备的电量快照。大多数设备只有一节电池；AirPods/Beats 这类耳机
/// 同时有左耳、右耳、充电盒三个电量，用 `gauges` 里的多条记录表示。
struct DeviceBatteryInfo: Identifiable, Equatable {
    enum Category: Equatable {
        case thisMac, keyboard, trackpad, mouse, headphones
    }

    struct Gauge: Equatable {
        /// 标签（"L"/"R"/充电盒）；单电池设备为 nil。
        var label: String?
        var percent: Int
        var isCharging: Bool
    }

    let id: String
    var category: Category
    var name: String
    /// 具体型号（如 "AirPods Pro 2"），未知为 nil。
    var model: String?
    var gauges: [Gauge]
    /// 补充说明（本机电池：剩余时间/循环次数）。
    var detail: String?
    var updatedAt: Date

    var lowestPercent: Int { gauges.map(\.percent).min() ?? 0 }
    var isCharging: Bool { gauges.contains(where: \.isCharging) }
}

// MARK: - AirPods / Beats BLE 广播解析

/// 一节电池的广播读数。percent 范围 0...100。
struct HeadphoneBatteryReading: Equatable {
    var percent: Int
    var isCharging: Bool

    /// 0% 且充电中是广播字节的边界/占位产物（原始字节 0x80 或 0x65...0x7F，
    /// 对应"失联但带了充电位"），真机上几乎不代表真实电量——不展示，也不
    /// 参与"最低电量"比较。
    var isPlausible: Bool { !(percent == 0 && isCharging) }
}

/// 从一条 Apple 厂商 BLE 广播里解出的耳机状态。
struct HeadphoneAdvertisement: Equatable {
    /// 开盖包带型号 ID；合盖包不带（为 nil）。
    var modelID: UInt16?
    var lidOpen: Bool
    var left: HeadphoneBatteryReading?
    var right: HeadphoneBatteryReading?
    var caseBattery: HeadphoneBatteryReading?
}

/// AirPods/Beats 耳机在附近持续广播的电量包解析器（纯被动接收，不配对不连接）。
///
/// 广播包布局是逆向出来的客观事实（AirBattery 等项目均有记录）：
/// - 开盖包 29 字节，`data[2] == 7`：字节 5/6 是型号 ID（小端），字节 14/15/16
///   依次是右/左/盒的电量字节（左右顺序由字节 7 的 0x20 位翻转），电量字节
///   0xFF 表示失联，大于 0x64 表示正在充电（减去 0x80 得到真实电量）。
/// - 合盖包 25 字节，`data[2] == 18`：字节 12/13/14 依次是盒/左/右电量，
///   编码规则同上，不带型号 ID。
enum AirPodsAdvertisementParser {
    static let appleCompanyID: UInt16 = 0x004C

    static func parse(_ data: Data) -> HeadphoneAdvertisement? {
        guard data.count >= 3 else { return nil }
        let companyID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        guard companyID == appleCompanyID else { return nil }

        if data.count == 29, data[2] == 7 {
            // 开盖包。字节 7 的 0x20 位决定左右耳槽位是否互换。
            let leftIndex = (data[7] & 0x20) == 0 ? 15 : 14
            let rightIndex = leftIndex == 15 ? 14 : 15
            return HeadphoneAdvertisement(
                modelID: UInt16(data[5]) | (UInt16(data[6]) << 8),
                lidOpen: true,
                left: decodeLevel(data[leftIndex]),
                right: decodeLevel(data[rightIndex]),
                caseBattery: decodeLevel(data[16])
            )
        }
        if data.count == 25, data[2] == 18 {
            return HeadphoneAdvertisement(
                modelID: nil,
                lidOpen: false,
                left: decodeLevel(data[13]),
                right: decodeLevel(data[14]),
                caseBattery: decodeLevel(data[12])
            )
        }
        return nil
    }

    /// 电量字节编码：0x00~0x64 = 0~100% 不充电；0x81~0xE4 = 充电中，电量为
    /// 原值减 0x80（1~100%）。其余都是无效值：0xFF = 失联/不在盒内，
    /// 0x65~0x80 是无效区间（含以前被误当"0% 充电"的 0x80），0xE5~0xFE 超出
    /// 编码上限——一律按丢弃处理，不能解出假充电位。
    static func decodeLevel(_ raw: UInt8) -> HeadphoneBatteryReading? {
        if raw <= 0x64 {
            return HeadphoneBatteryReading(percent: Int(raw), isCharging: false)
        }
        if raw >= 0x81, raw <= 0xE4 {
            return HeadphoneBatteryReading(percent: Int(raw) - 0x80, isCharging: true)
        }
        return nil
    }
}

/// BLE 广播包里的型号 ID → 产品名。ID 表来自广播协议本身（公开事实数据）。
enum HeadphoneModelCatalog {
    static func name(for modelID: UInt16) -> String? {
        switch modelID {
        case 0x2002: return "AirPods"
        case 0x200F: return "AirPods 2"
        case 0x2013: return "AirPods 3"
        case 0x2019, 0x201B: return "AirPods 4"
        case 0x200E: return "AirPods Pro"
        case 0x2014, 0x2024: return "AirPods Pro 2"
        case 0x200A, 0x201F: return "AirPods Max"
        case 0x2003: return "Powerbeats 3"
        case 0x200D: return "Powerbeats 4"
        case 0x200B: return "Powerbeats Pro"
        case 0x200C: return "Beats Solo Pro"
        case 0x2011: return "Beats Studio Buds"
        case 0x2010: return "Beats Flex"
        case 0x2005: return "BeatsX"
        case 0x2006: return "Beats Solo 3"
        case 0x2009: return "Beats Studio 3"
        case 0x2017: return "Beats Studio Pro"
        case 0x2012: return "Beats Fit Pro"
        case 0x2016: return "Beats Studio Buds+"
        default: return nil
        }
    }
}
