import AppKit
import SwiftUI
import Combine

/// 「设备电量」菜单栏项：图标 + 最低电量设备的百分比，左键开 popover
/// （列出所有设备电量），右键弹主菜单。结构对齐 BrightnessStatusItemController。
@MainActor
final class DeviceBatteryStatusItemController: NSObject {
    static let shared = DeviceBatteryStatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private override init() { super.init() }

    private func subscribeIfNeeded() {
        guard cancellables.isEmpty else { return }
        DeviceBatteryStore.shared.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    func start() {
        guard FeatureSwitches.shared.isEnabled(.deviceBattery) else { return }
        subscribeIfNeeded()
        DeviceBatteryStore.shared.start()
        guard statusItem == nil else { return }
        // 固定宽度：百分比在 0…100 间变化时菜单栏不会抖动/挤占邻居。
        let item = NSStatusBar.system.statusItem(withLength: fixedLength())
        item.button?.font = titleFont
        item.button?.imagePosition = .imageLeft
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        render()
    }

    /// 功能关闭：撤掉状态栏项、订阅和采集资源，什么都不留。
    func stop() {
        cancellables.removeAll()
        DeviceBatteryStore.shared.stop()
        tearDown()
    }

    private func tearDown() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
    }

    /// 宽度按最坏情况（图标 + "100%"）一次算死。
    private func fixedLength() -> CGFloat {
        let textWidth = ("100%" as NSString).size(withAttributes: [.font: titleFont]).width
        return ceil(textWidth) + 34
    }

    /// 设置页改了"状态栏显示"来源后调用。
    func refreshDisplay() {
        render()
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        let devices = DeviceBatteryStore.shared.devices
        // 菜单栏显示哪台设备由设置决定；选"最低电量"时 0% 的脏读数不参与比较。
        let source = UserDefaults.standard.string(forKey: DeviceBatteryStore.menuBarSourceKey) ?? "lowest"
        let lowest = devices.filter { $0.lowestPercent > 0 }.min(by: { $0.lowestPercent < $1.lowestPercent })
        let device: DeviceBatteryInfo?
        switch source {
        case "thisMac":
            device = devices.first { $0.category == .thisMac } ?? lowest
        case "lowest":
            device = lowest
        default:
            device = devices.first { $0.id == source } ?? lowest
        }
        guard let device else {
            button.image = Self.firstAvailableSymbol(["battery.50"])
            button.title = ""
            button.toolTip = L("settings.module.deviceBattery")
            return
        }
        button.image = symbol(for: device)
        button.title = "\(device.lowestPercent)%"
        button.toolTip = devices.map { info in
            let parts = info.gauges.map { gauge in
                let label = gauge.label.map { "\($0) " } ?? ""
                return "\(label)\(gauge.percent)%" + (gauge.isCharging ? "⚡︎" : "")
            }.joined(separator: " · ")
            return "\(info.name): \(parts)"
        }.joined(separator: "\n")
    }

    private func symbol(for device: DeviceBatteryInfo) -> NSImage? {
        switch device.category {
        case .thisMac:
            return NSImage(systemSymbolName: batterySymbolName(percent: device.lowestPercent, charging: device.isCharging),
                           accessibilityDescription: device.name)
        case .keyboard:
            return Self.firstAvailableSymbol(["keyboard.fill", "keyboard"])
        case .trackpad:
            return Self.firstAvailableSymbol(["trackpad.fill", "rectangle.and.hand.point.up.left.fill", "computermouse"])
        case .mouse:
            return Self.firstAvailableSymbol(["magicmouse.fill", "computermouse.fill", "computermouse"])
        case .headphones:
            let model = device.model ?? ""
            if model.contains("Max") || model.contains("Solo") || model.contains("Studio") {
                return Self.firstAvailableSymbol(["beats.headphones", "headphones"])
            }
            return Self.firstAvailableSymbol(["airpodspro", "airpods", "headphones"])
        }
    }

    static func firstAvailableSymbol(_ names: [String]) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return image }
        }
        return nil
    }

    private func batterySymbolName(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover?.performClose(nil)
            let menu = MainMenuBarController.shared.makeMainMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        let rows = max(1, DeviceBatteryStore.shared.devices.count)
        let size = NSSize(width: 380, height: max(120, 64 + rows * 52))
        guard let popover else {
            let newPopover = NSPopover()
            newPopover.behavior = .transient
            newPopover.animates = true
            newPopover.contentSize = size
            newPopover.contentViewController = NSHostingController(rootView: DeviceBatteryPopoverView())
            self.popover = newPopover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if let popover = self?.popover, popover.isShown {
                    popover.performClose(nil)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            newPopover.contentViewController?.view.window?.makeKey()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentSize = size
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Popover

private struct DeviceBatteryPopoverView: View {
    @StateObject private var store = DeviceBatteryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.module.deviceBattery"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("battery.refresh")) { store.pollNow() }
                    .controlSize(.small)
            }

            if store.devices.isEmpty {
                Text(L("battery.empty"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.devices) { device in
                    DeviceBatteryRow(device: device)
                        // 同一副耳机换过名/重复配对时，系统蓝牙里会留下多条记录，
                        // 面板看起来就像多出几副耳机。允许手动隐藏多余的条目。
                        .contextMenu {
                            if device.category == .headphones {
                                Button(L("battery.hideDevice")) {
                                    store.hide(name: device.name)
                                }
                            }
                        }
                }
            }

            if store.bluetoothDenied {
                Text(L("battery.bluetoothDenied"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 340)
    }
}

private struct DeviceBatteryRow: View {
    let device: DeviceBatteryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                popoverSymbol(iconCandidates)
                    .font(.system(size: 13))
                    .frame(width: 20, alignment: .center)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let model = device.model {
                        Text(model)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if device.category == .headphones {
                    // 主电量 = 最低的一节；⚡只属于那一节自己（不能是所有
                    // gauge 的 OR——否则盒子的百分比会背上耳塞的充电标记）。
                    let main = device.gauges.min(by: { $0.percent < $1.percent })
                    GaugeChip(gauge: nil, percent: main?.percent ?? device.lowestPercent,
                              isCharging: main?.isCharging ?? false, emphasized: true)
                } else {
                    ForEach(Array(device.gauges.enumerated()), id: \.offset) { _, gauge in
                        GaugeChip(gauge: gauge, percent: gauge.percent,
                                  isCharging: gauge.isCharging, emphasized: true)
                    }
                }
            }
            if device.category == .headphones {
                HStack(spacing: 10) {
                    ForEach(Array(device.gauges.enumerated()), id: \.offset) { _, gauge in
                        GaugeChip(gauge: gauge, percent: gauge.percent,
                                  isCharging: gauge.isCharging, emphasized: false)
                    }
                }
                .padding(.leading, 28)
            }
            if let detail = device.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }
        }
    }

    /// 一节电池的电量小条：可选标签 + 电池分档图形 + 百分比。
    private struct GaugeChip: View {
        let gauge: DeviceBatteryInfo.Gauge?
        let percent: Int
        let isCharging: Bool
        let emphasized: Bool

        var body: some View {
            HStack(spacing: 3) {
                if let label = gauge?.label {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Image(systemName: DeviceBatteryRow.batteryGlyph(percent: percent, charging: isCharging))
                    .font(.system(size: emphasized ? 11 : 10))
                    .foregroundColor(color)
                Text("\(percent)%")
                    .font(.system(size: emphasized ? 12 : 11, weight: emphasized ? .medium : .regular))
                    .foregroundColor(percent <= 20 ? .orange : (emphasized ? .primary : .secondary))
            }
        }

        private var color: Color {
            if isCharging { return .green }
            if percent <= 20 { return .orange }
            return .secondary
        }
    }

    /// 电池图形按电量分档，充电中固定显示带闪电的满格（SF Symbols 只有
    /// battery.100 有 bolt 变体）。
    static func batteryGlyph(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }

    /// SwiftUI 的 Image(systemName:) 遇到系统没有的符号会渲染空白，
    /// 先用 NSImage 探测可用性再选第一个存在的。
    private func popoverSymbol(_ names: [String]) -> Image {
        for name in names where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return Image(systemName: name)
        }
        return Image(systemName: "questionmark.circle")
    }

    private var iconCandidates: [String] {
        switch device.category {
        case .thisMac:  return ["laptopcomputer"]
        case .keyboard: return ["keyboard"]
        case .trackpad: return ["trackpad.fill", "rectangle.and.hand.point.up.left.fill", "computermouse"]
        case .mouse:    return ["magicmouse.fill", "computermouse"]
        case .headphones:
            let model = device.model ?? ""
            if model.contains("Max") || model.contains("Solo") || model.contains("Studio") {
                return ["beats.headphones", "headphones"]
            }
            return ["airpodspro", "airpods", "headphones"]
        }
    }
}
