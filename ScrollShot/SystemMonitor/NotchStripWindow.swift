import AppKit

/// 菜单栏挤爆时，把监控数值画在**刘海旁边那块空着的菜单栏**上。
///
/// 为什么不继续用状态项：实测（2026-10-28）内建屏右侧状态区只有 645.5pt，系统把
/// 我们的项折进 « 之后，即使腾出 120pt 空档也不会再把它摆出来——折叠是"贴右边缘
/// 从右往左排"，新加的项永远在最左边，第一个被吃掉。所以这里绕开状态项：直接在
/// 菜单栏那条空白上画一个透明的小窗（刘海左边那块系统从不使用）。
///
/// 只做三件事：贴刘海左边 → 画数值 → 点一下弹监控详情。窗口很小、点不到就穿透，
/// 不影响下面的菜单栏点击。
@MainActor
final class NotchStripWindow {
    private var window: NSWindow?
    private var view: StripView?
    private var currentText = ""
    private(set) var screen: NSScreen?

    /// 弹 popover 用：拿小窗里的视图当锚点。
    func anchorView() -> NSView? { view }

    /// 只在「有刘海的屏 + 当前处于合并态」时显示。
    func show(on screen: NSScreen, text: String) {
        self.screen = screen
        let size = StripView.size(for: text)
        // 几何交给可单测的 MenuBarNotchGeometry：刘海左沿取 auxiliaryTopLeftArea.maxX。
        // 0.8.74~0.8.83 曾误用 auxiliaryTopRightArea.minX（刘海右沿），小条被画到
        // 刘海底下：屏幕上看被切掉、截图里却完整（见 HANDOFF_2026-11-05_MENUBAR_NOTCH.md）。
        let geometry = MenuBarNotchGeometry(leftArea: screen.auxiliaryTopLeftArea,
                                            rightArea: screen.auxiliaryTopRightArea)
        guard let stripRect = geometry.stripFrame(width: size.width, height: size.height) else {
            hide()
            return
        }
        let barHeight = NSStatusBar.system.thickness
        let origin = NSPoint(x: stripRect.minX,
                             y: screen.frame.maxY - barHeight + (barHeight - size.height) / 2)
        let frame = NSRect(origin: origin, size: size)

        if let window, let view {
            window.setFrame(frame, display: false)
            if currentText != text { currentText = text; view.text = text; view.needsDisplay = true }
            if !window.isVisible { window.orderFrontRegardless() }
            return
        }

        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // 只做展示：点击完全穿透，绝不挡菜单栏/桌面上的任何操作。
        w.ignoresMouseEvents = true
        // 必须压过菜单栏那一层（MenuBarAgent 的窗口在 25 左右），否则画面上能看见、
        // 但点击会被菜单栏吃掉。
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = StripView(frame: NSRect(origin: .zero, size: frame.size))
        v.text = text
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        view = v
        currentText = text
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
        currentText = ""
    }
}

private final class StripView: NSView {
    var text = ""

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let padH: CGFloat = 8
    private static let height: CGFloat = 20

    static func size(for text: String) -> NSSize {
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width) + padH * 2
        return NSSize(width: max(w, 24), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 0.1, alpha: 0.72).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

}
