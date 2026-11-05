import Foundation
import IOKit
import IOKit.ps
import CoreBluetooth
import AppKit
import os

/// 设备电量数据采集中心：本机内置电池（IOKit）+ Magic 键盘/触控板/鼠标
///（IORegistry）+ AirPods/Beats（CoreBluetooth 被动广播）。
///
/// 一个轮询 timer（默认 30s，设置里可调）驱动前两类采集并触发一轮 BLE
/// 扫描窗口；`system_profiler SPBluetoothDataType` 很慢，只在后台队列里
/// 每 5 分钟刷一次缓存，用来补 Magic 外设的用户自定义名称，以及作为已连接
/// 耳机的权威电量源（与 BLE 广播按系统蓝牙名合流，见 HeadphoneRegistry）。
/// 蓝牙未授权/关闭时优雅降级：只显示本机电池和 HID 外设。
@MainActor
final class DeviceBatteryStore: ObservableObject {
    static let shared = DeviceBatteryStore()

    static let enabledKey = "deviceBattery.enabled"
    static let intervalKey = "deviceBattery.refreshInterval"
    /// 菜单栏显示哪台设备："lowest"（最低电量）/ "thisMac" / 具体设备 id。
    static let menuBarSourceKey = "deviceBattery.menuBarSource"
    /// 用户手动隐藏的设备名（按系统蓝牙名，与耳机登记处的身份一致）。
    static let hiddenNamesKey = "deviceBattery.hiddenNames"

    @Published private(set) var devices: [DeviceBatteryInfo] = []
    /// 蓝牙被拒绝/受限（popover 和设置页据此提示用户去开授权）。
    @Published private(set) var bluetoothDenied = false
    /// 用户手动隐藏的设备（名字集合）。面板/菜单栏/选择器都不再显示它们。
    @Published private(set) var hiddenNames: Set<String> = []

    private var pollTimer: Timer?
    private var scanner: HeadphoneBroadcastScanner?
    private var running = false

    /// 耳机登记处：身份 = 系统蓝牙名；无名的 BLE 广播直接丢弃。
    private var registry = HeadphoneRegistry()

    /// system_profiler 蓝牙缓存：地址 → 用户自定义设备名 / 类型，
    /// 耳机名 → (左/右/盒电量百分比, 产品 ID)。
    private struct BluetoothSnapshot {
        var nameByAddress: [String: String] = [:]
        var typeByAddress: [String: String] = [:]
        var headphones: [HeadphoneRegistry.SystemProfilerReading] = []
    }
    private var btSnapshot = BluetoothSnapshot()
    private var btSnapshotFetchedAt = Date.distantPast
    private var btSnapshotLoading = false

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.hiddenNamesKey) {
            hiddenNames = Set(saved)
        }
    }

    /// 过滤掉用户隐藏的设备（纯函数，便于单测）。
    nonisolated static func visible(_ devices: [DeviceBatteryInfo], hidden: Set<String>) -> [DeviceBatteryInfo] {
        hidden.isEmpty ? devices : devices.filter { !hidden.contains($0.name) }
    }

    /// 隐藏一台设备（按系统蓝牙名）。用户遇到「同一副耳机留下多条旧记录」时用它清面板。
    func hide(name: String) {
        guard !name.isEmpty else { return }
        hiddenNames.insert(name)
        persistHidden()
        pollNow()
    }

    /// 把隐藏的设备放回面板。
    func unhide(name: String) {
        hiddenNames.remove(name)
        persistHidden()
        pollNow()
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenNames).sorted(), forKey: Self.hiddenNamesKey)
    }

    var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        return stored >= 10 ? stored : 30
    }

    // MARK: - 生命周期

    func start() {
        guard !running else { return }
        running = true
        scheduleTimer()
        if !AppConfig.suppressesPermissionPrompts {
            startBLEScannerIfPossible()
        }
        pollNow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        scanner?.stopScanning()
        scanner = nil
        running = false
    }

    /// 设置页改了刷新间隔后调用。
    func reschedule() {
        guard running else { return }
        scheduleTimer()
        pollNow()
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
    }

    // MARK: - 轮询

    func pollNow() {
        var next: [DeviceBatteryInfo] = []
        if let mac = readInternalBattery() { next.append(mac) }
        next.append(contentsOf: readMagicPeripherals())
        registry.prune()
        next.append(contentsOf: registry.infos(caseLabel: L("battery.case")))
        devices = Self.visible(next, hidden: hiddenNames)
        refreshBluetoothSnapshotIfNeeded()
        scanner?.scanWindow()
    }

    // MARK: - 本机内置电池

    private func readInternalBattery() -> DeviceBatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func intProperty(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        func boolProperty(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }

        var percent: Int?
        if let current = intProperty("CurrentCapacity"), let maxCap = intProperty("MaxCapacity"), maxCap > 0 {
            percent = Int((Double(current) / Double(maxCap)) * 100.0)
        }

        var charging = boolProperty("IsCharging")
        // 接着适配器就显示⚡，即使 100% 已充满（IsCharging 已满转 false）。
        let externalConnected = boolProperty("ExternalConnected")
        var acPowered = false
        var timeToEmpty: Int?
        var timeToFull: Int?
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        for source in IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array {
            let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any]
            if percent == nil, let current = info?[kIOPSCurrentCapacityKey] as? Int,
               let maxCap = info?[kIOPSMaxCapacityKey] as? Int, maxCap > 0 {
                percent = Int((Double(current) / Double(maxCap)) * 100.0)
            }
            if let isCharging = info?[kIOPSIsChargingKey] as? Bool { charging = isCharging }
            if let state = info?[kIOPSPowerSourceStateKey] as? String {
                acPowered = (state == kIOPSACPowerValue)
            }
            timeToEmpty = info?[kIOPSTimeToEmptyKey] as? Int
            timeToFull = info?[kIOPSTimeToFullChargeKey] as? Int
        }
        let showsCharging = InternalBatteryCharging.showsCharging(
            isCharging: charging, externalConnected: externalConnected, acPowered: acPowered
        )

        guard let percent else { return nil }

        var detailParts: [String] = []
        let minutes = charging ? timeToFull : timeToEmpty
        if let minutes, minutes > 0, !(percent == 100 && !charging) {
            let text = String(format: "%lld:%02lld", minutes / 60, minutes % 60)
            detailParts.append(String(format: charging ? L("battery.timeToFull") : L("battery.timeToEmpty"), text))
        }
        if let cycles = intProperty("CycleCount") {
            detailParts.append(String(format: L("battery.cycles"), cycles))
        }
        if let rawTemp = intProperty("Temperature") {
            detailParts.append(String(format: "%.0f°C", Double(rawTemp) / 100.0))
        }

        return DeviceBatteryInfo(
            id: "internal-battery",
            category: .thisMac,
            name: Host.current().localizedName ?? "Mac",
            model: nil,
            gauges: [.init(label: nil, percent: percent, isCharging: showsCharging)],
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            updatedAt: Date()
        )
    }

    // MARK: - Magic 外设（键盘 / 触控板 / 鼠标）

    private func readMagicPeripherals() -> [DeviceBatteryInfo] {
        // 新机型统一走 AppleDeviceManagementHIDEventService；老设备是后三个类。
        let serviceClasses = [
            "AppleDeviceManagementHIDEventService",
            "AppleBluetoothHIDKeyboard",
            "BNBTrackpadDevice",
            "BNBMouseDevice",
        ]
        var result: [DeviceBatteryInfo] = []
        var seenAddresses = Set<String>()
        for className in serviceClasses {
            var iterator = io_iterator_t()
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let info = readHIDBattery(entry),
                      !seenAddresses.contains(info.id) else { continue }
                seenAddresses.insert(info.id)
                result.append(info)
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private func readHIDBattery(_ entry: io_registry_entry_t) -> DeviceBatteryInfo? {
        func property(_ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        guard let rawPercent = property("BatteryPercent") as? Int, (0...100).contains(rawPercent) else { return nil }
        let product = property("Product") as? String ?? ""
        // 内置键盘/触控板也走 HID 服务，但不是电池设备。
        if product.contains("Internal") { return nil }

        let address = (property("DeviceAddress") as? String ?? "")
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
        let flags = property("BatteryStatusFlags") as? Int ?? 0
        // BatteryStatusFlags 是 bitfield，bit0 = 正在充电。
        let charging = (flags & 1) != 0

        let category: DeviceBatteryInfo.Category
        let typeHint = product.isEmpty ? (btSnapshot.typeByAddress[address] ?? "") : product
        if typeHint.contains("Trackpad") {
            category = .trackpad
        } else if typeHint.contains("Mouse") {
            category = .mouse
        } else {
            category = .keyboard
        }

        let name = btSnapshot.nameByAddress[address]
            ?? (product.isEmpty ? L("battery.hidDevice") : product)

        return DeviceBatteryInfo(
            id: address.isEmpty ? "hid-\(product)-\(rawPercent)" : "hid-\(address)",
            category: category,
            name: name,
            model: nil,
            gauges: [.init(label: nil, percent: rawPercent, isCharging: charging)],
            detail: nil,
            updatedAt: Date()
        )
    }

    // MARK: - AirPods / Beats（BLE 被动广播）

    private func startBLEScannerIfPossible() {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            bluetoothDenied = true
            return
        default:
            break
        }
        guard scanner == nil else { return }
        let scanner = HeadphoneBroadcastScanner()
        scanner.onReading = { [weak self] reading, name, _ in
            Task { @MainActor in self?.ingest(reading, name: name) }
        }
        scanner.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.bluetoothDenied = (state == .unauthorized)
            }
        }
        self.scanner = scanner
        scanner.scanWindow()
    }

    private func ingest(_ reading: HeadphoneAdvertisement, name: String?) {
        registry.ingest(reading, name: name)
        publishHeadphones()
    }

    private func publishHeadphones() {
        var next = devices.filter { $0.category != .headphones }
        next.append(contentsOf: registry.infos(caseLabel: L("battery.case")))
        devices = Self.visible(next, hidden: hiddenNames)
    }

    // MARK: - system_profiler 蓝牙缓存（慢，后台队列 + 5 分钟节流）

    private func refreshBluetoothSnapshotIfNeeded() {
        guard !btSnapshotLoading, Date().timeIntervalSince(btSnapshotFetchedAt) > 300 else { return }
        btSnapshotLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Self.loadBluetoothSnapshot()
            Task { @MainActor in
                guard let self else { return }
                if let snapshot {
                    self.btSnapshot = snapshot
                    // SP 的 device_connected 是已连接耳机的权威电量源，按名字合流
                    self.registry.applySystemProfiler(snapshot.headphones)
                    self.publishHeadphones()
                }
                self.btSnapshotFetchedAt = Date()
                self.btSnapshotLoading = false
            }
        }
    }

    private nonisolated static func loadBluetoothSnapshot() -> BluetoothSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              let bluetooth = sections.first else { return nil }

        var snapshot = BluetoothSnapshot()
        for sectionKey in ["device_connected", "device_not_connected"] {
            guard let entries = bluetooth[sectionKey] as? [[String: Any]] else { continue }
            for entry in entries {
                for (name, rawInfo) in entry {
                    guard let info = rawInfo as? [String: Any] else { continue }
                    if let address = (info["device_address"] as? String)?.uppercased() {
                        snapshot.nameByAddress[address] = name
                        if let minorType = info["device_minorType"] as? String {
                            snapshot.typeByAddress[address] = minorType
                        }
                    }
                    // 电量字段只有 device_connected（已连接设备）里有。
                    guard sectionKey == "device_connected" else { continue }
                    func level(_ key: String) -> Int? {
                        guard let text = info[key] as? String else { return nil }
                        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
                    }
                    let productID = (info["device_productID"] as? String)
                        .flatMap { UInt16($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                    let reading = HeadphoneRegistry.SystemProfilerReading(
                        name: name,
                        left: level("device_batteryLevelLeft"),
                        right: level("device_batteryLevelRight"),
                        caseLevel: level("device_batteryLevelCase"),
                        productID: productID
                    )
                    if reading.left != nil || reading.right != nil || reading.caseLevel != nil {
                        snapshot.headphones.append(reading)
                    }
                }
            }
        }
        return snapshot
    }
}

// MARK: - BLE 扫描器

/// 被动接收附近 AirPods/Beats 的电量广播。不配对、不连接，只看
/// advertisementData 里的 Apple manufacturerData。
final class HeadphoneBroadcastScanner: NSObject, CBCentralManagerDelegate {
    /// 回调都打在内部的串行 utility 队列上，调用方自行切回主线程。
    var onReading: ((HeadphoneAdvertisement, String?, UUID) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?

    private let queue = DispatchQueue(label: "com.scrollshot.app.device-battery.ble", qos: .utility)
    private var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// 开一个十几秒长的扫描窗口（对齐 AirBattery 的 15s 长扫描——AirPods
    /// 合盖/闲置时广播很稀疏，8s 窗口会漏掉另一副），窗口内允许重复广播。
    func scanWindow(seconds: TimeInterval = 15) {
        queue.async { [weak self] in
            guard let self, self.central.state == .poweredOn else { return }
            if !self.central.isScanning {
                self.central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
            }
            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.central.stopScan()
            }
        }
    }

    func stopScanning() {
        queue.async { [weak self] in self?.central.stopScan() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(central.state)
        if central.state == .poweredOn {
            scanWindow()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = AirPodsAdvertisementParser.parse(manufacturerData) else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if name == nil {
            // 配对设备的系统蓝牙名偶尔解析不出来；登记处会丢弃无名包。
            // 真机排查用：log stream --predicate 'subsystem == "com.scrollshot.app"'
            Diag.battery.debug("AirPods broadcast without resolvable name (model \(reading.modelID ?? 0, privacy: .public)) — dropped")
        }
        onReading?(reading, name, peripheral.identifier)
    }
}
