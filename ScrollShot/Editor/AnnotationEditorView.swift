import AppKit
import CoreGraphics

/// Editable canvas for an arbitrary image (e.g. a stitched long screenshot).
/// Same annotation model/behaviour as the overlay, but no region selection —
/// the whole image is editable, and the view scrolls inside a window.
///
/// Geometry: the view is flipped (top-left) and sized in points = pixels/scale,
/// so annotations map to image pixels via `* scale` on export.
final class AnnotationEditorView: NSView {
    private enum Mode { case idle, drawing, moving }

    private let baseCGImage: CGImage
    private let baseImage: NSImage
    private let scale: CGFloat
    /// Fixed point-size of the image (pixels / scale). Used for rendering &
    /// export so the output never depends on the live `bounds` (which a scroll
    /// view may resize), which would otherwise truncate the long image.
    private let displaySize: NSSize

    private var mode: Mode = .idle
    private var startPoint: CGPoint?
    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private var movingIndex: Int?
    private var lastMovePoint: CGPoint = .zero

    private var currentTool: AnnotationTool?
    private var currentColor: NSColor = .systemRed
    private var currentWidth: CGFloat = 4
    /// Next number for the counter tool.
    private var counterNext = 1

    private var textBox: TextBoxEditor?

    /// Lazily materialized on first use; released again in `outputImage()`.
    private var pixelatedImage: NSImage?
    /// True only when a mosaic annotation exists — the (expensive) pixelated
    /// copy is skipped entirely otherwise.
    private var needsPixelated: Bool {
        annotations.contains(where: Self.isMosaic) || (draft.map(Self.isMosaic) ?? false)
    }

    private static func isMosaic(_ annotation: Annotation) -> Bool {
        if case .mosaic = annotation.shape { return true }
        return false
    }

    private func pixelated() -> NSImage? {
        if pixelatedImage == nil,
           let cg = ImageUtils.pixelated(baseCGImage) {
            pixelatedImage = NSImage(cgImage: cg, size: displaySize)
        }
        return pixelatedImage
    }

    init(image: CGImage, scale: CGFloat) {
        self.baseCGImage = image
        self.scale = max(1, scale)
        let size = NSSize(width: CGFloat(image.width) / max(1, scale),
                          height: CGFloat(image.height) / max(1, scale))
        self.displaySize = size
        self.baseImage = NSImage(cgImage: image, size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentTool == nil ? .arrow : .crosshair)
    }

    // MARK: External controls (wired from the toolbar)

    func selectTool(_ tool: AnnotationTool) { currentTool = tool; window?.invalidateCursorRects(for: self) }
    func setColor(_ color: NSColor) { currentColor = color; restyleTextBox() }
    func setWidth(_ width: CGFloat) { currentWidth = width; restyleTextBox() }

    func undo() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if case .counter = removed.shape { counterNext -= 1 }
        needsDisplay = true
    }

    @discardableResult
    func save() -> URL? {
        commitTextBox()
        guard let image = outputImage() else { return nil }
        ImageUtils.copyToPasteboard(image)
        return try? ImageUtils.saveToDesktop(image)
    }

    func copy() {
        commitTextBox()
        guard let image = outputImage() else { return }
        ImageUtils.copyToPasteboard(image)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(origin: .zero, size: displaySize)
        baseImage.draw(in: rect)
        let pix = needsPixelated ? pixelated() : nil
        for annotation in annotations {
            annotation.draw(pixelatedImage: pix, fullBounds: rect)
        }
        draft?.draw(pixelatedImage: pix, fullBounds: rect)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextBox()
        let point = convert(event.locationInWindow, from: nil)
        if let index = hitTestAnnotation(at: point) {
            mode = .moving
            movingIndex = index
            lastMovePoint = point
            return
        }
        guard let tool = currentTool else { return }
        if tool == .text {
            beginTextEditing(at: point)
        } else {
            mode = .drawing
            startPoint = point
            draft = initialDraft(tool: tool, at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .drawing:
            updateDraft(to: point)
            needsDisplay = true
        case .moving:
            moveAnnotation(to: point)
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .drawing, let draft, isValid(draft) {
            annotations.append(draft)
            if case .counter = draft.shape { counterNext += 1 }
        }
        draft = nil
        startPoint = nil
        movingIndex = nil
        mode = .idle
        needsDisplay = true
    }

    // MARK: Annotation helpers

    private func hitTestAnnotation(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() where annotations[index].hitTest(point, tolerance: 8) {
            return index
        }
        return nil
    }

    private func moveAnnotation(to point: CGPoint) {
        guard let index = movingIndex else { return }
        var delta = CGSize(width: point.x - lastMovePoint.x, height: point.y - lastMovePoint.y)
        let box = annotations[index].boundingBox
        delta.width = min(max(delta.width, -box.minX), bounds.width - box.maxX)
        delta.height = min(max(delta.height, -box.minY), bounds.height - box.maxY)
        annotations[index] = annotations[index].translated(by: delta)
        lastMovePoint = point
        needsDisplay = true
    }

    private func initialDraft(tool: AnnotationTool, at point: CGPoint) -> Annotation {
        let shape: Annotation.Shape
        switch tool {
        case .arrow: shape = .arrow(from: point, to: point)
        case .rectangle: shape = .rectangle(CGRect(origin: point, size: .zero))
        case .ellipse: shape = .ellipse(CGRect(origin: point, size: .zero))
        case .mosaic: shape = .mosaic(CGRect(origin: point, size: .zero))
        case .pen: shape = .pen([point])
        case .counter: shape = .counter(center: point, number: counterNext)
        case .text: shape = .text(rect: CGRect(origin: point, size: .zero), string: "", fontSize: textFontSize(for: currentWidth))
        }
        return Annotation(shape: shape, color: currentColor, lineWidth: currentWidth)
    }

    private func updateDraft(to rawPoint: CGPoint) {
        guard var draft, let start = startPoint else { return }
        let point = clampToBounds(rawPoint)
        let rect = normalizedRect(from: clampToBounds(start), to: point)
        switch draft.shape {
        case .arrow: draft.shape = .arrow(from: start, to: point)
        case .rectangle: draft.shape = .rectangle(rect)
        case .ellipse: draft.shape = .ellipse(rect)
        case .mosaic: draft.shape = .mosaic(rect)
        case .pen(var points): points.append(point); draft.shape = .pen(points)
        // Dragging a counter fine-tunes its position before release.
        case let .counter(_, number): draft.shape = .counter(center: point, number: number)
        case .text: break
        }
        self.draft = draft
    }

    private func isValid(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect):
            return rect.width > 2 && rect.height > 2
        case let .arrow(from, to):
            return hypot(to.x - from.x, to.y - from.y) > 3
        case let .pen(points):
            return points.count > 1
        case let .text(_, string, _):
            return !string.isEmpty
        case .counter:
            return true   // single click, no drag distance needed
        }
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func textFontSize(for width: CGFloat) -> CGFloat { 12 + width * 2.5 }

    // MARK: Text boxes

    private func beginTextEditing(at point: CGPoint) {
        commitTextBox()
        let fontSize = textFontSize(for: currentWidth)
        let box = TextBoxEditor(
            frame: CGRect(x: point.x, y: point.y, width: 180, height: max(48, fontSize * 2)),
            fontSize: fontSize,
            color: currentColor
        )
        box.onCommit = { [weak self] rect, string, size, color in
            guard let self else { return }
            self.annotations.append(Annotation(
                shape: .text(rect: rect, string: string, fontSize: size),
                color: color,
                lineWidth: self.currentWidth
            ))
            self.needsDisplay = true
        }
        box.onFinished = { [weak self] in self?.textBox = nil }
        addSubview(box)
        textBox = box
        box.focus()
    }

    private func commitTextBox() {
        textBox?.commit()
        textBox = nil
    }

    private func restyleTextBox() {
        textBox?.setColor(currentColor)
        textBox?.setFontSize(textFontSize(for: currentWidth))
    }

    // MARK: Output

    private func outputImage() -> CGImage? {
        // Release the pixelated copy up front so base + output (+ pixelated,
        // if re-created below) don't all coexist.
        pixelatedImage = nil
        let pixelWidth = baseCGImage.width
        let pixelHeight = baseCGImage.height
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let base = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        NSGraphicsContext.saveGraphicsState()
        let cg = base.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixelHeight))
        cg.scaleBy(x: scale, y: -scale)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped

        // Render against the fixed display size, NOT the live `bounds`.
        let rect = NSRect(origin: .zero, size: displaySize)
        baseImage.draw(in: rect)
        let pix = needsPixelated ? pixelated() : nil
        for annotation in annotations {
            annotation.draw(pixelatedImage: pix, fullBounds: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}
