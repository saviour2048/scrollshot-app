import Foundation
import Combine

/// 菜单栏用量表每一列(左/右)显示哪个来源;.none = 该列不显示。
enum MenuBarSlot: String, CaseIterable, Identifiable {
    case none
    case claude
    case kimi
    case codex
    case deepseek
    case opencode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:   return "无"
        case .claude: return "Claude"
        case .kimi:   return "Kimi"
        case .codex:  return "Codex"
        case .deepseek: return "DeepSeek"
        case .opencode: return "OpenCode"
        }
    }
}

/// What the menu-bar status item shows as live text next to its icon.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case sessionWeekly // two lines: session % (top) + weekly % (bottom)
    case session       // session window % left
    case weekly        // weekly window % left
    case todayCost     // today's $ spend
    case iconOnly      // no text, just the icon meter
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionWeekly: return "本次周期 + 本周(两行)"
        case .session:       return "本次周期剩余 %"
        case .weekly:        return "本周剩余 %"
        case .todayCost:     return "今日花费 $"
        case .iconOnly:      return "只显示图标"
        }
    }
}

/// User-configurable settings for the usage monitor (UserDefaults-backed).
enum UsageMonitorSettings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "usage.enabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "usage.enabled") }
    }

    static var menuBarLeft: MenuBarSlot {
        get { MenuBarSlot(rawValue: d.string(forKey: "usage.menuBarLeft") ?? "") ?? .claude }
        set { d.set(newValue.rawValue, forKey: "usage.menuBarLeft") }
    }

    static var menuBarRight: MenuBarSlot {
        get { MenuBarSlot(rawValue: d.string(forKey: "usage.menuBarRight") ?? "") ?? .none }
        set { d.set(newValue.rawValue, forKey: "usage.menuBarRight") }
    }

    /// 一次性:把旧的单选 usage.menuBarSource 迁移成左/右两列。
    /// 旧 key 保留不删(降级兼容),迁移后代码不再读它。
    static func migrateToSlotsIfNeeded() {
        guard !d.bool(forKey: "usage.migratedSlots") else { return }
        d.set(true, forKey: "usage.migratedSlots")
        switch d.string(forKey: "usage.menuBarSource") ?? "claude" {
        case "kimi":  menuBarLeft = .kimi;  menuBarRight = .none
        case "codex": menuBarLeft = .codex; menuBarRight = .none
        case "both":  menuBarLeft = .claude; menuBarRight = .kimi
        default:      menuBarLeft = .claude; menuBarRight = .none
        }
    }

    static var showCatIcon: Bool {
        get { d.object(forKey: "usage.showCatIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "usage.showCatIcon") }
    }

    static var menuBarMetric: MenuBarMetric {
        get { MenuBarMetric(rawValue: d.string(forKey: "usage.menuBarMetric") ?? "") ?? .sessionWeekly }
        set { d.set(newValue.rawValue, forKey: "usage.menuBarMetric") }
    }

    /// Seconds between auto-refreshes. 0 = manual only.
    static var refreshInterval: TimeInterval {
        get {
            let v = d.object(forKey: "usage.refreshInterval") as? Double
            return v ?? 120
        }
        set { d.set(newValue, forKey: "usage.refreshInterval") }
    }
}

/// Owns the usage snapshot: polls the limits API + scans local logs, and
/// publishes results to the SwiftUI dashboard and the AppKit status item.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isRefreshing = false

    /// Called on the main thread after every snapshot change (for the status item).
    var onUpdate: ((UsageSnapshot) -> Void)?

    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "com.scrollshot.usage.scan", qos: .utility)

    private init() {}

    func start() {
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the refresh cadence (call after the user changes it in settings).
    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        let interval = UsageMonitorSettings.refreshInterval
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if isRefreshing { return }
        isRefreshing = true

        // Pipeline B — local cost/token scan (off the main thread).
        scanQueue.async { [weak self] in
            let cost = UsageLogScanner.scan()
            Task { @MainActor in
                guard let self else { return }
                if cost.hasData {
                    self.apply { $0.cost = cost; $0.costError = nil }
                } else if cost.filesScanned == 0 {
                    self.apply(stamp: false) {
                        $0.cost = nil
                        $0.costError = "未找到 Claude Code 本地日志。\n花费/Token 估算需要 Claude Code CLI 生成的 ~/.claude/projects/*.jsonl 文件。"
                    }
                } else {
                    self.apply(stamp: false) {
                        $0.cost = nil
                        $0.costError = "找到 \(cost.filesScanned) 个日志文件，但未解析到 usage 数据。\n可能是 Claude Code 更新了日志格式。"
                    }
                }
            }
        }

        // Pipeline A — remote limits.
        //   1. Try the Claude Code OAuth/CLI token (native API).
        //   2. If that fails, fall back to a user-supplied claude.ai browser sessionKey.
        Task { @MainActor in
            do {
                let limits = try await fetchClaudeLimits()
                apply { $0.limits = limits; $0.limitsError = nil }
            } catch {
                // Keep the last-known limits on screen, but DON'T bump updatedAt —
                // otherwise the header's "更新于 X 前" lies while numbers are frozen.
                apply(stamp: false) { $0.limitsError = error.localizedDescription }
            }
            isRefreshing = false
        }

        // Pipeline C — Kimi coding quota (only when a key is configured).
        if KimiSettings.isConfigured {
            Task { @MainActor in
                do {
                    let kimi = try await KimiUsageFetcher.fetch()
                    apply { $0.kimi = kimi; $0.kimiError = nil }
                } catch {
                    apply(stamp: false) { $0.kimiError = error.localizedDescription }
                }
            }
        }

        // Pipeline D — Codex(ChatGPT 订阅)用量(仅当本机 codex CLI 已登录)。
        if CodexSettings.isConfigured {
            Task { @MainActor in
                do {
                    let codex = try await CodexUsageFetcher.fetch()
                    apply { $0.codex = codex; $0.codexError = nil }
                } catch {
                    apply(stamp: false) { $0.codexError = error.localizedDescription }
                }
            }
        }

        // Pipeline E — DeepSeek 余额(复用 AI 对话的 baseURL + key,都配了才查)。
        if LLMSettings.isConfigured,
           !LLMSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { @MainActor in
                do {
                    let deepseek = try await DeepSeekBalanceFetcher.fetch()
                    apply { $0.deepseek = deepseek; $0.deepseekError = nil }
                } catch {
                    apply(stamp: false) { $0.deepseekError = error.localizedDescription }
                }
            }
        }
        // Pipeline F — DeepSeek 控制台账号整体消耗(独立于余额 pipeline,只看 consoleToken)。
        if DeepSeekConsoleSettings.isConfigured {
            Task { @MainActor in
                do {
                    let usage = try await DeepSeekConsoleUsageFetcher.fetch()
                    apply { $0.deepseekUsage = usage; $0.deepseekUsageError = nil }
                } catch {
                    apply(stamp: false) { $0.deepseekUsageError = error.localizedDescription }
                }
            }
        }
        // Pipeline G — OpenCode Go 套餐用量(零配置,复用 opencode CLI 本机 key)。
        if OpenCodeSettings.isConfigured {
            Task { @MainActor in
                do {
                    let opencode = try await OpenCodeUsageFetcher.fetch()
                    apply { $0.opencode = opencode; $0.opencodeError = nil }
                } catch {
                    apply(stamp: false) { $0.opencodeError = error.localizedDescription }
                }
            }
        }
    }

    private func fetchClaudeLimits() async throws -> UsageLimits {
        do {
            return try await ClaudeUsageAPI.fetchLimits()
        } catch {
            guard ClaudeWebSettings.isConfigured else { throw error }
            return try await ClaudeWebUsageFetcher.fetchLimits(sessionKey: ClaudeWebSettings.sessionKey)
        }
    }

    /// - Parameter stamp: pass `false` for error-only updates so `updatedAt`
    ///   keeps marking the last *successful* data, not the last failed poll.
    private func apply(stamp: Bool = true, _ mutate: (inout UsageSnapshot) -> Void) {
        var s = snapshot
        mutate(&s)
        if stamp { s.updatedAt = Date() }
        snapshot = s
        onUpdate?(s)
    }

    /// Returns true if any known limit/rate window has already reset but the
    /// snapshot still reflects the old window. Used by the dashboard's live
    /// countdown to trigger a data refresh exactly at the reset boundary.
    func hasExpiredWindow(now: Date = Date()) -> Bool {
        let windows = [
            snapshot.limits?.session?.resetsAt,
            snapshot.limits?.weekly?.resetsAt,
            snapshot.limits?.weeklyOpus?.resetsAt,
            snapshot.limits?.weeklySonnet?.resetsAt,
            snapshot.limits?.routines?.resetsAt,
            snapshot.kimi?.rate?.resetAt,
            snapshot.kimi?.weekly?.resetAt,
            snapshot.codex?.primary?.resetAt,
            snapshot.codex?.secondary?.resetAt,
            snapshot.opencode?.rolling?.resetAt,
            snapshot.opencode?.weekly?.resetAt,
            snapshot.opencode?.monthly?.resetAt
        ].compactMap { $0 }
        return windows.contains { $0 <= now }
    }
}
