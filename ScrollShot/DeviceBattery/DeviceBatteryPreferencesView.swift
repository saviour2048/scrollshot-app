import SwiftUI
import CoreBluetooth

/// 「设备电量」设置页：总开关、刷新间隔、蓝牙授权状态（AirPods 广播依赖它）。
struct DeviceBatteryPreferencesView: View {
    @StateObject private var featureSwitches = FeatureSwitches.shared
    @StateObject private var batteryStore = DeviceBatteryStore.shared
    @State private var interval = DeviceBatteryStore.shared.refreshInterval
    @State private var bluetoothAuthorized = CBCentralManager.authorization == .allowedAlways
    @State private var menuBarSource = UserDefaults.standard.string(forKey: DeviceBatteryStore.menuBarSourceKey) ?? "lowest"

    private let intervalOptions: [TimeInterval] = [15, 30, 60, 120]

    private var enabled: Bool { featureSwitches.isEnabled(.deviceBattery) }

    var body: some View {
        Card(title: L("settings.module.deviceBattery")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("battery.enable"), isOn: Binding(
                    get: { enabled },
                    set: { featureSwitches.setEnabled(.deviceBattery, $0) }
                ))

                if enabled {
                    Divider().overlay(Color.ssHairline)

                    HStack {
                        Text(L("battery.refreshInterval"))
                            .font(.system(size: 14)).foregroundColor(.ssText)
                        Spacer()
                        Picker("", selection: $interval) {
                            ForEach(intervalOptions, id: \.self) { seconds in
                                Text(String(format: L("battery.interval.seconds"), Int(seconds)))
                                    .tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .onChange(of: interval) { value in
                            UserDefaults.standard.set(value, forKey: DeviceBatteryStore.intervalKey)
                            DeviceBatteryStore.shared.reschedule()
                        }
                    }

                    HStack {
                        Text(L("battery.source"))
                            .font(.system(size: 14)).foregroundColor(.ssText)
                        Spacer()
                        Picker("", selection: $menuBarSource) {
                            Text(L("battery.source.lowest")).tag("lowest")
                            Text(L("battery.source.thisMac")).tag("thisMac")
                            if !batteryStore.devices.isEmpty {
                                Divider()
                                ForEach(batteryStore.devices) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .onChange(of: menuBarSource) { value in
                            UserDefaults.standard.set(value, forKey: DeviceBatteryStore.menuBarSourceKey)
                            DeviceBatteryStatusItemController.shared.refreshDisplay()
                        }
                    }

                    Divider().overlay(Color.ssHairline)

                    HStack(spacing: 8) {
                        Text(L("battery.bluetooth"))
                            .font(.system(size: 13)).foregroundColor(.ssText)
                        Spacer()
                        StatusBadge(granted: bluetoothAuthorized)
                        if !bluetoothAuthorized {
                            Button(L("settings.openSettings")) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.ssSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.ssControlBorder, lineWidth: 1)
                            )
                            .buttonStyle(.plain)
                        }
                    }

                    Text(L("battery.hint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    // 被手动隐藏的设备：在这里一键放回（隐藏入口在菜单栏 popover 的右键菜单）
                    if !batteryStore.hiddenNames.isEmpty {
                        Divider().overlay(Color.ssHairline)
                        Text(L("battery.hiddenTitle"))
                            .font(.system(size: 13)).foregroundColor(.ssText)
                        ForEach(batteryStore.hiddenNames.sorted(), id: \.self) { name in
                            HStack(spacing: 8) {
                                Text(name)
                                    .font(.system(size: 12))
                                    .foregroundColor(.ssSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(L("battery.unhide")) {
                                    batteryStore.unhide(name: name)
                                }
                                .font(.system(size: 12))
                                .buttonStyle(.plain)
                                .foregroundColor(.ssSecondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            interval = DeviceBatteryStore.shared.refreshInterval
            bluetoothAuthorized = CBCentralManager.authorization == .allowedAlways
        }
    }
}
