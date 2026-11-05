import AppKit
import SwiftUI

/// Dashboard popover 的可见性,用来驱动 UsageDashboardView 的 1s 定时器
/// connect/cancel:popover 关闭后其 contentViewController 仍被永久持有,
/// 不停掉的话定时器会永远空转(每秒重渲染不可见界面)。
@MainActor
final class UsageDashboardVisibility: ObservableObject {
    static let shared = UsageDashboardVisibility()
    @Published var isPopoverVisible = false
    private init() {}
}

/// A dedicated menu-bar status item that shows live Claude usage (CodexBar-style):
/// an icon plus a configurable live metric (session % / weekly % / today $),
/// clicking it opens the full dashboard popover.
@MainActor
final class UsageStatusItemController: NSObject {
    static let shared = UsageStatusItemController()

    private var statusItem: NSStatusItem?
    private var meterView: UsageMeterView?
    private let popover = NSPopover()

    // RunCat-style animation state: the cat's stride phase advances on a fixed
    // 4Hz timer; speed follows whole-machine CPU usage (like RunCat).
    private var animTimer: Timer?
    private var catPhase: Double = 0
    private var catSpeed: Double = 0.8   // strides per second
    private var animTick = 0
    private let cpuSampler = CPUSampler()

    private override init() { super.init() }

    /// Creates the status item and starts polling (no-op if disabled in settings).
    func start() {
        guard UsageMonitorSettings.enabled, statusItem == nil else { return }
        Self.migrateToTwoLineIfNeeded()
        UsageMonitorSettings.migrateToSlotsIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let view = UsageMeterView(frame: NSRect(x: 0, y: 0, width: 34, height: NSStatusBar.system.thickness))
        view.autoresizingMask = [.width, .height]
        view.onClick = { [weak self] event in self?.handleMeterClick(event) }
        item.button?.image = nil
        item.button?.title = ""
        item.button?.addSubview(view)
        meterView = view
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 460)
        popover.contentViewController = NSHostingController(rootView: UsageDashboardView())

        UsageStore.shared.onUpdate = { [weak self] snap in self?.render(snap) }
        UsageStore.shared.start()
        render(UsageStore.shared.snapshot)
        startAnimation()
    }

    /// Removes the status item and stops polling.
    func stop() {
        animTimer?.invalidate()
        animTimer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        UsageStore.shared.onUpdate = nil
        UsageStore.shared.stop()
    }

    // MARK: Cat animation

    private func startAnimation() {
        animTimer?.invalidate()
        // 4Hz(0.25s):相比 10Hz 肉眼几乎无差,但常驻 CPU 底噪明显更低
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAnimation() }
        }
        timer.tolerance = 0.05   // 允许系统合并定时器唤醒,进一步省电
        animTimer = timer
    }

    /// Advance the stride phase; redraw only when the visible frame changes, so
    /// a slow stroll doesn't repaint on every tick for nothing. Every 2s, resample
    /// CPU and retarget the speed (idle → lazy jog, busy → sprint), like RunCat.
    /// 状态项不可见时整个 tick(含 CPU 采样)直接跳过。
    private func tickAnimation() {
        guard let view = meterView, isStatusItemVisible else { return }
        animTick += 1
        if animTick % 8 == 0 {   // 2s cadence at the 0.25s tick
            let cpu = cpuSampler.usagePercent()
            catSpeed = 0.7 + 3.3 * (cpu / 100)
        }
        let frames = Double(RunningCat.frameCount)
        let oldFrame = Int(catPhase * frames)
        catPhase += 0.25 * catSpeed
        if catPhase >= 1 { catPhase -= 1 }
        let newFrame = Int(catPhase * frames) % RunningCat.frameCount
        if newFrame != oldFrame {
            view.frameIndex = newFrame
            view.needsDisplay = true
        }
    }

    /// False when the menu-bar item can't be seen — hidden by a bar manager
    /// (Ice / Hidden Bar), or its window is occluded (display asleep, screen
    /// locked). Animating then just burns CPU and makes WindowServer composite
    /// something nobody can see.
    private var isStatusItemVisible: Bool {
        if #available(macOS 14.0, *) {
            if statusItem?.isVisible == false { return false }
        }
        if let window = statusItem?.button?.window,
           !window.occlusionState.contains(.visible) { return false }
        return true
    }

    /// Re-applies settings (enabled toggle, metric, cadence).
    func reload() {
        if UsageMonitorSettings.enabled {
            if statusItem == nil {
                start()
            } else {
                UsageStore.shared.scheduleTimer()
                render(UsageStore.shared.snapshot)
            }
        } else {
            stop()
        }
    }

    /// Left-click opens the dashboard; right-click (or ⌃-click) shows the main
    /// menu, so Settings / Quit stay reachable even when the camera icon is hidden.
    private func handleMeterClick(_ event: NSEvent) {
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            let menu = MainMenuBarController.shared.makeMainMenu()
            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            }
        } else {
            togglePopover(nil)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            UsageStore.shared.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func render(_ snap: UsageSnapshot) {
        guard let view = meterView else { return }
        var data = meterData(snap)
        data.showCat = UsageMonitorSettings.showCatIcon
        view.set(data: data)
        statusItem?.button?.toolTip = data.toolTip
        layoutMeter()
    }

    /// The 1–2 lines to show for the current metric, composed from the two
    /// configurable columns (左/右 slot)。右列选「无」时退回单列竖排。
    private func meterData(_ snap: UsageSnapshot) -> MeterData {
        let metric = UsageMonitorSettings.menuBarMetric
        var leftSlot = UsageMonitorSettings.menuBarLeft
        var rightSlot = UsageMonitorSettings.menuBarRight
        // 左列选「无」时把右列提上来当单列,避免留一个空左列
        if leftSlot == .none { leftSlot = rightSlot; rightSlot = .none }

        // 占位语义沿用旧行为:双列缺数据填 "—";单列的 session/weekly/todayCost
        // 缺失时留空(只显示猫),sessionWeekly 两行始终有 "—" 占位。
        let placeholder = rightSlot == .none ? "" : "—"
        let left = UsageMeterMapping.column(leftSlot, metric: metric, snap: snap, placeholder: placeholder)
        guard rightSlot != .none else {
            // 单列且整列无内容时(只显示猫)不预留宽度,保持旧的收缩行为。
            let leftEmpty = left.top.isEmpty && left.bottom.isEmpty
            return MeterData(layout: .vertical,
                             leftTop: left.top, leftBottom: left.bottom,
                             rightTop: "", rightBottom: "",
                             toolTip: UsageMeterMapping.toolTip(left: leftSlot, right: nil, metric: metric),
                             leftTemplate: leftEmpty ? nil : UsageMeterMapping.template(for: leftSlot, metric: metric))
        }
        let right = UsageMeterMapping.column(rightSlot, metric: metric, snap: snap, placeholder: placeholder)
        return MeterData(layout: .horizontal,
                         leftTop: left.top, leftBottom: left.bottom,
                         rightTop: right.top, rightBottom: right.bottom,
                         toolTip: UsageMeterMapping.toolTip(left: leftSlot, right: rightSlot, metric: metric),
                         leftTemplate: UsageMeterMapping.template(for: leftSlot, metric: metric),
                         rightTemplate: UsageMeterMapping.template(for: rightSlot, metric: metric))
    }

    /// Size the status item to the meter view's content.
    private func layoutMeter() {
        guard let view = meterView, let item = statusItem else { return }
        let w = view.fittingWidth
        item.length = w
        view.frame = NSRect(x: 0, y: 0, width: w, height: NSStatusBar.system.thickness)
    }

    /// One-time: move existing single-line users onto the new two-line meter the
    /// user asked for. Leaves a deliberate icon-only / cost choice untouched.
    private static func migrateToTwoLineIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "usage.migratedTwoLine") else { return }
        d.set(true, forKey: "usage.migratedTwoLine")
        let current = UsageMonitorSettings.menuBarMetric
        if current == .session || current == .weekly {
            UsageMonitorSettings.menuBarMetric = .sessionWeekly
        }
    }

}

extension UsageStatusItemController: NSPopoverDelegate {
    // 把 popover 可见性同步给 dashboard,控制它 1s 定时器的 connect/cancel
    nonisolated func popoverWillShow(_ notification: Notification) {
        Task { @MainActor in UsageDashboardVisibility.shared.isPopoverVisible = true }
    }
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in UsageDashboardVisibility.shared.isPopoverVisible = false }
    }
}

/// 菜单栏用量表的「slot × 指标 → 显示文本」纯映射,拆成静态函数便于单测。
enum UsageMeterMapping {
    /// 每个来源的(短周期, 周)窗口,统一成 UsageWindow:
    /// Claude = session/周,Kimi = 频限/周,Codex = 5小时(primary)/7天(secondary),
    /// OpenCode = 5小时滚动(rolling)/周。DeepSeek 没有限流窗口(显示余额/消耗,
    /// 在 column 里提前分流),永远返回 (nil, nil)。
    static func windows(for slot: MenuBarSlot, snap: UsageSnapshot) -> (short: UsageWindow?, long: UsageWindow?)? {
        switch slot {
        case .none: return nil
        case .claude: return (snap.limits?.session, snap.limits?.weekly)
        case .deepseek: return (nil, nil)
        case .kimi:
            return (snap.kimi?.rate.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) },
                    snap.kimi?.weekly.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) })
        case .codex:
            return (snap.codex?.primary.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) },
                    snap.codex?.secondary.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) })
        case .opencode:
            return (snap.opencode?.rolling.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) },
                    snap.opencode?.weekly.map { UsageWindow(utilization: $0.usedPercent, resetsAt: $0.resetAt) })
        }
    }

    /// 一列的(上行, 下行)文本。placeholder:session/weekly/todayCost 数据未到时的
    /// 占位(单列传 "" 沿用旧行为,双列传 "—");sessionWeekly 两行始终用 "—" 占位。
    static func column(_ slot: MenuBarSlot, metric: MenuBarMetric, snap: UsageSnapshot,
                       placeholder: String = "—") -> (top: String, bottom: String) {
        if slot == .deepseek { return deepseekColumn(metric: metric, snap: snap, placeholder: placeholder) }
        guard let w = windows(for: slot, snap: snap) else { return ("", "") }
        func pct(_ win: UsageWindow?, _ ph: String) -> String {
            win.map { UsageFormat.percent($0.remainingPercent) } ?? ph
        }
        switch metric {
        case .sessionWeekly: return (pct(w.short, "—"), pct(w.long, "—"))
        case .session:       return (pct(w.short, placeholder), "")
        case .weekly:        return (pct(w.long, placeholder), "")
        case .todayCost:
            // 只有 Claude 有本地花费估算;Kimi/Codex 固定 "—"
            if slot == .claude { return (snap.cost.map { UsageFormat.dollars($0.todayCost) } ?? placeholder, "") }
            return ("—", "")
        case .iconOnly:      return ("", "")
        }
    }

    /// DeepSeek 列:余额(pipeline E,AI 对话 key)与今日消耗(pipeline F,
    /// consoleToken)是两个独立来源,各自缺数据时独立占位。
    private static func deepseekColumn(metric: MenuBarMetric, snap: UsageSnapshot,
                                       placeholder: String) -> (top: String, bottom: String) {
        func symbol(_ currency: String) -> String { currency == "USD" ? "$" : "¥" }
        let bal = snap.deepseek?.balances.first(where: { $0.currency == "CNY" })
            ?? snap.deepseek?.balances.first
        let balText = bal.flatMap { Double($0.total) }
            .map { UsageFormat.compactMoney($0, symbol: symbol(bal!.currency), maxChars: 7) }
        let todayText = snap.deepseekUsage.map {
            "-" + UsageFormat.compactMoney($0.todayCost, symbol: symbol($0.currency), maxChars: 6)
        }
        switch metric {
        case .sessionWeekly: return (balText ?? "—", todayText ?? "—")
        case .session, .weekly: return (balText ?? placeholder, "")
        case .todayCost: return (todayText ?? placeholder, "")
        case .iconOnly: return ("", "")
        }
    }

    /// 该列宽度的"最宽样本串",只用于宽度计算——状态项宽度由模板决定而非
    /// 实时数值,数字从 93% 跳到 100% 时图标不再抖动/挤占邻居。
    /// 返回 nil = 该列不占宽(none / iconOnly)。
    static func template(for slot: MenuBarSlot, metric: MenuBarMetric) -> String? {
        guard slot != .none, metric != .iconOnly else { return nil }
        if slot == .deepseek {
            switch metric {
            case .sessionWeekly: return "¥000.00\n-¥00.00"
            case .todayCost:     return "-¥00.00"
            case .session, .weekly: return "¥000.00"
            case .iconOnly:      return nil
            }
        }
        switch metric {
        case .sessionWeekly: return "100%\n100%"
        case .session, .weekly: return "100%"
        case .todayCost: return "$000.00"
        case .iconOnly: return nil
        }
    }

    /// 状态栏 tooltip;right 为 nil 表示单列竖排。
    static func toolTip(left: MenuBarSlot, right: MenuBarSlot?, metric: MenuBarMetric) -> String? {
        // 各来源短周期窗口的名字
        func shortName(_ slot: MenuBarSlot) -> String {
            switch slot {
            case .claude: return "本次周期"
            case .kimi:   return "Kimi 短周期"
            case .codex:  return "Codex 5小时"
            case .deepseek: return "余额"
            case .opencode: return "5小时"
            case .none:   return ""
            }
        }
        // sessionWeekly 双行布局下每列的完整描述
        func twoLineDesc(_ slot: MenuBarSlot) -> String {
            slot == .deepseek ? "DeepSeek 余额/今日消耗"
                              : "\(slot.label) \(shortName(slot))/本周"
        }
        switch metric {
        case .sessionWeekly:
            if let right {
                return "左:\(twoLineDesc(left)) · 右:\(twoLineDesc(right))"
            }
            return left == .none ? nil
                 : left == .deepseek ? "上:DeepSeek 余额 · 下:今日消耗"
                 : "上:\(shortName(left))剩余 · 下:本周剩余"
        case .session:
            guard let right else { return nil }
            return "左:\(left.label) \(shortName(left))剩余 · 右:\(right.label) \(shortName(right))剩余"
        case .weekly:
            guard let right else { return nil }
            return "左:\(left.label) 本周剩余 · 右:\(right.label) 本周剩余"
        case .todayCost, .iconOnly:
            return nil
        }
    }
}

/// Layout mode for the meter: vertical stack (single source) or horizontal
/// side-by-side blocks (Claude + Kimi together).
private enum MeterLayout { case vertical, horizontal }

/// Renderable description of the current menu-bar meter.
///
/// leftTemplate/rightTemplate 是列的"最宽样本串",只用于宽度计算:
/// 状态项宽度由模板决定而非实时数值,数字从 93% 跳到 100% 时图标不再抖动/
/// 挤占邻居(与 SystemMonitor 状态项固定宽度同一修法)。
private struct MeterData: Equatable {
    let layout: MeterLayout
    let leftTop: String
    let leftBottom: String
    let rightTop: String
    let rightBottom: String
    let toolTip: String?
    var showCat: Bool = true
    var leftTemplate: String? = nil
    var rightTemplate: String? = nil
}

/// Draws the menu-bar usage meter: the running coral cat on the left (RunCat-
/// style, animated by `catPhase`), then either a stacked two-line column or two
/// columns side-by-side for Claude + Kimi. Text uses `labelColor`, so it adapts
/// to the menu bar's light/dark appearance.
private final class UsageMeterView: NSView {
    var onClick: ((NSEvent) -> Void)?
    /// Current stride frame, advanced by the controller's animation timer.
    var frameIndex = 0

    private let frames: [NSImage]
    private var data = MeterData(layout: .vertical, leftTop: "", leftBottom: "",
                                  rightTop: "", rightBottom: "", toolTip: nil,
                                  showCat: true)
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private let catW: CGFloat = 18    // 126:77 frame aspect at 11pt tall（比原来小 1/4，给菜单栏腾地方）
    private let catH: CGFloat = 11
    private let gap: CGFloat = 3
    private let pad: CGFloat = 4
    private let colGap: CGFloat = 6

    override init(frame frameRect: NSRect) {
        // Vivid orange — the deeper coral sank into dark menu bars (user-picked
        // from a 3-way comparison on a dark background).
        frames = RunningCat.loadFrames(tint: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.25, alpha: 1))
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func set(data: MeterData) {
        guard data != self.data else { return }
        self.data = data
        needsDisplay = true
    }

    /// Text-measurement cache. The meter shows a tiny set of short labels
    /// (percentages / dollar amounts), so memoizing by string keeps CoreText
    /// layout off the per-frame path. Measurement only depends on the text and
    /// the font (a fixed instance); color/paragraph attributes don't affect it.
    private var textSizeCache: [String: NSSize] = [:]

    private func measure(_ text: String) -> NSSize {
        if let s = textSizeCache[text] { return s }
        if textSizeCache.count > 200 { textSizeCache.removeAll() }
        let s = NSAttributedString(string: text, attributes: textAttributes()).size()
        let cached = NSSize(width: ceil(s.width), height: ceil(s.height))
        textSizeCache[text] = cached
        return cached
    }

    var fittingWidth: CGFloat {
        let leftW = columnWidth(top: data.leftTop, bottom: data.leftBottom, template: data.leftTemplate)
        let rightW = columnWidth(top: data.rightTop, bottom: data.rightBottom, template: data.rightTemplate)
        var textW: CGFloat = 0
        switch data.layout {
        case .vertical:
            textW = leftW
        case .horizontal:
            textW = (leftW > 0 ? leftW : 0) + (rightW > 0 ? rightW : 0)
            if leftW > 0 && rightW > 0 { textW += colGap }
        }
        let hasText = data.leftTop.isEmpty == false || data.leftBottom.isEmpty == false
                     || data.rightTop.isEmpty == false || data.rightBottom.isEmpty == false
        var contentW: CGFloat = 0
        if data.showCat { contentW += catW }
        if data.showCat && hasText { contentW += gap }
        if hasText { contentW += textW }
        if contentW == 0 { contentW = catW } // never collapse to zero
        return ceil(pad + contentW + pad)
    }

    private func columnWidth(top: String, bottom: String, template: String? = nil) -> CGFloat {
        // 有模板时按模板量:列宽恒定,数值变化不再改变状态项宽度。
        if let template { return measure(template).width }
        guard !top.isEmpty || !bottom.isEmpty else { return 0 }
        let t = bottom.isEmpty ? top : "\(top)\n\(bottom)"
        return measure(t).width
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        var x = pad
        if data.showCat, !frames.isEmpty {
            frames[frameIndex % frames.count]
                .draw(in: NSRect(x: x, y: (h - catH) / 2, width: catW, height: catH))
        }
        if data.showCat { x += catW + gap }

        let attrs = textAttributes()
        switch data.layout {
        case .vertical:
            let leftW = columnWidth(top: data.leftTop, bottom: data.leftBottom, template: data.leftTemplate)
            drawColumn(top: data.leftTop, bottom: data.leftBottom, x: x,
                       width: leftW, alignRight: false, attrs: attrs)
        case .horizontal:
            let leftW = columnWidth(top: data.leftTop, bottom: data.leftBottom, template: data.leftTemplate)
            let rightW = columnWidth(top: data.rightTop, bottom: data.rightBottom, template: data.rightTemplate)
            drawColumn(top: data.leftTop, bottom: data.leftBottom, x: x,
                       width: leftW, alignRight: false, attrs: attrs)
            if leftW > 0 && rightW > 0 {
                // 右列在保留宽度内右对齐:短数值也贴右边,列间距恒定。
                drawColumn(top: data.rightTop, bottom: data.rightBottom, x: x + leftW + colGap,
                           width: rightW, alignRight: true, attrs: attrs)
            } else if rightW > 0 {
                drawColumn(top: data.rightTop, bottom: data.rightBottom, x: x,
                           width: rightW, alignRight: true, attrs: attrs)
            }
        }
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.maximumLineHeight = 9.5
        para.minimumLineHeight = 9.5
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
    }

    private func drawColumn(top: String, bottom: String, x: CGFloat, width: CGFloat,
                            alignRight: Bool, attrs: [NSAttributedString.Key: Any]) {
        guard !top.isEmpty || !bottom.isEmpty else { return }
        let text = bottom.isEmpty ? top : "\(top)\n\(bottom)"
        let sz = measure(text)
        let h = bounds.height
        let dx = alignRight ? max(0, width - sz.width - 2) : 0
        let rect = NSRect(x: x + dx, y: (h - sz.height) / 2, width: sz.width + 2, height: sz.height)
        textImage(text, size: NSSize(width: sz.width + 2, height: sz.height), attrs: attrs).draw(in: rect)
    }

    /// Rendered-text cache. The cat animation repaints the meter several times
    /// per second, and re-typesetting the (almost never changing) labels on
    /// every frame was the top cost in sampling. Keyed by text + appearance;
    /// drawing a cached image is a plain blit.
    private var textImageCache: [String: NSImage] = [:]

    private func textImage(_ text: String, size: NSSize, attrs: [NSAttributedString.Key: Any]) -> NSImage {
        let key = effectiveAppearance.name.rawValue + "|" + text
        if let img = textImageCache[key] { return img }
        if textImageCache.count > 64 { textImageCache.removeAll() }
        let img = NSImage(size: size, flipped: false) { rect in
            NSAttributedString(string: text, attributes: attrs).draw(in: rect)
            return true
        }
        textImageCache[key] = img
        return img
    }

    override func mouseDown(with event: NSEvent) { onClick?(event) }
    override func rightMouseDown(with event: NSEvent) { onClick?(event) }
}
