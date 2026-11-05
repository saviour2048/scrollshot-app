import SwiftUI

/// 刘海审批设置页：总开关 + 每家 agent 的 hook 安装状态与单独装/卸按钮。
struct AgentBridgePane: View {
    @StateObject private var featureSwitches = FeatureSwitches.shared
    @State private var statuses: [String: HookInstaller.Status] = [:]

    private static let dshID = "dsh"

    var body: some View {
        Card(title: L("settings.agentBridge.title")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.agentBridge.enable"), isOn: masterBinding)
                Text(L("settings.agentBridge.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.ssHairline)

                ForEach(HookInstaller.Agent.allCases) { agent in
                    agentRow(id: agent.rawValue, name: agent.displayName,
                             hint: agent == .kimi ? L("settings.agentBridge.kimiHint") : nil)
                }
                agentRow(id: Self.dshID, name: "dsh", hint: L("settings.agentBridge.dshHint"))
            }
        }
        .onAppear(perform: refresh)
    }

    // MARK: - Master switch

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { featureSwitches.isEnabled(.agentBridge) },
            set: { on in
                // `revision` bumps inside setEnabled only when it goes through
                // FeatureSwitches; enable()/disable() already call it.
                if on { AgentBridgeSetup.enable() } else { AgentBridgeSetup.disable() }
                refresh()
            }
        )
    }

    // MARK: - Per-agent rows

    private func agentRow(id: String, name: String, hint: String?) -> some View {
        let status = statuses[id] ?? .notInstalled
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 13)).foregroundColor(.ssText)
                Text(statusText(status))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                Spacer()
                if status != .agentMissing {
                    Button(status == .installed
                           ? L("settings.agentBridge.uninstall")
                           : L("settings.agentBridge.install")) {
                        AgentBridgeSetup.setAgent(id, installed: status != .installed)
                        refresh()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(status == .installed ? .ssMuted : .ssBlue)
                }
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        let installer = HookInstaller()
        var map: [String: HookInstaller.Status] = [:]
        for agent in HookInstaller.Agent.allCases {
            map[agent.rawValue] = installer.status(agent)
        }
        map[Self.dshID] = DshPluginInstaller().status()
        statuses = map
    }

    private func statusColor(_ status: HookInstaller.Status) -> Color {
        switch status {
        case .installed:    return .ssGreen
        case .notInstalled: return .ssMuted
        case .modified:     return .ssOrange
        case .agentMissing: return .ssMuted.opacity(0.4)
        }
    }

    private func statusText(_ status: HookInstaller.Status) -> String {
        switch status {
        case .installed:    return L("settings.agentBridge.status.installed")
        case .notInstalled: return L("settings.agentBridge.status.notInstalled")
        case .modified:     return L("settings.agentBridge.status.modified")
        case .agentMissing: return L("settings.agentBridge.status.missing")
        }
    }
}
