import AppKit

/// 内存压力迷你面积图(仿活动监视器 Memory Pressure): 底部基线 + 填充区域,
/// 线高表示压力(0–100%),按当前压力等级变色(绿/黄/红)。固定 36pt 宽,
/// 只在帧内容变化时重绘,避免触发菜单栏重排。
final class MemoryPressureGraphView: NSView {
    static let width: CGFloat = 36

    /// 压力样本(0–100,旧→新),由 SystemMonitorStore 的环形缓冲提供。
    private var history: [Int] = []

    func set(history: [Int]) {
        guard history != self.history else { return }
        self.history = history
        needsDisplay = true
    }

    /// 当前压力等级颜色: level = 100 - 压力(内存可用百分比)。
    /// 菜单栏底色深浅不一,黄色用琥珀色自定义值——systemYellow 在浅色菜单栏上太淡。
    private var levelColor: NSColor {
        let level = 100 - (history.last ?? 0)
        if level > 40 { return .systemGreen }
        if level > 20 { return NSColor(srgbRed: 1.0, green: 0.60, blue: 0.02, alpha: 1.0) }
        return .systemRed
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let inset: CGFloat = 2
        let plotH = max(bounds.height - inset * 2, 1)

        // 底部基线
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 0, y: inset + 0.5))
        base.line(to: NSPoint(x: w, y: inset + 0.5))
        base.lineWidth = 1
        base.stroke()

        guard history.count >= 2 else { return }
        // 按满窗口容量定步长,样本不足时右对齐(最新样本贴右缘)。
        let step = w / CGFloat(SystemMonitorStore.memPressureHistoryCapacity - 1)
        let startX = w - step * CGFloat(history.count - 1)

        let area = NSBezierPath()
        let line = NSBezierPath()
        for (i, p) in history.enumerated() {
            let x = startX + step * CGFloat(i)
            let y = inset + plotH * CGFloat(min(max(p, 0), 100)) / 100
            if i == 0 {
                area.move(to: NSPoint(x: x, y: inset))
                area.line(to: NSPoint(x: x, y: y))
                line.move(to: NSPoint(x: x, y: y))
            } else {
                area.line(to: NSPoint(x: x, y: y))
                line.line(to: NSPoint(x: x, y: y))
            }
        }
        area.line(to: NSPoint(x: startX + step * CGFloat(history.count - 1), y: inset))
        area.close()

        levelColor.withAlphaComponent(0.8).setFill()
        area.fill()
        levelColor.setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }
}
