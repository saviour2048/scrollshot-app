import AppKit

/// The floating toolbar shown next to a selection: drawing tools + color +
/// stroke width + undo, then the save / copy / cancel actions.
final class AnnotationBar: NSView {
    var onSelectTool: ((AnnotationTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLongCapture: (() -> Void)?

    private static let orderedTools: [AnnotationTool] = [.arrow, .rectangle, .ellipse, .pen, .counter, .text, .mosaic]
    private static let widthValues: [CGFloat] = [2, 4, 7]
    private static let widthLabels = ["细", "中", "粗"]
    /// Flameshot/QQ截图-style preset swatches. A system NSColorWell/NSColorPanel
    /// can't work in the capture overlay: the overlay runs a modal session at
    /// CGShieldingWindowLevel, so the color panel can't open/operate. Plain
    /// buttons are the only controls proven to work there (and in the editor).
    private static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    private let showsLongCapture: Bool
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var widthButtons: [NSButton] = []
    private var selectedColorIndex = 0
    private var selectedWidthIndex = 1
    private let stack = NSStackView()
    /// Liquid Glass background (renders as Liquid Glass on macOS Tahoe, vibrancy
    /// on earlier systems). Lets the screenshot show through the toolbar.
    private let glass = NSVisualEffectView()

    init(showsLongCapture: Bool = true) {
        self.showsLongCapture = showsLongCapture
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18                                             // capsule-like (Apple Music feel)
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor  // glass highlight edge
        // Standard controls render in dark mode for contrast on the glass.
        appearance = NSAppearance(named: .darkAqua)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var currentColor: NSColor { Self.presetColors[selectedColorIndex] }
    var currentWidth: CGFloat { Self.widthValues[selectedWidthIndex] }

    /// The natural size of the toolbar content. Computed from the stack itself
    /// (not tied to this view's frame) so it is never collapsed to zero. A small
    /// slack avoids sub-pixel "conflicting constraints" logs when the stack is
    /// framed to exactly its fitting size.
    var contentSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        return NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + 2)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        // Center the stack within the (slightly larger) bar so the extra slack
        // is split evenly and never squeezes the arranged controls.
        stack.frame = bounds
    }

    private func buildUI() {
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        addSubview(glass)

        var views: [NSView] = []

        for (index, tool) in Self.orderedTools.enumerated() {
            let button = tool == .text
                ? labeledToolButton(title: "文字", tag: index)
                : toolButton(symbol: symbol(for: tool), tip: tip(for: tool), tag: index)
            toolButtons[tool] = button
            views.append(button)
        }

        views.append(separator())

        for (index, color) in Self.presetColors.enumerated() {
            let swatch = colorSwatch(color: color, tag: 100 + index)
            colorButtons.append(swatch)
            views.append(swatch)
        }
        updateColorSelection()

        for (index, label) in Self.widthLabels.enumerated() {
            let button = widthButton(title: label, tag: 200 + index)
            widthButtons.append(button)
            views.append(button)
        }
        updateWidthSelection()

        views.append(actionButton(title: "撤销", action: #selector(undoTapped)))
        views.append(separator())
        if showsLongCapture {
            let longButton = actionButton(title: "长截图", action: #selector(longCaptureTapped))
            longButton.bezelColor = .systemTeal
            views.append(longButton)
        }
        let saveButton = actionButton(title: "保存", action: #selector(saveTapped))
        saveButton.bezelColor = .controlAccentColor   // make the primary action stand out
        views.append(saveButton)
        views.append(actionButton(title: "复制", action: #selector(copyTapped)))
        views.append(actionButton(title: "取消", action: #selector(cancelTapped)))

        views.forEach { stack.addArrangedSubview($0) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        // The stack is sized via manual frame (= bounds, which is >= its content
        // thanks to the slack in `contentSize`), so it must NOT also pin its size
        // with .required content priorities — that fights the autoresizing frame
        // constraint and spams "conflicting constraints".
        addSubview(stack)
    }

    func setActiveTool(_ tool: AnnotationTool?) {
        for (candidate, button) in toolButtons {
            let color: NSColor = (candidate == tool) ? .controlAccentColor : .white
            button.contentTintColor = color
            if !button.title.isEmpty { applyTitleColor(color, to: button) }
        }
    }

    private func applyTitleColor(_ color: NSColor, to button: NSButton) {
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )
    }

    // MARK: Builders

    private func toolButton(symbol: String, tip: String, tag: Int) -> NSButton {
        let button = NSButton()
        button.title = ""                       // no default "按钮" title
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.contentTintColor = .white
        button.toolTip = tip
        button.tag = tag
        button.target = self
        button.action = #selector(toolTapped(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    /// A tool button that shows a text label (e.g. 「文字」) instead of an icon.
    private func labeledToolButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(toolTapped(_:)))
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .white
        button.tag = tag
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        applyTitleColor(.white, to: button)   // visible on the dark toolbar
        return button
    }

    private func actionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A circular color swatch (plain NSButton — works in the modal overlay,
    /// unlike NSColorWell which needs to open the system color panel).
    private func colorSwatch(color: NSColor, tag: Int) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.backgroundColor = color.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        button.toolTip = "颜色"
        button.tag = tag
        button.target = self
        button.action = #selector(colorTapped(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    /// 细/中/粗 as plain buttons (NSSegmentedControl's SwiftUI-backed
    /// implementation is unreliable in the modal nonactivating overlay).
    private func widthButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(widthTapped(_:)))
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.tag = tag
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func updateColorSelection() {
        for (index, button) in colorButtons.enumerated() {
            let selected = index == selectedColorIndex
            button.layer?.borderWidth = selected ? 2.5 : 1
            button.layer?.borderColor = selected
                ? NSColor.white.cgColor
                : NSColor.white.withAlphaComponent(0.35).cgColor
        }
    }

    private func updateWidthSelection() {
        for (index, button) in widthButtons.enumerated() {
            applyTitleColor(index == selectedWidthIndex ? .controlAccentColor : .white, to: button)
        }
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }

    private func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .counter: return "1.circle"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }

    private func tip(for tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .counter: return "序号"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    // MARK: Actions

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = Self.orderedTools[sender.tag]
        setActiveTool(tool)
        onSelectTool?(tool)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        selectedColorIndex = sender.tag - 100
        updateColorSelection()
        onColor?(currentColor)
    }

    @objc private func widthTapped(_ sender: NSButton) {
        selectedWidthIndex = sender.tag - 200
        updateWidthSelection()
        onWidth?(Self.widthValues[selectedWidthIndex])
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func longCaptureTapped() { onLongCapture?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func cancelTapped() { onCancel?() }
}
