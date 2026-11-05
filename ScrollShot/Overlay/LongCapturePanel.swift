import AppKit

/// A compact floating Liquid Glass card docked at the screen's bottom-left
/// during long capture: live preview, progress, an 自动滚动 button, and
/// 完成 / 取消. Borderless + translucent so the screen shows through (Tahoe feel).
/// Excluded from the capture so it never appears in the stitched image.
final class LongCapturePanel {
    var onAuto: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    let window: NSPanel

    private static let panelSize = NSSize(width: 240, height: 268)
    private static let cornerRadius: CGFloat = 18

    private let glass = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "向下慢慢滚动页面…")
    private let previewView = NSImageView()
    private let autoButton = NSButton()
    private let finishButton = NSButton()
    private let cancelButton = NSButton()

    init() {
        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true   // drag the glass to move it
        window.contentMinSize = Self.panelSize
        window.contentMaxSize = Self.panelSize
        buildUI()
    }

    var windowID: CGWindowID? {
        guard window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
    }

    func show(atBottomLeftOf screen: NSScreen) {
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        window.setFrameOrigin(CGPoint(x: visible.minX + margin, y: visible.minY + margin))
        window.orderFrontRegardless()
    }

    func update(height: Int, frames: Int, preview: NSImage?) {
        statusLabel.stringValue = "已拼接 \(height) px · \(frames) 帧"
        if let preview { previewView.image = preview }
    }

    func setAuto(_ on: Bool) {
        autoButton.isEnabled = !on
        autoButton.title = on ? "自动滚动中…" : "自动滚动"
    }

    func note(_ text: String) {
        statusLabel.stringValue = text
    }

    func close() {
        previewView.image = nil   // release the (potentially huge) stitched preview
        window.orderOut(nil)
    }

    private func buildUI() {
        // Liquid Glass background — blur what's behind the window (the screen).
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = LongCapturePanel.roundedMask(radius: Self.cornerRadius)
        window.contentView = glass

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignTop
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        previewView.layer?.cornerRadius = 8
        previewView.setContentHuggingPriority(.init(1), for: .horizontal)
        previewView.setContentHuggingPriority(.init(1), for: .vertical)
        previewView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        previewView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        autoButton.title = "自动滚动"
        autoButton.bezelStyle = .rounded
        autoButton.controlSize = .large
        autoButton.target = self
        autoButton.action = #selector(autoTapped)

        finishButton.title = "完成"
        finishButton.bezelStyle = .rounded
        finishButton.controlSize = .large
        finishButton.bezelColor = .controlAccentColor
        finishButton.keyEquivalent = "\r"
        finishButton.target = self
        finishButton.action = #selector(finishTapped)

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let actionRow = NSStackView(views: [cancelButton, finishButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        let stack = NSStackView(views: [statusLabel, previewView, autoButton, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            previewView.heightAnchor.constraint(equalToConstant: 92),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            previewView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            autoButton.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
    }

    /// A stretchable rounded-rect mask for the Liquid Glass corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let length = radius * 2 + 1
        let image = NSImage(size: NSSize(width: length, height: length), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    @objc private func autoTapped() { onAuto?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
