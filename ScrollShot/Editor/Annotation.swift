import AppKit
import CoreGraphics

private extension CGPoint {
    func offset(_ delta: CGSize) -> CGPoint {
        CGPoint(x: x + delta.width, y: y + delta.height)
    }
}

/// The drawing tools available in the overlay toolbar.
enum AnnotationTool: Int, CaseIterable {
    case arrow, rectangle, ellipse, pen, counter, text, mosaic
}

/// A single committed annotation. All geometry is stored in the canvas's
/// flipped (top-left origin) point coordinate space, matching the live view so
/// the same `draw` routine works for both on-screen rendering and export.
struct Annotation {
    enum Shape {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        /// A numbered step marker: a filled circle with a white number, placed
        /// with a single click (ShareX "Step" / Greenshot "Counter" style).
        case counter(center: CGPoint, number: Int)
        /// A text box: the string is wrapped/clipped inside `rect`.
        case text(rect: CGRect, string: String, fontSize: CGFloat)
        case mosaic(CGRect)
    }

    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat

    /// Draws into the current graphics context.
    /// - Parameters:
    ///   - pixelatedImage: a fully-pixelated copy of the frozen screenshot,
    ///     sized to `fullBounds`, used to render mosaic regions.
    ///   - fullBounds: the canvas bounds (points), i.e. where the screenshot is drawn.
    func draw(pixelatedImage: NSImage?, fullBounds: CGRect) {
        switch shape {
        case let .arrow(from, to):
            Annotation.drawArrow(from: from, to: to, lineWidth: lineWidth, color: color)

        case let .rectangle(rect):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case let .ellipse(rect):
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case let .pen(points):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            color.setStroke()
            path.stroke()

        case let .text(rect, string, fontSize):
            guard !string.isEmpty else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            // Wraps within the box width and across explicit newlines.
            (string as NSString).draw(in: rect, withAttributes: attributes)

        case let .counter(center, number):
            Annotation.drawCounter(center: center, number: number, lineWidth: lineWidth, color: color)

        case let .mosaic(rect):
            guard let pixelatedImage else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            pixelatedImage.draw(in: fullBounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The axis-aligned bounds of the annotation in canvas points.
    var boundingBox: CGRect {
        switch shape {
        case let .arrow(from, to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(from.x - to.x), height: abs(from.y - to.y))
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect):
            return rect
        case let .pen(points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in points {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .text(rect, _, _):
            return rect
        case let .counter(center, _):
            let r = Annotation.counterRadius(for: lineWidth)
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    /// Whether `point` lands on the annotation (used to grab it for dragging).
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = max(tolerance, lineWidth + 4)
        switch shape {
        case let .arrow(from, to):
            return Annotation.distance(point, toSegment: from, to) <= tol
        case let .pen(points):
            guard points.count > 1 else { return false }
            for i in 0..<(points.count - 1) where
                Annotation.distance(point, toSegment: points[i], points[i + 1]) <= tol {
                return true
            }
            return false
        case let .rectangle(rect), let .ellipse(rect):
            // Grab near the outline; for small shapes the whole box is grabbable.
            let outer = rect.insetBy(dx: -tol, dy: -tol)
            let inner = rect.insetBy(dx: tol, dy: tol)
            guard outer.contains(point) else { return false }
            return inner.width <= 0 || inner.height <= 0 || !inner.contains(point)
        case let .mosaic(rect):
            return rect.contains(point)
        case let .text(rect, _, _):
            return rect.insetBy(dx: -tol, dy: -tol).contains(point)
        case let .counter(center, _):
            return hypot(point.x - center.x, point.y - center.y) <= Annotation.counterRadius(for: lineWidth) + tol
        }
    }

    /// A copy translated by `delta`.
    func translated(by delta: CGSize) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from.offset(delta), to: to.offset(delta))
        case let .rectangle(rect):
            copy.shape = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .ellipse(rect):
            copy.shape = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .mosaic(rect):
            copy.shape = .mosaic(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .pen(points):
            copy.shape = .pen(points.map { $0.offset(delta) })
        case let .text(rect, string, fontSize):
            copy.shape = .text(rect: rect.offsetBy(dx: delta.width, dy: delta.height), string: string, fontSize: fontSize)
        case let .counter(center, number):
            copy.shape = .counter(center: center.offset(delta), number: number)
        }
        return copy
    }

    /// Distance from a point to a line segment.
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    /// Radius of a counter marker for the given stroke-width tier
    /// (细/中/粗 → 11/13/16 pt, so two-digit numbers stay legible).
    static func counterRadius(for lineWidth: CGFloat) -> CGFloat { 9 + lineWidth }

    /// A filled circle with a centered white number, the standard "step" marker.
    static func drawCounter(center: CGPoint, number: Int, lineWidth: CGFloat, color: NSColor) {
        let radius = counterRadius(for: lineWidth)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        // Thin light ring so the marker stays visible on same-colored content.
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()

        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.1, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                   withAttributes: attributes)
    }

    static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, color: NSColor) {
        color.setStroke()
        color.setFill()

        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: to)
        shaft.stroke()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(12, lineWidth * 3.5)
        let headAngle = CGFloat.pi / 7
        let left = CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        )
        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }
}
