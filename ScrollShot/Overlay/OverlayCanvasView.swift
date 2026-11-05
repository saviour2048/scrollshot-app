import AppKit
import CoreGraphics
import os

/// The interactive surface for one display: frozen screenshot, dimmed outside
/// the selection, an annotation toolbar, and the drawing tools themselves.
/// Output is the selection region of the frozen image composited with all
/// annotations, at full pixel resolution.
///
/// Coordinate space: the view is flipped (top-left origin), so selection &
/// annotation points map directly to frozen-image pixels via `* backingScaleFactor`.
final class OverlayCanvasView: NSView {
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    var onLongCapture: ((LongCaptureRegion) -> Void)?

    private enum Mode { case idle, selecting, drawing, moving }

    private let shot: DisplayShot
    private let frozenImage: NSImage

    private var mode: Mode = .idle
    private var startPoint: CGPoint?
    private var selectionRect: CGRect? { didSet { needsDisplay = true } }

    private var movingIndex: Int?
    private var lastMovePoint: CGPoint = .zero

    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private var currentTool: AnnotationTool?
    private var currentColor: NSColor = .systemRed
    private var currentWidth: CGFloat = 4
    /// Next number for the counter tool; resets when annotations are cleared.
    private var counterNext = 1

    private var bar: AnnotationBar?
    private var textBox: TextBoxEditor?

    /// Lazily materialized on first use; skipped entirely when no mosaic
    /// annotation exists (a full-screen pixelated bitmap is ~60 MB per display).
    private var pixelatedImage: NSImage?
    private var needsPixelated: Bool {
        annotations.contains(where: Self.isMosaic) || (draft.map(Self.isMosaic) ?? false)
    }

    private static func isMosaic(_ annotation: Annotation) -> Bool {
        if case .mosaic = annotation.shape { return true }
        return false
    }

    private func pixelated() -> NSImage? {
        if pixelatedImage == nil,
           let cg = ImageUtils.pixelated(shot.image) {
            pixelatedImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return pixelatedImage
    }

    init(shot: DisplayShot) {
        self.shot = shot
        self.frozenImage = NSImage(
            cgImage: shot.image,
            size: NSSize(width: shot.image.width, height: shot.image.height)
        )
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var scale: CGFloat { shot.screen.backingScaleFactor }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        frozenImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        guard let rect = selectionRect, rect.width > 0, rect.height > 0 else {
            drawHint()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        frozenImage.draw(in: bounds)
        drawAnnotations()
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        drawSizeLabel(for: rect)
    }

    private func drawAnnotations() {
        let pix = needsPixelated ? pixelated() : nil
        for annotation in annotations {
            annotation.draw(pixelatedImage: pix, fullBounds: bounds)
        }
        draft?.draw(pixelatedImage: pix, fullBounds: bounds)
    }

    private func drawHint() {
        let text = "拖动选择截图区域 · Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.4),
                  withAttributes: attributes)
    }

    private func drawSizeLabel(for rect: CGRect) {
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let padH: CGFloat = 9, padV: CGFloat = 5
        var origin = CGPoint(x: rect.minX + padH, y: rect.minY - textSize.height - padV * 2 - 6)
        if origin.y < padV { origin.y = rect.minY + padV + 6 }
        let pill = CGRect(x: origin.x - padH, y: origin.y - padV,
                          width: textSize.width + padH * 2, height: textSize.height + padV * 2)
        // Frosted dark pill (glass-like) with a thin highlight edge.
        NSColor.black.withAlphaComponent(0.55).setFill()
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
        label.draw(at: origin, withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        Diag.capture.debug("canvas mouseDown — event reached the overlay (window isKey=\(self.window?.isKeyWindow == true, privacy: .public), appActive=\(NSApp.isActive, privacy: .public))")
        commitTextBox()
        let point = convert(event.locationInWindow, from: nil)

        guard let selection = selectionRect else {
            beginSelection(at: point)
            return
        }

        // 1. Grab an existing annotation (topmost first) to drag it.
        if let index = hitTestAnnotation(at: point) {
            mode = .moving
            movingIndex = index
            lastMovePoint = point
            startPoint = point
            return
        }

        // 2. Inside the selection with a tool active → draw.
        if selection.contains(point) {
            if let tool = currentTool {
                if tool == .text {
                    beginTextEditing(at: point)
                } else {
                    beginDrawing(tool: tool, at: point)
                }
            }
            return
        }

        // 3. Clicked outside the selection → start a new selection.
        annotations.removeAll()
        counterNext = 1
        draft = nil
        beginSelection(at: point)
    }

    /// Index of the topmost annotation under `point`, if any.
    private func hitTestAnnotation(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() where annotations[index].hitTest(point, tolerance: 8) {
            return index
        }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .selecting:
            selectionRect = normalizedRect(from: start, to: point).intersection(bounds)
        case .drawing:
            updateDraft(from: start, to: point)
            needsDisplay = true
        case .moving:
            moveAnnotation(to: point)
        case .idle:
            break
        }
    }

    /// Drags the grabbed annotation, keeping its bounds within the selection.
    private func moveAnnotation(to point: CGPoint) {
        guard let index = movingIndex, let selection = selectionRect else { return }
        var delta = CGSize(width: point.x - lastMovePoint.x, height: point.y - lastMovePoint.y)
        let box = annotations[index].boundingBox
        delta.width = min(max(delta.width, selection.minX - box.minX), selection.maxX - box.maxX)
        delta.height = min(max(delta.height, selection.minY - box.minY), selection.maxY - box.maxY)
        annotations[index] = annotations[index].translated(by: delta)
        lastMovePoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; mode = .idle; movingIndex = nil }
        switch mode {
        case .selecting:
            if let rect = selectionRect,
               rect.width >= AppConfig.minimumSelectionSize,
               rect.height >= AppConfig.minimumSelectionSize {
                showBar(for: rect)
            } else {
                selectionRect = nil
            }
        case .drawing:
            if let draft, isValid(draft) {
                annotations.append(draft)
                if case .counter = draft.shape { counterNext += 1 }
            }
            draft = nil
            needsDisplay = true
        case .moving, .idle:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: handleEscape()              // Esc
        case 36, 49, 76: confirmSave()       // Return / Enter / Space
        default: super.keyDown(with: event)
        }
    }

    /// Exit the capture overlay. Called both from the canvas's own keyDown and
    /// from the window (`cancelOperation`) when focus is on a toolbar control.
    func handleEscape() {
        onCancel?()
    }

    // MARK: Selection / drawing helpers

    private func beginSelection(at point: CGPoint) {
        mode = .selecting
        startPoint = point
        selectionRect = nil
        bar?.isHidden = true
    }

    // MARK: Tap-driven selection (menu-bar strip rescue)
    //
    // A CGEventTap in OverlayController feeds selection drags that START inside
    // the system menu-bar strip to these methods. That strip swallows the
    // initial mouseDown before it can reach this view (the menu bar owns it), so
    // such drags never arrive through the normal responder chain — exactly the
    // "can't start a selection in the menu bar" bug. Points are already in this
    // (flipped) canvas's coordinates. Everything below the strip still flows
    // through the regular mouseDown/Dragged/Up path untouched.

    /// True when a tap-delivered mouseDown at `point` should START a new
    /// selection (vs. land inside the current selection, where it's an
    /// annotation the normal path handles).
    func wantsTapSelection(at point: CGPoint) -> Bool {
        guard let selection = selectionRect else { return true }
        return !selection.contains(point)
    }

    func beginTapSelection(at point: CGPoint) {
        commitTextBox()
        annotations.removeAll()
        counterNext = 1
        draft = nil
        beginSelection(at: point)
    }

    func updateTapSelection(at point: CGPoint) {
        guard mode == .selecting, let start = startPoint else { return }
        selectionRect = normalizedRect(from: start, to: point).intersection(bounds)
        needsDisplay = true
    }

    func endTapSelection() {
        defer { startPoint = nil; mode = .idle }
        guard mode == .selecting else { return }
        if let rect = selectionRect,
           rect.width >= AppConfig.minimumSelectionSize,
           rect.height >= AppConfig.minimumSelectionSize {
            showBar(for: rect)
        } else {
            selectionRect = nil
        }
    }

    private func beginDrawing(tool: AnnotationTool, at point: CGPoint) {
        mode = .drawing
        startPoint = point
        draft = initialDraft(tool: tool, at: point)
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

    private func updateDraft(from start: CGPoint, to rawPoint: CGPoint) {
        guard var draft, let selection = selectionRect else { return }
        let point = clamp(rawPoint, to: selection)
        let rect = normalizedRect(from: clamp(start, to: selection), to: point)
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

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY))
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

    /// Finish the active text box (if any).
    private func commitTextBox() {
        textBox?.commit()
        textBox = nil
    }

    private func restyleTextBox() {
        textBox?.setColor(currentColor)
        textBox?.setFontSize(textFontSize(for: currentWidth))
    }

    // MARK: Toolbar

    private func showBar(for rect: CGRect) {
        let bar = self.bar ?? makeBar()
        bar.isHidden = false
        positionBar(bar, for: rect)
    }

    private func makeBar() -> AnnotationBar {
        let bar = AnnotationBar()
        bar.onSelectTool = { [weak self] tool in
            self?.currentTool = tool
            // Restore keyboard focus to the canvas so Return/Esc keep working
            // after clicking a tool button.
            self?.restoreFocus()
        }
        bar.onColor = { [weak self] color in
            self?.currentColor = color
            self?.restyleTextBox()
        }
        bar.onWidth = { [weak self] width in
            self?.currentWidth = width
            self?.restyleTextBox()
            self?.restoreFocus()
        }
        bar.onUndo = { [weak self] in
            self?.undo()
            self?.restoreFocus()
        }
        bar.onSave = { [weak self] in self?.confirmSave() }
        bar.onCopy = { [weak self] in self?.confirmCopy() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        bar.onLongCapture = { [weak self] in self?.requestLongCapture() }
        currentColor = bar.currentColor
        currentWidth = bar.currentWidth
        addSubview(bar)
        self.bar = bar
        return bar
    }

    /// Make the canvas first responder again unless a text field is being edited.
    private func restoreFocus() {
        guard textBox == nil else { return }
        window?.makeFirstResponder(self)
    }

    private func positionBar(_ bar: AnnotationBar, for rect: CGRect) {
        let size = bar.contentSize
        let gap: CGFloat = 8
        var origin = CGPoint(x: rect.minX, y: rect.maxY + gap)
        if origin.y + size.height > bounds.height {
            origin.y = rect.minY - gap - size.height
        }
        if origin.y < 0 {
            origin.y = max(0, min(bounds.height - size.height, rect.maxY + gap))
        }
        origin.x = min(max(0, origin.x), max(0, bounds.width - size.width))
        bar.frame = CGRect(origin: origin, size: size)
    }

    private func undo() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        // Roll the counter back when undoing a step marker, so the next
        // placement reuses the undone number instead of leaving a gap.
        if case .counter = removed.shape { counterNext -= 1 }
        needsDisplay = true
    }

    // MARK: Output

    private func confirmSave() {
        commitTextBox()
        guard let image = outputImage() else { onCancel?(); return }
        onFinish?(image)
    }

    private func confirmCopy() {
        commitTextBox()
        guard let image = outputImage() else { onCancel?(); return }
        ImageUtils.copyToPasteboard(image)
        onCancel?()
    }

    /// Hands the chosen region off to long (scroll) capture.
    private func requestLongCapture() {
        commitTextBox()
        guard let rect = selectionRect,
              rect.width >= 1, rect.height >= 1,
              let displayID = shot.screen.displayID else { onCancel?(); return }
        let frame = shot.screen.frame
        let globalRect = CGRect(
            x: frame.minX + rect.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let region = LongCaptureRegion(
            screen: shot.screen,
            displayID: displayID,
            sourceRect: rect,
            globalRect: globalRect,
            scale: shot.screen.backingScaleFactor
        )
        onLongCapture?(region)
    }

    /// Renders the selection region of the frozen image + annotations at full
    /// pixel resolution. The bitmap is sized to the selection directly — the
    /// coordinate system is translated so the selection's top-left lands at the
    /// bitmap origin, instead of rendering full-screen and cropping afterwards.
    private func outputImage() -> CGImage? {
        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return nil }
        // Release the pixelated copy before allocating the output bitmap.
        pixelatedImage = nil

        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let pixelWidth = Int(pixelRect.width)
        let pixelHeight = Int(pixelRect.height)
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
        // Keep user space in pixels (1 unit = 1 px) to avoid points/pixels ambiguity.
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        NSGraphicsContext.saveGraphicsState()
        let cg = base.cgContext
        // Top-left, point-unit coordinate system, shifted so the selection's
        // top-left sits at the bitmap origin: after scaleBy(1,-1) and the y-flip
        // in translateBy, drawing at point (rect.minX, rect.minY) maps to the
        // bitmap's top-left pixel.
        cg.translateBy(x: -rect.minX * scale, y: CGFloat(pixelHeight) + rect.minY * scale)
        cg.scaleBy(x: scale, y: -scale)
        // Present it as a *flipped* context so NSImage/NSBezierPath render
        // upright exactly like the live (flipped) view.
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped

        frozenImage.draw(in: bounds)
        drawAnnotations()
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}
