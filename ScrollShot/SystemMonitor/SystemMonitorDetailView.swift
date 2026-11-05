import SwiftUI
import AppKit

/// The popover shown when a system-monitor menu-bar item is clicked: the metric's
/// current value + the top processes using that resource (Stats-style).
struct SystemMonitorDetailView: View {
    let metric: SysMetric
    @ObservedObject var store = SystemMonitorStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: metric.icon)
                Text(metric.title).font(.headline)
                Spacer()
                Text(currentValue).font(.system(.title3, design: .rounded).weight(.semibold))
            }
            // 内存 popover 顺带显示当前内存压力(kern.memorystatus_level)。
            if metric == .memory, let level = store.stats.memPressureLevel {
                HStack {
                    Text(L("sysmon.memPressure.name")).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(100 - level)%")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(.secondary)
                }
                .frame(height: 20)
            }
            Divider()
            processSection
        }
        .padding(16)
        .frame(width: 300)
    }

    private var currentValue: String {
        let s = store.stats
        switch metric {
        case .cpu:
            return s.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .memory:
            if let u = s.memUsed, let t = s.memTotal { return "\(SysFormat.bytes(u)) / \(SysFormat.bytes(t))" }
            return "—"
        case .network:
            let d = s.netDown.map(SysFormat.rate) ?? "—"
            let u = s.netUp.map(SysFormat.rate) ?? "—"
            return "↓\(d)  ↑\(u)"
        case .temperature:
            return s.tempC.map { "\(Int($0.rounded()))°C" } ?? "—"
        case .fan:
            return s.fanRPM.map { "\(Int($0.rounded())) RPM" } ?? "—"
        case .simulator:
            guard s.simRunning, let m = s.simMemory else { return "未在跑" }
            let cpu = s.simCPU.map { " · CPU \(Int($0.rounded()))%" } ?? ""
            return "\(SysFormat.bytes(m))\(cpu)"
        }
    }

    @ViewBuilder private var processSection: some View {
        if metric == .simulator {
            simulatorSection
        } else if metric == .fan {
            fanSection
        } else if metric == .temperature {
            Text("各传感器").font(.caption).foregroundColor(.secondary)
            if store.stats.tempSensors.isEmpty {
                Text("这台机器读不到分组温度。").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(store.stats.tempSensors) { s in
                    HStack {
                        Text(s.name).font(.system(size: 12))
                        Spacer()
                        Text("\(Int(s.value.rounded()))°C")
                            .font(.system(size: 12, design: .rounded)).foregroundColor(.secondary)
                    }
                    .frame(height: 20)
                }
            }
        } else {
            Text("占用最高的进程").font(.caption).foregroundColor(.secondary)
            if processes.isEmpty {
                Text("读取中…").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(processes) { p in ProcRow(metric: metric, proc: p) }
            }
        }
    }

    private var processes: [ProcInfo] {
        switch metric {
        case .cpu:     return store.topCPU
        case .memory:  return store.topMemory
        case .network: return store.topNetwork
        case .simulator: return store.topSimulator
        case .temperature, .fan: return []
        }
    }

    /// 风扇 popover:每颗风扇的当前转速 + 该机型的风扇转速范围。
    @ViewBuilder private var fanSection: some View {
        Text("风扇").font(.caption).foregroundColor(.secondary)
        if store.stats.fanValues.isEmpty {
            Text("这台机器没有可读的风扇(无风扇机型,或 SMC 读不到)。")
                .font(.caption).foregroundColor(.secondary)
        } else {
            ForEach(store.stats.fanValues.indices, id: \.self) { i in
                HStack {
                    Text("风扇 \(i + 1)").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(store.stats.fanValues[i].rounded())) RPM")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(.secondary)
                }
                .frame(height: 20)
            }
            if let mn = store.stats.fanMin, let mx = store.stats.fanMax {
                HStack {
                    Text("转速范围").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(mn.rounded()))–\(Int(mx.rounded())) RPM")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                }
                .frame(height: 20)
            }
        }
    }

    /// 模拟器 popover：已启动的设备 + 占用最高的模拟器进程。
    @ViewBuilder private var simulatorSection: some View {
        Text("已启动的设备").font(.caption).foregroundColor(.secondary)
        if store.simDevices.isEmpty {
            Text(store.stats.simRunning ? "读取中…" : "当前没有模拟器在跑。")
                .font(.caption).foregroundColor(.secondary)
        } else {
            ForEach(store.simDevices, id: \.self) { name in
                HStack {
                    Image(systemName: "iphone").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                }
                .frame(height: 20)
            }
        }
        if store.stats.simRunning {
            Divider()
            Text("占用最高的进程").font(.caption).foregroundColor(.secondary)
            if store.topSimulator.isEmpty {
                Text("读取中…").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(store.topSimulator) { p in ProcRow(metric: metric, proc: p) }
            }
        }
    }
}

/// Merged-mode popover (fallback for macOS 27's menu-bar pile-up bug): a
/// segmented metric switcher on top of the regular detail view, so one
/// menu-bar item still reaches all four metrics.
struct SystemMonitorMergedDetailView: View {
    private let enabled = SysMetric.allCases.filter { SystemMonitorSettings.shows($0) }
    @State private var metric: SysMetric = SysMetric.allCases.first { SystemMonitorSettings.shows($0) } ?? .cpu

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $metric) {
                ForEach(enabled) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            SystemMonitorDetailView(metric: metric)
        }
        .onAppear { SystemMonitorStore.shared.openMetric = metric }
        .onChange(of: metric) { SystemMonitorStore.shared.openMetric = $0 }
    }
}

private struct ProcRow: View {
    let metric: SysMetric
    let proc: ProcInfo

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16, height: 16)
            Text(proc.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(valueText).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
        }
        .frame(height: 20)
    }

    @ViewBuilder private var icon: some View {
        if let img = NSRunningApplication(processIdentifier: pid_t(proc.pid))?.icon {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: "app.dashed").foregroundColor(.secondary)
        }
    }

    private var valueText: String {
        switch metric {
        case .cpu:     return String(format: "%.1f%%", proc.primary)
        case .memory:  return SysFormat.bytes(proc.primary)
        case .network: return "↓\(SysFormat.rate(proc.primary)) ↑\(SysFormat.rate(proc.secondary ?? 0))"
        case .simulator:
            let cpu = proc.secondary.map { " · \(Int($0.rounded()))%" } ?? ""
            return "\(SysFormat.bytes(proc.primary))\(cpu)"
        case .temperature: return ""
        case .fan: return ""
        }
    }
}
