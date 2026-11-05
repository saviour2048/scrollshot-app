import SwiftUI
import AppKit
import Combine

/// The full usage panel shown in the status-item popover.
/// Reuses the `ss*` color tokens defined in PreferencesView.
///
/// The body reads the store once and hands plain values to the section views
/// below, so a re-render (the 1s timer, snapshot updates) doesn't re-run the
/// store's property access through every section.
struct UsageDashboardView: View {
    @ObservedObject var store = UsageStore.shared
    @ObservedObject private var visibility = UsageDashboardVisibility.shared
    @State private var now = Date()
    @State private var timerConnection: Cancellable?

    // 手动 connect/cancel:只在 popover 可见时运行,关闭后立即停掉,
    // 避免 popover 关闭后仍每秒重渲染不可见界面、周期性触发 store.refresh()
    private let timer = Timer.publish(every: 1, on: .main, in: .common)

    var body: some View {
        let snap = store.snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardHeader(updatedAt: snap.updatedAt,
                                isRefreshing: store.isRefreshing,
                                onRefresh: { store.refresh() })
                LimitsSection(limits: snap.limits, error: snap.limitsError, now: now)
                KimiSection(kimi: snap.kimi, error: snap.kimiError, now: now)
                CodexSection(codex: snap.codex, error: snap.codexError, now: now)
                OpenCodeSection(opencode: snap.opencode, error: snap.opencodeError, now: now)
                DeepSeekSection(deepseek: snap.deepseek, error: snap.deepseekError,
                                usage: snap.deepseekUsage, usageError: snap.deepseekUsageError)
                footer
            }
            .padding(18)
        }
        .frame(width: 320, height: 460)
        .background(Color.ssPage)
        .onAppear {
            store.refresh()
            now = Date()
            setTimerRunning(visibility.isPopoverVisible)
        }
        .onDisappear { setTimerRunning(false) }
        .onChange(of: visibility.isPopoverVisible) { setTimerRunning($0) }
        .onReceive(timer) { _ in
            let previous = now
            now = Date()
            // If any rate window just crossed its reset boundary, refresh the data
            // so the UI doesn't show stale "0% remaining" after the window reset.
            if shouldAutoRefresh(since: previous) {
                store.refresh()
            }
        }
    }

    /// 按 popover 可见性连接/断开 1s 定时器;断开期间界面不刷新即可。
    private func setTimerRunning(_ running: Bool) {
        if running {
            guard timerConnection == nil else { return }
            timerConnection = timer.connect()
        } else {
            timerConnection?.cancel()
            timerConnection = nil
        }
    }

    /// Returns true if any limit/rate window has reached its reset time since
    /// the last tick, so the dashboard refreshes data right at the boundary.
    private func shouldAutoRefresh(since previous: Date) -> Bool {
        store.hasExpiredWindow(now: now) && !store.hasExpiredWindow(now: previous)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("额度来自 Claude 用量接口(需在本机登录订阅版 Claude Code),仅供参考。")
                .font(.system(size: 10)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("偏好设置…") { openSettings() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.ssBlue)
                Button("退出 ScrollShot") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.ssMuted)
            }
        }
    }

    private func openSettings() {
        PreferencesWindowController.shared.show()
    }
}

// MARK: - Sections (value-typed; they never touch UsageStore)

private struct DashboardHeader: View {
    let updatedAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code 用量").font(.system(size: 17, weight: .bold)).foregroundColor(.ssText)
                if let at = updatedAt {
                    Text("更新于 \(relative(at))").font(.system(size: 11)).foregroundColor(.ssMuted)
                }
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .foregroundColor(.ssBlue)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct LimitsSection: View {
    let limits: UsageLimits?
    let error: String?
    let now: Date

    var body: some View {
        if let err = error, limits == nil {
            CardBox {
                Text("额度暂不可用").font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let limits {
            CardBox {
                LimitRow(title: "本次 Session", window: limits.session, now: now)
                LimitRow(title: "本周", window: limits.weekly, now: now)
                LimitRow(title: "本周 · Opus", window: limits.weeklyOpus, now: now)
                LimitRow(title: "本周 · Sonnet", window: limits.weeklySonnet, now: now)
                LimitRow(title: "Daily Routines", window: limits.routines, now: now)
                // Last fetch failed → the numbers above are stale; say so.
                if let err = error {
                    Divider().overlay(Color.ssHairline)
                    Label("刷新失败,以上为上次成功数据:\(err)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(.ssOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct KimiSection: View {
    let kimi: KimiSnapshot?
    let error: String?
    let now: Date

    var body: some View {
        if let kimi {
            CardBox {
                if let r = kimi.rate {
                    LimitRow(title: "Kimi · 每 \(kimi.rateLabel ?? "频限")",
                             window: UsageWindow(utilization: r.usedPercent, resetsAt: r.resetAt),
                             now: now)
                }
                if let w = kimi.weekly {
                    LimitRow(title: "Kimi · 本周",
                             window: UsageWindow(utilization: w.usedPercent, resetsAt: w.resetAt),
                             now: now)
                }
            }
        } else if let err = error {
            CardBox {
                Text("Kimi 额度暂不可用").font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CodexSection: View {
    let codex: CodexSnapshot?
    let error: String?
    let now: Date

    var body: some View {
        if let codex {
            CardBox {
                HStack(spacing: 6) {
                    Text("Codex").font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                    if let plan = codex.planType {
                        Text(plan.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.ssBlue)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.ssBlue.opacity(0.10), in: Capsule())
                    }
                    Spacer()
                }
                if let p = codex.primary {
                    LimitRow(title: L("usage.codex.primary"),
                             window: UsageWindow(utilization: p.usedPercent, resetsAt: p.resetAt),
                             now: now)
                }
                if let s = codex.secondary {
                    LimitRow(title: L("usage.codex.secondary"),
                             window: UsageWindow(utilization: s.usedPercent, resetsAt: s.resetAt),
                             now: now)
                }
                if codex.creditsUnlimited {
                    Text(L("usage.codex.creditsUnlimited"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                } else if codex.hasCredits {
                    Text(String(format: L("usage.codex.creditsBalance"), codex.creditsBalance ?? "—"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                }
            }
        } else if let err = error {
            CardBox {
                Text(L("usage.codex.unavailable")).font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !CodexSettings.isConfigured {
            CardBox {
                Text(L("settings.usage.codexNotLoggedIn"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OpenCodeSection: View {
    let opencode: OpenCodeUsageSnapshot?
    let error: String?
    let now: Date

    var body: some View {
        if let opencode {
            CardBox {
                HStack(spacing: 6) {
                    Text("OpenCode Go").font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                    Spacer()
                }
                if let r = opencode.rolling {
                    LimitRow(title: L("usage.opencode.rolling"),
                             window: UsageWindow(utilization: r.usedPercent, resetsAt: r.resetAt),
                             now: now)
                }
                if let w = opencode.weekly {
                    LimitRow(title: L("usage.opencode.weekly"),
                             window: UsageWindow(utilization: w.usedPercent, resetsAt: w.resetAt),
                             now: now)
                }
                if let m = opencode.monthly {
                    LimitRow(title: L("usage.opencode.monthly"),
                             window: UsageWindow(utilization: m.usedPercent, resetsAt: m.resetAt),
                             now: now)
                }
            }
        } else if let err = error {
            CardBox {
                Text(L("usage.opencode.unavailable")).font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !OpenCodeSettings.isConfigured {
            CardBox {
                Text(L("settings.usage.opencodeNotLoggedIn"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DeepSeekSection: View {
    let deepseek: DeepSeekBalanceSnapshot?
    let error: String?
    let usage: DeepSeekUsageSnapshot?
    let usageError: String?

    /// 标题用 baseURL 的 host(去掉 api. 之类子域,取主域名首字母大写),取不到就 "API 服务"。
    private var serviceName: String {
        guard let host = URL(string: LLMSettings.baseURL)?.host else {
            return L("usage.deepseek.fallbackTitle")
        }
        var parts = host.split(separator: ".").map(String.init)
        if parts.count > 2 { parts.removeFirst() }
        return parts.first?.capitalized ?? L("usage.deepseek.fallbackTitle")
    }

    var body: some View {
        // 余额或消耗任一路有数据/有错误就显示;两个来源都没配置才整块隐藏
        let hasBalance = deepseek != nil || error != nil
        let hasUsage = usage != nil || usageError != nil
        if hasBalance || hasUsage {
            CardBox {
                Text(serviceName).font(.system(size: 13, weight: .semibold)).foregroundColor(.ssText)
                if let deepseek {
                    ForEach(Array(deepseek.balances.enumerated()), id: \.offset) { _, b in
                        Stat(title: b.currency, value: amount(b.total, currency: b.currency))
                        Text(String(format: L("usage.deepseek.detail"),
                                    amount(b.toppedUp, currency: b.currency),
                                    amount(b.granted, currency: b.currency)))
                            .font(.system(size: 11)).foregroundColor(.ssMuted)
                    }
                    if !deepseek.isAvailable {
                        Text(L("usage.deepseek.insufficient"))
                            .font(.system(size: 11)).foregroundColor(.ssOrange)
                    }
                } else if let err = error {
                    Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let usage {
                    Divider().overlay(Color.ssHairline)
                    Text(String(format: L("usage.deepseek.usageToday"),
                                money(usage.todayCost, currency: usage.currency),
                                UsageFormat.tokens(usage.todayTokens)))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                    Text(String(format: L("usage.deepseek.usage30d"),
                                money(usage.cost30d, currency: usage.currency),
                                UsageFormat.tokens(usage.tokens30d)))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                    if let top = usage.topModel {
                        Text(String(format: L("usage.deepseek.topModel"), top))
                            .font(.system(size: 11)).foregroundColor(.ssMuted)
                    }
                } else if let err = usageError {
                    Divider().overlay(Color.ssHairline)
                    Text(err).font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !DeepSeekConsoleSettings.isConfigured {
                    Divider().overlay(Color.ssHairline)
                    Text(L("usage.deepseek.usageHint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// CNY→¥ / USD→$,其它币种原样显示 currency code。
    private func amount(_ raw: String, currency: String) -> String {
        switch currency.uppercased() {
        case "CNY": return "¥\(raw)"
        case "USD": return "$\(raw)"
        default:    return "\(currency) \(raw)"
        }
    }

    /// Double 金额版(消耗接口的数字)。
    private func money(_ v: Double, currency: String) -> String {
        amount(String(format: "%.2f", v), currency: currency)
    }
}

// MARK: - Building blocks

private struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ssCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }
}

private struct LimitRow: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    var body: some View {
        if let w = window {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 13)).foregroundColor(.ssText)
                    Spacer()
                    Text("\(UsageFormat.percent(w.remainingPercent)) 剩余")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color(for: w.remainingPercent))
                    Text("· \(UsageFormat.countdown(to: w.resetsAt, now: now))")
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                }
                ProgressBar(fraction: w.remainingPercent / 100, color: color(for: w.remainingPercent))
                    .frame(height: 6)
                if let at = w.resetsAt {
                    Text("重置时间:\(UsageFormat.resetClock(to: at, now: now))")
                        .font(.system(size: 10.5)).foregroundColor(.ssMuted)
                }
            }
        }
    }

    private func color(for remaining: Double) -> Color {
        if remaining <= 10 { return .ssOrange }
        if remaining <= 25 { return Color(red: 0xFF/255, green: 0xCC/255, blue: 0x00/255) }
        return .ssGreen
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.ssHairline)
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundColor(.ssMuted)
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundColor(.ssText)
        }
    }
}
