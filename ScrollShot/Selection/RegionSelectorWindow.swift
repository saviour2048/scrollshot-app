import AppKit

/// The outcome of a region drag: which screen and the rect in global AppKit
/// coordinates (bottom-left origin, points).
struct RegionSelection {
    let screen: NSScreen
    let rectInScreen: CGRect
}

/// Drives a full-screen marquee selection across every connected display.
/// Call `begin` once; the completion fires with the selection or `nil` if the
/// user pressed Esc / made a too-small selection.
@MainActor
final class RegionSelectorController {
    private var windows: [RegionSelectorWindow] = []
    private var completion: ((RegionSelection?) -> Void)?
    private var previousActiveApp: NSRunningApplication?

    func begin(completion: @escaping (RegionSelection?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        windows = NSScreen.screens.map { screen in
            let window = RegionSelectorWindow(targetScreen: screen)
            window.onFinish = { [weak self] selection in self?.finish(selection) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            window.orderFrontRegardless()
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(_ selection: RegionSelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(selection)
    }
}

/// A borderless, transparent, top-most window covering a single screen.
final class RegionSelectorWindow: NSWindow {
    var onFinish: ((RegionSelection) -> Void)?
    var onCancel: (() -> Void)?

    private let targetScreen: NSScreen

    init(targetScreen: NSScreen) {
        self.targetScreen = targetScreen
        super.init(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(targetScreen.frame, display: true)

        let view = SelectionView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        view.onFinish = { [weak self] rectInWindow in
            guard let self else { return }
            let rectInScreen = self.convertToScreen(rectInWindow)
            self.onFinish?(RegionSelection(screen: self.targetScreen, rectInScreen: rectInScreen))
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dimmed overlay with a "punched-out" selection rectangle and
/// reports the dragged rect (in window coordinates) when the mouse is released.
private final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else {
            drawHint()
            return
        }

        // Punch a transparent hole so the live content shows through the selection.
        NSColor.clear.setFill()
        currentRect.fill(using: .copy)

        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        drawSizeLabel()
    }

    private func drawHint() {
        let text = "拖动选择截图区域 · Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.62)
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawSizeLabel() {
        let label = "\(Int(currentRect.width.rounded())) × \(Int(currentRect.height.rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        let padding: CGFloat = 6
        var origin = CGPoint(x: currentRect.minX, y: currentRect.maxY + padding)
        if origin.y + size.height > bounds.maxY {
            origin.y = currentRect.minY - size.height - padding
        }
        let backgroundRect = CGRect(
            x: origin.x - padding / 2,
            y: origin.y - padding / 2,
            width: size.width + padding,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard currentRect.width >= AppConfig.minimumSelectionSize,
              currentRect.height >= AppConfig.minimumSelectionSize else {
            onCancel?()
            return
        }
        onFinish?(currentRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
