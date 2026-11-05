import AppKit
import SwiftUI

/// Manages the system-monitor menu-bar presence (Stats-style: CPU, 内存, 网络,
/// 温度). Default is one `NSStatusItem` per enabled metric — fixed width, so a
/// changing value never reflows the bar.
///
/// When the menu bar runs out of room, macOS doesn't keep our items visible:
/// on macOS 27 it either packs them onto identical coordinates (叠罗汉) or
/// leaves the item with only its offscreen shadow window at (0,−33), i.e. it
/// silently disappears. Both are "被折叠"; `MenuBarLayoutClassifier` detects
/// them from our own item windows, and we fall back to one compact two-line
/// item so every metric stays readable. When space comes back (display change,
/// wake) we try separate items again and merge only if they get eaten again.
/// Clicking opens a popover (current value + top processes); merged mode's
/// popover has a metric switcher.
@MainActor
final class SystemMonitorStatusItems: NSObject {
    static let shared = SystemMonitorStatusItems()

    private var items: [SysMetric: NSStatusItem] = [:]
    private var popovers: [SysMetric: NSPopover] = [:]
    private var running = false
    /// Rates the network image was last drawn from; drawing / setImage only when
    /// they change skips redundant menu-bar layout.
    private var lastNetRates: (up: Double?, down: Double?)?

    /// 内存压力曲线项: 固定宽度自定义面积图,与文本指标项并列,不参与 merged 回退。
    private var pressureItem: NSStatusItem?
    private var pressureView: MemoryPressureGraphView?

    // Merged single-item fallback (macOS 27+, see type doc).
    private var mergedItem: NSStatusItem?
    private var mergedView: SysMonitorMeterView?
    private var mergedPopover: NSPopover?
    /// 当前是否处于「合并成一个项」的布局。被折叠/叠罗汉时自动置 true；
    /// 换屏、唤醒时先尝试拆回独立项，仍然拥挤才会再合并（见 `checkLayout`）。
    private var merged = false
    /// Pile-up checks only run this long after a rebuild — freshly created item
    /// windows briefly report placeholder frames before the bar lays them out.
    private var lastRebuild = Date.distantPast

    /// 上次渲染时的模拟器运行状态: 变化时重建菜单栏项(出现/消失)。
    private var lastSimRunning = false

    /// 启用的指标。模拟器特殊: 只在没有模拟器在跑时从菜单栏隐藏(不占空间),
    /// 状态翻转由 render 里的 transition 检测触发 rebuild。
    private func enabledMetrics() -> [SysMetric] {
        SysMetric.allCases.filter {
            SystemMonitorSettings.shows($0)
                && ($0 != .simulator || SystemMonitorStore.shared.stats.simRunning)
        }
    }

    private override init() { super.init() }

    /// Re-probe the layout when displays change (monitor plugged/unplugged,
    /// wake from sleep): the merge is sticky within a configuration, but a new
    /// configuration may have room for separate items again.
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// 空间状况可能变好了（插拔屏 / 唤醒 / 分辨率变化）：先拆回独立项，
    /// 由 `checkLayout` 在 4 秒内重新判定——仍然折叠就再合并，够用就保持拆开。
    private func retrySeparateLayout() {
        mergeStrikes = 0
        restoreStrikes = 0
        guard merged else { return }
        merged = false
        rebuild()
    }

    func start() {
        guard SystemMonitorSettings.enabled, !running else { return }
        running = true
        SystemMonitorStore.shared.onUpdate = { [weak self] s in self?.render(s) }
        SystemMonitorStore.shared.start()
        rebuild()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retrySeparateLayout() }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retrySeparateLayout() }
            }
        }
    }

    func stop() {
        items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
        items.removeAll()
        popovers.removeAll()
        removePressureItem()
        if let item = mergedItem { NSStatusBar.system.removeStatusItem(item) }
        mergedItem = nil
        mergedView = nil
        mergedPopover = nil
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        screenObserver = nil
        if let obs = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        wakeObserver = nil
        notchStrip.hide()
        SystemMonitorStore.shared.onUpdate = nil
        SystemMonitorStore.shared.stop()
        running = false
    }

    /// Re-applies the enabled toggle and which metrics are shown.
    func reload() {
        if SystemMonitorSettings.enabled {
            // 关掉「自动合并」时立刻拆回独立项，不等下一次判定。
            if !SystemMonitorSettings.mergeWhenCrowded {
                merged = false
                mergeStrikes = 0
            }
            if running { rebuild() } else { start() }
        } else {
            stop()
        }
    }

    private func rebuild() {
        if !merged { notchStrip.hide() }
        items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
        items.removeAll()
        popovers.removeAll()
        lastNetRates = nil
        removePressureItem()
        if let item = mergedItem { NSStatusBar.system.removeStatusItem(item) }
        mergedItem = nil
        mergedView = nil
        mergedPopover = nil

        let enabled = enabledMetrics()

        // 内存压力曲线是独立的图形项。合并模式下不建它：它本身就要占 52pt，
        // 而菜单栏已经满到把我们的项挤没了——这时候把空间让给数值更有价值
        // （曲线的历史仍然可以在弹窗里看）。
        if SystemMonitorSettings.showsMemPressure, !merged {
            let item = NSStatusBar.system.statusItem(withLength: MemoryPressureGraphView.width)
            item.autosaveName = "sysmon_memPressure"
            item.button?.image = nil
            item.button?.title = ""
            let view = MemoryPressureGraphView(frame: NSRect(x: 0, y: 0, width: MemoryPressureGraphView.width, height: NSStatusBar.system.thickness))
            item.button?.addSubview(view)
            pressureItem = item
            pressureView = view
        }

        guard !enabled.isEmpty else {
            render(SystemMonitorStore.shared.stats)
            lastRebuild = Date()
            return
        }

        if merged {
            // One compact two-line item holding every enabled metric. Width is
            // fixed at creation from worst-case samples — setting item.length
            // on every update would reflow (and visibly shift) the whole bar.
            let w = mergedLength(enabled)
            let item = NSStatusBar.system.statusItem(withLength: w)
            // 让系统记住用户 ⌘ 拖动过的位置，重建（合并/拆开）后不会被丢到最左边。
            item.autosaveName = "sysmon_merged"
            let view = SysMonitorMeterView(frame: NSRect(x: 0, y: 0, width: w, height: NSStatusBar.system.thickness))
            view.onClick = { [weak self] _ in self?.clickedMerged() }
            item.button?.image = nil
            item.button?.title = ""
            item.button?.addSubview(view)
            mergedItem = item
            mergedView = view

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: SystemMonitorMergedDetailView())
            mergedPopover = popover
        } else {
            for metric in enabled {
                // Fixed width so a changing value never reflows / jitters the menu bar.
                let item = NSStatusBar.system.statusItem(withLength: fixedLength(metric))
                item.autosaveName = "sysmon_\(metric.rawValue)"
                item.button?.font = statusFont
                item.button?.alignment = .left
                item.button?.target = self
                item.button?.action = #selector(clicked(_:))
                if metric == .network { item.button?.imagePosition = .imageOnly }
                items[metric] = item

                let popover = NSPopover()
                popover.behavior = .transient
                popover.delegate = self
                popover.contentViewController = NSHostingController(rootView: SystemMonitorDetailView(metric: metric))
                popovers[metric] = popover
            }
        }
        render(SystemMonitorStore.shared.stats)
        lastRebuild = Date()
    }

    private func removePressureItem() {
        if let item = pressureItem { NSStatusBar.system.removeStatusItem(item) }
        pressureItem = nil
        pressureView = nil
    }

    private func render(_ s: SystemStats) {
        // 模拟器开/关状态翻转 → 重建菜单栏项(出现或消失)。rebuild 末尾会再调
        // render, 此时 lastSimRunning 已更新, 不会递归。
        if s.simRunning != lastSimRunning {
            lastSimRunning = s.simRunning
            if running, SystemMonitorSettings.shows(.simulator) {
                rebuild()
                return
            }
        }
        if let view = pressureView {
            view.set(history: SystemMonitorStore.shared.memPressureHistory)
            if let level = s.memPressureLevel {
                pressureItem?.button?.toolTip = String(format: L("sysmon.memPressure.tooltip"), 100 - level)
            }
        }
        if merged {
            guard let view = mergedView, let item = mergedItem else { return }
            checkLayout()
            if MenuBarLayoutProbe.loggingEnabled {
                let samples = MenuBarLayoutProbe.samples(for: [item])
                MenuBarLayoutProbe.log(samples, crowded: MenuBarLayoutClassifier.isCrowded(samples), merged: true)
            }
            let enabled = enabledMetrics()
            let values = enabled.map { compactValue(for: $0, s) }
            view.set(values: values)
            item.button?.toolTip = zip(enabled, values)
                .map { "\($0.title): \($1)" }
                .joined(separator: "  ·  ")
            return
        }
        for (metric, item) in items {
            guard let button = item.button else { continue }
            if metric == .network {
                // Two-line stacked (↑ over ↓) drawn as a template image — narrower
                // than a single inline line, and it adapts to the menu-bar tint.
                // setTitle/setImage each trigger a menu-bar relayout, so skip
                // unless the rates actually changed.
                let rates = (up: s.netUp, down: s.netDown)
                if lastNetRates.map({ $0 != rates }) ?? true {
                    button.image = networkImage(s)
                    lastNetRates = rates
                }
            } else if metric == .fan {
                // 风扇图标 + 转速数字,比 "风扇 1200" 省宽度。
                if button.image == nil {
                    button.image = fanImage
                    button.imagePosition = .imageLeading
                }
                let t = title(for: metric, s)
                if button.title != t { button.title = t }
            } else {
                let t = title(for: metric, s)
                if button.title != t { button.title = t }
            }
        }
        checkLayout()
    }

    /// 合并态下把数值同步到刘海旁边的小条；拆开后收起来。
    private func updateNotchStrip(_ values: [String], on screen: NSScreen) {
        notchStrip.show(on: screen, text: values.joined(separator: "   "))
    }

    /// 点刘海旁的小条：弹合并版详情。
    private func openNotchDetail() {
        guard let view = notchStrip.anchorView() else { return }
        if mergedPopover?.isShown == true { mergedPopover?.performClose(nil); return }
        let popover: NSPopover
        if let existing = mergedPopover {
            popover = existing
        } else {
            let p = NSPopover()
            p.behavior = .transient
            p.delegate = self
            p.contentViewController = NSHostingController(rootView: SystemMonitorMergedDetailView())
            mergedPopover = p
            popover = p
        }
        SystemMonitorStore.shared.openMetric = SysMetric.allCases.first { SystemMonitorSettings.shows($0) }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// 容量模型：菜单栏装不下 → 合并；装得下 → 拆开。两个方向都用同一把尺子量。
    ///
    /// 为什么不用「看窗口有没有被折叠」当唯一判据：实测里 `button.window` 只给出
    /// 我们项所在的**一块**屏的窗口，另一块屏上那些项是被系统复制过去画的，
    /// 我们看不到它们有没有被折进 «；而「主屏」还会在插拔/切屏时换。所以这里量
    /// 的是**用量**：
    ///   usedNow      = 屏右边缘 − 我们最左那个项的左边（= 整条状态栏实际占用）
    ///   我们需要的宽度 = usedNow − 当前我们占的 + 目标布局占的
    /// 然后和每块屏的可用宽度（刘海屏只有右半边）比较：任一块屏装不下就合并。
    private func checkLayout() {
        guard SystemMonitorSettings.mergeWhenCrowded else { return }
        guard Date().timeIntervalSince(lastRebuild) > 2 else { return }
        guard let measured = measure() else { mergeStrikes = 0; restoreStrikes = 0; return }

        let neededSeparate = measured.used - measured.footprintNow + footprint(merged: false)
        let tightest = NSScreen.screens.map { MenuBarLayoutProbe.statusAreaWidth(of: $0) }.min() ?? .infinity
        let fits = neededSeparate + 8 <= tightest

        // 刘海屏 + 外接屏同时存在时，宁可画数值条也不合并：合并对所有屏同时
        // 生效，会顺带把外接屏的独立项也变没，不该为内建屏牺牲大屏。
        // 但如果只有刘海屏一块屏（没有外接屏可牺牲），就走下面的正常合并逻辑：
        // 浮条画在 App 菜单区里又和状态项重复，用户只会觉得乱。
        if let notchScreen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }),
           NSScreen.screens.contains(where: { $0.auxiliaryTopRightArea == nil }) {
            let plainTightest = NSScreen.screens
                .filter { $0.auxiliaryTopRightArea == nil }
                .map { MenuBarLayoutProbe.statusAreaWidth(of: $0) }
                .min() ?? .infinity
            if plainTightest.isFinite, neededSeparate + 8 > plainTightest {
                // 外接屏也装不下：走合并
            } else {
                if !fits {
                    updateNotchStrip(enabledMetrics().map { compactValue(for: $0, SystemMonitorStore.shared.stats) },
                                     on: notchScreen)
                } else {
                    notchStrip.hide()
                }
                if merged {
                    merged = false
                    rebuild()
                }
                return
            }
        }
        notchStrip.hide()

        if merged {
            guard fits else { restoreStrikes = 0; return }
            restoreStrikes += 1
            guard restoreStrikes >= 3 else { return }   // ≈6s 才拆，避免抖
            restoreStrikes = 0
            merged = false
            notchStrip.hide()
            rebuild()
            NSLog("[ScrollShot] sysmon: separate layout fits (%.0f <= %.0f) → back to separate",
                  neededSeparate, tightest)
        } else {
            // 叠罗汉是兜底判据：那种状态下量出来的 used 不可靠。
            let piled = MenuBarLayoutClassifier.isCrowded(
                MenuBarLayoutProbe.samples(for: Array(items.values)))
            guard !fits || piled else { mergeStrikes = 0; return }
            mergeStrikes += 1
            guard mergeStrikes >= 2 else { return }
            mergeStrikes = 0
            merged = true
            rebuild()
            NSLog("[ScrollShot] sysmon: menu bar too small (need %.0f, tightest %.0f, piled=%d) → merged",
                  neededSeparate, tightest, piled ? 1 : 0)
        }
    }
    private var mergeStrikes = 0
    private var restoreStrikes = 0
    private let notchStrip = NotchStripWindow()

    private struct Measurement { let used: CGFloat; let footprintNow: CGFloat }

    private func measure() -> Measurement? {
        var windows = items.values.compactMap { $0.button?.window }
        if let w = mergedItem?.button?.window { windows.append(w) }
        guard let anchor = windows.first, let screen = anchor.screen else { return nil }
        // 只看和锚点同一块屏、且真的摆出来了的窗口（x=0 是"没摆到这块屏"）。
        let xs = windows.filter { $0.screen == screen }.map { $0.frame.minX }
        guard let leftmost = xs.min(), leftmost - screen.frame.minX > 1 else { return nil }
        return Measurement(used: screen.frame.maxX - leftmost, footprintNow: footprintNow())
    }

    /// 当前布局下我们（系统监控）占的宽度。
    private func footprintNow() -> CGFloat { footprint(merged: merged) }

    private func footprint(merged isMerged: Bool) -> CGFloat {
        let metrics = enabledMetrics()
        guard !metrics.isEmpty else { return 0 }
        let graph: CGFloat = SystemMonitorSettings.showsMemPressure && !isMerged
            ? MemoryPressureGraphView.width + 8 : 0
        if isMerged {
            return mergedLength(metrics) + 16 + graph
        }
        return metrics.reduce(0) { $0 + fixedLength($1) + 16 + 8 } + graph
    }

    /// Short label for one metric in the merged meter (no "CPU"/"内存" prefixes —
    /// the tooltip carries the full names).
    private func compactValue(for metric: SysMetric, _ s: SystemStats) -> String {
        switch metric {
        case .cpu:
            return s.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .memory:
            return s.memUsed.map(SysFormat.bytes) ?? "—"
        case .network:
            let d = s.netDown.map(SysFormat.rateCompact) ?? "—"
            let u = s.netUp.map(SysFormat.rateCompact) ?? "—"
            return "↓\(d) ↑\(u)"
        case .temperature:
            return s.tempC.map { "\(Int($0.rounded()))°" } ?? "—°"
        case .fan:
            return s.fanRPM.map { "\(Int($0.rounded()))rpm" } ?? "—rpm"
        case .simulator:
            return s.simMemory.map { "SIM \(SysFormat.bytes($0))" } ?? "SIM —"
        }
    }

    private func clickedMerged() {
        guard let button = mergedItem?.button, let popover = mergedPopover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            SystemMonitorStore.shared.openMetric = SysMetric.allCases.first { SystemMonitorSettings.shows($0) }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func title(for metric: SysMetric, _ s: SystemStats) -> String {
        switch metric {
        case .cpu:
            return s.cpuPercent.map { "CPU \(Int($0.rounded()))%" } ?? "CPU —"
        case .memory:
            return s.memUsed.map { "内存 \(SysFormat.bytes($0))" } ?? "内存 —"
        case .network:
            let d = s.netDown.map(SysFormat.rateCompact) ?? "—"
            let u = s.netUp.map(SysFormat.rateCompact) ?? "—"
            return "↓\(d) ↑\(u)"
        case .temperature:
            return s.tempC.map { "\(Int($0.rounded()))°" } ?? "—°"
        case .fan:
            return s.fanRPM.map { "\(Int($0.rounded()))" } ?? "—"
        case .simulator:
            return s.simMemory.map(SysFormat.bytes) ?? "—"
        }
    }

    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    /// 风扇项的模板图标(跟随菜单栏明暗/高亮着色),只设一次,避免每次刷新重排。
    private lazy var fanImage: NSImage? = {
        let img = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "风扇转速")
        img?.isTemplate = true
        return img
    }()

    /// Renders the network rates as two stacked lines (↑ top, ↓ bottom) into a
    /// template image, vertically centered in the menu bar.
    private func networkImage(_ s: SystemStats) -> NSImage {
        let down = "↓" + (s.netDown.map(SysFormat.rateCompact) ?? "—")
        let up   = "↑" + (s.netUp.map(SysFormat.rateCompact) ?? "—")
        let attrs: [NSAttributedString.Key: Any] = [.font: networkFont, .foregroundColor: NSColor.black]
        let dStr = NSAttributedString(string: down, attributes: attrs)
        let uStr = NSAttributedString(string: up, attributes: attrs)

        let h = NSStatusBar.system.thickness
        let lineH = min(ceil(networkFont.ascender - networkFont.descender), h / 2)   // ~11
        let w = ceil(max(dStr.size().width, uStr.size().width))
        let y0 = max((h - lineH * 2) / 2, 0)   // vertically center the two-line block

        let img = NSImage(size: NSSize(width: max(w, 1), height: h))
        img.lockFocus()
        dStr.draw(at: NSPoint(x: 0, y: y0))            // bottom line: download
        uStr.draw(at: NSPoint(x: 0, y: y0 + lineH))    // top line: upload
        img.unlockFocus()
        img.isTemplate = true    // adopt the menu-bar tint (light/dark, highlighted)
        return img
    }

    /// A fixed menu-bar width sized to each metric's worst-case value, so live
    /// updates don't reflow the bar.
    private func fixedLength(_ metric: SysMetric) -> CGFloat {
        if metric == .network {
            // Two-line: width is just the single widest line.
            let w = ("↓888M" as NSString).size(withAttributes: [.font: networkFont]).width
            return ceil(w) + 6
        }
        let sample: String
        switch metric {
        case .cpu:         sample = "CPU 100%"
        case .memory:      sample = "内存 99.9G"
        case .temperature: sample = "100°"
        case .fan:
            // 图标 + 最多四位数转速。
            let w = ("4900" as NSString).size(withAttributes: [.font: statusFont]).width
            return ceil(w) + 16 + 6
        case .simulator:   sample = "SIM 99.9G"
        case .network:     sample = ""
        }
        let width = (sample as NSString).size(withAttributes: [.font: statusFont]).width
        return ceil(width) + 6
    }

    /// Worst-case width of the merged two-line meter, so value updates never
    /// reflow the menu bar.
    private func mergedLength(_ enabled: [SysMetric]) -> CGFloat {
        let samples: [SysMetric: String] = [
            .cpu: "100%", .memory: "99.9G", .network: "↓888K ↑888K", .temperature: "100°",
            .fan: "4900rpm",
            .simulator: "99.9G",
        ]
        let values = enabled.map { samples[$0] ?? "——" }
        let split = (values.count + 1) / 2
        let attrs: [NSAttributedString.Key: Any] = [.font: SysMonitorMeterView.font]
        let top = (values.prefix(split).joined(separator: " ") as NSString).size(withAttributes: attrs).width
        let bottom = (values.suffix(from: split).joined(separator: " ") as NSString).size(withAttributes: attrs).width
        return ceil(max(top, bottom)) + SysMonitorMeterView.padding * 2
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let (metric, item) = items.first(where: { $0.value.button === sender }),
              let popover = popovers[metric], let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Close any other open popover first.
            popovers.values.forEach { if $0.isShown { $0.performClose(nil) } }
            SystemMonitorStore.shared.openMetric = metric
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

extension SystemMonitorStatusItems: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in SystemMonitorStore.shared.openMetric = nil }
    }
}

/// Two-line menu-bar meter used in merged mode (macOS 27+ fallback): enabled
/// metrics are split across two short lines — the first ceil(n/2) values on
/// top, the rest below. Same visual language as the usage meter. The width is
/// fixed by the controller, so value changes never reflow the bar.
final class SysMonitorMeterView: NSView {
    var onClick: ((NSEvent) -> Void)?

    /// 合并项的字号/内边距：宽度按这套参数算死，数值跳动不会让菜单栏重排。
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let padding: CGFloat = 4

    private var top = ""
    private var bottom = ""
    private let font = SysMonitorMeterView.font
    private let pad = SysMonitorMeterView.padding

    func set(values: [String]) {
        let split = (values.count + 1) / 2
        let newTop = values.prefix(split).joined(separator: " ")
        let newBottom = values.suffix(from: split).joined(separator: " ")
        guard newTop != top || newBottom != bottom else { return }
        top = newTop
        bottom = newBottom
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let h = bounds.height
        let lineH: CGFloat = 9.5
        let yBottom = (h - lineH * 2) / 2
        if !bottom.isEmpty {
            NSAttributedString(string: bottom, attributes: attrs)
                .draw(at: NSPoint(x: pad, y: yBottom))
        }
        if !top.isEmpty {
            NSAttributedString(string: top, attributes: attrs)
                .draw(at: NSPoint(x: pad, y: yBottom + lineH))
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?(event) }
}
