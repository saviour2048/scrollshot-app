import Combine
import SwiftUI

/// 「线缆检测」偏好设置面板。
///
/// 数据来自 vendored 的 WhatCable Core / Darwin 后端（MIT，
/// 见 CableInfo/LICENSE-WHATCABLE.txt）。诊断文案（端口状态、充电瓶颈等）
/// 全部复用上游 `PortSummary` / `ChargingDiagnostic` 的既有逻辑，这里只做展示。
///
/// 该功能依赖 macOS 14+ 的 Apple 芯片端口控制器（AppleHPMInterface），
/// 低版本系统或 Intel Mac 上端口列表为空，因此整个面板按 macOS 14 门控。
struct CableInfoPane: View {
    var body: some View {
        if #available(macOS 14, *) {
            CableInfoPaneContent()
        } else {
            Card(title: "线缆检测") {
                Text("需要 macOS 14 或更高版本（且为 Apple 芯片）。")
                    .font(.system(size: 12))
                    .foregroundColor(.ssMuted)
            }
        }
    }
}

// MARK: - Store

@available(macOS 14, *)
@MainActor
final class CableInfoStore: ObservableObject {
    @Published private(set) var snapshot: CableSnapshot?
    @Published private(set) var errorMessage: String?
    /// 实时输入功率（瓦），0 表示未接外部电源或读数不可用。
    @Published private(set) var chargerInputWatts: Int = 0

    private let provider: any CableSnapshotProvider
    private var watchTask: Task<Void, Never>?
    /// 只在面板可见时读取实时功率（默认关闭，不产生 SMC 读取）。
    private let liveWatcher = PowerSourceWatcher()
    private var liveTask: Task<Void, Never>?
    private var liveCancellables = Set<AnyCancellable>()

    init(provider: (any CableSnapshotProvider)? = nil) {
        self.provider = provider ?? makeDefaultSnapshotProvider()
    }

    func start() {
        if watchTask == nil {
            watchTask = Task { [provider] in
                do {
                    for try await snap in provider.watch() {
                        self.snapshot = snap
                        self.errorMessage = nil
                    }
                } catch {
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
        startLivePower()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        stopLivePower()
    }

    private func startLivePower() {
        guard liveTask == nil else { return }
        liveWatcher.$chargerInputWatts
            .sink { [weak self] in self?.chargerInputWatts = $0 }
            .store(in: &liveCancellables)
        liveWatcher.readsChargerInputWatts = true
        liveTask = Task { [liveWatcher] in
            while !Task.isCancelled {
                liveWatcher.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopLivePower() {
        liveTask?.cancel()
        liveTask = nil
        liveCancellables.removeAll()
        liveWatcher.readsChargerInputWatts = false
    }
}

// MARK: - Per-port presentation

/// 一个端口的展示模型。字段收集逻辑与上游 `WidgetSnapshot.init(from:)`
/// 一致（同样的 join / liveness / 瓦数解析），只是保留完整的
/// `PortSummary`（含全部 bullets）和原始 PDO / e-marker 数据。
@available(macOS 14, *)
private struct PortPresentation: Identifiable {
    let port: AppleHPMInterface
    let summary: PortSummary
    let sources: [PowerSource]
    let devices: [USBDevice]
    let cableIdentity: USBPDSOP?
    let charging: ChargingDiagnostic?

    var id: UInt64 { port.id }
    var title: String { port.portDescription ?? port.serviceName }
    var isEmpty: Bool { summary.status == .empty }
    var iconName: String { WidgetSnapshot.Status(from: summary.status).iconName }

    static func presentations(for cable: CableSnapshot) -> [PortPresentation] {
        let activePortCount = cable.ports.filter { $0.connectionActive == true }.count
        let chargerSourceCount = ChargerWattageSource.chargerSourceCount(
            ports: cable.ports, sources: cable.powerSources)
        let chargerAttached = (cable.adapter?.watts ?? 0) > 0

        return cable.ports.map { port in
            let devices = port.matchingDevices(from: cable.usbDevices)
            let sources = cable.powerSources.filter { $0.canonicallyMatches(port: port) }
            let identities = cable.identities.filter { $0.canonicallyMatches(port: port) }

            let isLive = isPortLive(
                port: port,
                powerSources: sources,
                identities: identities,
                matchingDevices: devices,
                chargerAttached: chargerAttached
            )
            let wattageSource = ChargerWattageSource.resolve(
                portSources: sources,
                activePortCount: activePortCount,
                chargerSourceCount: chargerSourceCount,
                adapter: cable.adapter
            )
            let summary = PortSummary(
                port: port,
                sources: sources,
                identities: identities,
                devices: devices,
                thunderboltSwitches: cable.thunderboltSwitches,
                federatedIdentities: cable.federatedIdentities,
                usb3Transports: cable.usb3Transports.filter { $0.canonicallyMatches(port: port) },
                trmTransports: cable.trmTransports.filter { $0.canonicallyMatches(port: port) },
                cioCapability: cable.cioCapabilities.first { $0.canonicallyMatches(port: port) },
                isConnectedOverride: isLive,
                chargerWattageSource: wattageSource,
                batteryFullyCharged: cable.batteryFullyCharged,
                batteryIsCharging: cable.batteryIsCharging,
                adapter: cable.adapter
            )
            let anotherPortCharging = cable.powerSources.contains {
                !$0.canonicallyMatches(port: port) && $0.winning != nil
            }
            let charging = ChargingDiagnostic(
                port: port,
                sources: sources,
                identities: identities,
                adapter: cable.adapter,
                wattageSource: wattageSource,
                batteryFullyCharged: cable.batteryFullyCharged,
                batteryIsCharging: cable.batteryIsCharging,
                anotherPortActivelyCharging: anotherPortCharging,
                federatedIdentities: cable.federatedIdentities
            )
            let cableIdentity = identities.first(where: {
                $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
            }) ?? identities.first(where: { $0.identifiesAsCable })

            return PortPresentation(
                port: port,
                summary: summary,
                sources: sources,
                devices: devices,
                cableIdentity: cableIdentity,
                charging: charging
            )
        }
    }
}

// MARK: - Content

@available(macOS 14, *)
private struct CableInfoPaneContent: View {
    @StateObject private var store = CableInfoStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            livePowerCard

            if let error = store.errorMessage {
                Card(title: "线缆检测") {
                    Text("读取端口状态失败：\(error)")
                        .font(.system(size: 12))
                        .foregroundColor(.ssOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let snapshot = store.snapshot {
                let presentations = PortPresentation.presentations(for: snapshot)
                if presentations.isEmpty {
                    Card(title: "线缆检测") {
                        Text("未检测到 USB-C 端口控制器。此功能仅支持 Apple 芯片 Mac。")
                            .font(.system(size: 12))
                            .foregroundColor(.ssMuted)
                    }
                } else {
                    ForEach(presentations) { presentation in
                        CableInfoPortCard(presentation: presentation)
                    }
                }
            } else if store.errorMessage == nil {
                Card(title: "线缆检测") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取端口状态…")
                            .font(.system(size: 12))
                            .foregroundColor(.ssMuted)
                    }
                }
            }

            Text("线缆检测能力基于开源项目 WhatCable（MIT）")
                .font(.system(size: 11))
                .foregroundColor(.ssMuted)
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private var livePowerCard: some View {
        Card(title: "功率") {
            VStack(alignment: .leading, spacing: 8) {
                powerRow("Mac 当前取电", store.chargerInputWatts > 0 ? store.chargerInputWatts : nil)
            }
        }
    }

    private func powerRow(_ label: String, _ watts: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.ssMuted)
                .frame(width: 88, alignment: .leading)
            Text(watts.map { "\($0) W" } ?? "—")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(watts == nil ? .ssMuted : .ssText)
        }
    }
}

// MARK: - Port card

@available(macOS 14, *)
private struct CableInfoPortCard: View {
    let presentation: PortPresentation

    var body: some View {
        Card(title: presentation.title) {
            if presentation.isEmpty {
                emptyBody
            } else {
                connectedBody
            }
        }
    }

    private var emptyBody: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.iconName)
                .font(.system(size: 13))
                .foregroundColor(.ssMuted)
            Text("未连接")
                .font(.system(size: 13))
                .foregroundColor(.ssMuted)
        }
    }

    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 一句话状态
            HStack(spacing: 8) {
                Image(systemName: presentation.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(.ssBlue)
                Text(presentation.summary.headline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.ssText)
            }
            if !presentation.summary.subtitle.isEmpty {
                Text(presentation.summary.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 充电诊断横幅
            if let charging = presentation.charging {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: charging.isWarning ? "exclamationmark.triangle.fill" : "bolt.fill")
                        .font(.system(size: 12))
                        .foregroundColor(charging.isWarning ? .ssOrange : .ssGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(charging.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(charging.isWarning ? .ssOrange : .ssText)
                        Text(charging.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.ssMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((charging.isWarning ? Color.ssOrange : Color.ssGreen).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // PortSummary 诊断要点
            ForEach(presentation.summary.bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 6) {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.ssMuted)
                    Text(bullet)
                        .font(.system(size: 11))
                        .foregroundColor(.ssSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 线缆 e-marker 信息
            if let identity = presentation.cableIdentity {
                cableSection(identity)
            }

            // PDO 列表
            pdoSection

            // 挂载的 USB 设备
            if !presentation.devices.isEmpty {
                deviceSection
            }
        }
    }

    private func cableSection(_ identity: USBPDSOP) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("线缆信息（e-marker）")
            infoRow("厂商", VendorDB.label(for: identity.vendorID))
            if let vdo = identity.cableVDO {
                infoRow("速度", vdo.reportSpeedLabel)
                infoRow("功率", "\(vdo.maxWatts)W · 最高 \(vdo.maxVolts)V")
            }
            let curated = CableDB.curatedCables(vid: identity.vendorID, pid: identity.productID)
            if let first = curated.first {
                infoRow("品牌库匹配", "\(first.brand)（\(first.speed) / \(first.power)）")
            }
            if let xid = identity.certStatVDO?.xid, xid != 0 {
                let certs = CableDB.certifications(forXID: xid)
                if let cert = certs.first {
                    infoRow("USB-IF 认证", "\(cert.company) \(cert.model)")
                }
            }
        }
    }

    private var pdoSection: some View {
        let pdos = presentation.sources.flatMap { source -> [(PowerOption, Bool)] in
            source.options.map { ($0, $0 == source.winning) }
        }
        return Group {
            if !pdos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("供电档位（PDO）")
                    ForEach(Array(pdos.enumerated()), id: \.offset) { _, entry in
                        let (option, isWinning) = entry
                        HStack(spacing: 6) {
                            Text("\(option.voltsLabel) · \(option.ampsLabel) · \(option.wattsLabel)")
                                .font(.system(size: 11, weight: isWinning ? .semibold : .regular))
                                .foregroundColor(isWinning ? .ssText : .ssSecondary)
                            if isWinning {
                                Text("当前")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.ssGreen.opacity(0.12), in: Capsule())
                                    .foregroundColor(.ssGreen)
                            }
                        }
                    }
                }
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("USB 设备")
            ForEach(presentation.devices) { device in
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.ssSecondary)
                    Spacer()
                    Text(device.speedLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.ssMuted)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.ssMuted)
            .padding(.top, 2)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.ssMuted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.ssSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
