import AppKit

/// A PowerPoint-style editable text box: multi-line wrapping text, a dashed
/// border, four corner handles for resizing, and body-drag to move. Enter
/// inserts a newline; Esc (or clicking outside, driven by the canvas) commits.
final class TextBoxEditor: NSView, NSTextViewDelegate {
    /// Called with the text-area rect (in superview/canvas coordinates), the
    /// string, font size and color when editing finishes with non-empty text.
    var onCommit: ((_ rect: CGRect, _ string: String, _ fontSize: CGFloat, _ color: NSColor) -> Void)?
    /// Called after the editor removes itself (committed or empty).
    var onFinished: (() -> Void)?

    private let textView = NSTextView()
    private let inset: CGFloat = 10
    private let handleHit: CGFloat = 18
    private let minSize = NSSize(width: 60, height: 28)

    private var color: NSColor
    private var fontSize: CGFloat

    private enum DragMode { case none, move, resize(Int) }
    private var dragMode: DragMode = .none
    private var dragStartInSuper: CGPoint = .zero
    private var startFrame: CGRect = .zero

    init(frame: CGRect, fontSize: CGFloat, color: NSColor) {
        self.color = color
        self.fontSize = fontSize
        super.init(frame: frame)
        wantsLayer = true
        setupTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func setupTextView() {
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = color
        textView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        textView.delegate = self
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.frame = bounds.insetBy(dx: inset, dy: inset)
        addSubview(textView)
    }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    // MARK: External controls

    func focus() { window?.makeFirstResponder(textView) }

    func setColor(_ newColor: NSColor) {
        color = newColor
        textView.textColor = newColor
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        textView.font = .systemFont(ofSize: size, weight: .semibold)
    }

    var isEmpty: Bool {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Finishes editing: emits an annotation if non-empty, then removes itself.
    func commit() {
        let rect = convert(textView.frame, to: superview)
        let string = textView.string
        let size = fontSize
        let textColor = color
        removeFromSuperview()
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCommit?(rect, string, size, textColor)
        }
        onFinished?()
    }

    // MARK: Drawing (border + handles)

    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        for center in handleCenters() {
            let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 11, height: 11)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private func handleCenters() -> [CGPoint] {
        [CGPoint(x: bounds.minX + 2, y: bounds.minY + 2),   // 0 top-left
         CGPoint(x: bounds.maxX - 2, y: bounds.minY + 2),   // 1 top-right
         CGPoint(x: bounds.minX + 2, y: bounds.maxY - 2),   // 2 bottom-left
         CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2)]   // 3 bottom-right
    }

    private func handle(at point: CGPoint) -> Int? {
        for (index, center) in handleCenters().enumerated() {
            if abs(point.x - center.x) <= handleHit && abs(point.y - center.y) <= handleHit {
                return index
            }
        }
        return nil
    }

    // Route clicks: handles/border → self (move/resize); inner → text view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if handle(at: local) != nil { return self }
        let inner = bounds.insetBy(dx: inset, dy: inset)
        if bounds.contains(local), !inner.contains(local) { return self }
        return super.hitTest(point)
    }

    // MARK: Move / resize

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        startFrame = frame
        dragStartInSuper = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        if let index = handle(at: local) {
            dragMode = .resize(index)
        } else {
            dragMode = .move
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let now = superview.convert(event.locationInWindow, from: nil)
        let dx = now.x - dragStartInSuper.x
        let dy = now.y - dragStartInSuper.y

        switch dragMode {
        case .move:
            frame = startFrame.offsetBy(dx: dx, dy: dy)
        case let .resize(corner):
            frame = resizedFrame(corner: corner, dx: dx, dy: dy)
        case .none:
            break
        }
        needsLayout = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        focus()
    }

    private func resizedFrame(corner: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        var x = startFrame.minX, y = startFrame.minY
        var w = startFrame.width, h = startFrame.height
        let maxX = startFrame.maxX, maxY = startFrame.maxY

        switch corner {
        case 0: // top-left: left + top edges move
            x = min(maxX - minSize.width, startFrame.minX + dx); w = maxX - x
            y = min(maxY - minSize.height, startFrame.minY + dy); h = maxY - y
        case 1: // top-right: right + top
            w = max(minSize.width, startFrame.width + dx)
            y = min(maxY - minSize.height, startFrame.minY + dy); h = maxY - y
        case 2: // bottom-left: left + bottom
            x = min(maxX - minSize.width, startFrame.minX + dx); w = maxX - x
            h = max(minSize.height, startFrame.height + dy)
        default: // bottom-right: right + bottom
            w = max(minSize.width, startFrame.width + dx)
            h = max(minSize.height, startFrame.height + dy)
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Text view delegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commit()        // Esc finishes editing
            return true
        }
        return false        // Enter → default newline
    }
}
