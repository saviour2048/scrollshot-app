import CoreGraphics

/// Stitches a sequence of same-sized frames (captured while the user scrolls a
/// region downward) into one tall image — handling apps with a FIXED header
/// and/or footer (chat title bars, input bars, toolbars) that don't scroll.
///
/// Approach (matches mature scroll-stitchers like Picsew/Tailor, verified on a
/// synthetic scroll harness with sticky header+footer):
///  1. From the first scrolled pair, detect the static top band (`headerH`) and
///     static bottom band (`footerH`) — rows that are unchanged between frames.
///  2. Align and stitch ONLY the scrolling middle region; the static header is
///     emitted once at the very top and the footer once at the very bottom.
/// Naively appending each frame's bottom rows (the old approach) repeated the
/// fixed footer/header down the image and ghosted text (looked blurry).
///
/// Matching is a mean-absolute-difference (SAD) search on a 128-px-wide grayscale
/// copy — cheap and robust for the ~3 fps capture rate. (Was 64 px / step 3;
/// doubling both halves seam misalignment on text-heavy content for negligible
/// CPU at this frame rate.)
///
/// Thread-safety is guaranteed by the caller: every access happens serially on a
/// single dedicated queue (LongCaptureController.stitchQueue).
final class FrameStitcher: @unchecked Sendable {
    private let grayWidth = 128
    private let rowSampleStep = 2
    private let maxShiftRatio: CGFloat = 0.9
    private let minOverlapRatio: CGFloat = 0.15
    /// Mean per-pixel gray difference (0–255) below which an alignment is accepted.
    private let matchThreshold: Double = 16
    /// Per-pixel mean gray difference below which a row counts as "unchanged"
    /// between two frames (→ part of a fixed header/footer).
    private let staticRowTolerance: Double = 6
    /// The header and footer are each capped at this fraction of the frame, so a
    /// slow/absent scroll can't classify the whole frame as static.
    private let maxStaticRatio: CGFloat = 0.45

    private var frameW = 0
    private var frameH = 0

    // Before the static header/footer are locked in (waiting for a real scroll).
    private var pendingFrame: CGImage?
    private var pendingGray: [UInt8] = []
    private var staticLocked = false

    // After lock-in.
    private var headerH = 0
    private var footerH = 0
    private var headerImage: CGImage?
    private var footerImage: CGImage?          // updated to the latest frame's footer
    private var middleStrips: [CGImage] = []   // scrolling content, in order
    private var prevScrollGray: [UInt8] = []
    private var prevScrollH = 0

    private(set) var outputWidth = 0

    /// Hard cap (~100 screens of typical content) on the stitched height; past
    /// this the accumulated strip copies dominate memory, so the caller should
    /// stop feeding frames (LongCaptureController finishes the session).
    private let maxTotalHeight = 50_000
    var canAccept: Bool { totalHeight < maxTotalHeight }

    var frameCount: Int { middleStrips.count + (staticLocked ? 0 : (pendingFrame == nil ? 0 : 1)) }

    var totalHeight: Int {
        staticLocked ? headerH + middleStrips.reduce(0) { $0 + $1.height } + footerH : frameH
    }

    func reset() {
        frameW = 0; frameH = 0
        pendingFrame = nil; pendingGray = []
        staticLocked = false
        headerH = 0; footerH = 0
        headerImage = nil; footerImage = nil
        middleStrips = []
        prevScrollGray = []; prevScrollH = 0
        outputWidth = 0
    }

    /// Feeds a freshly captured frame. Returns true if new content was appended.
    @discardableResult
    func add(_ frame: CGImage) -> Bool {
        guard let gray = Self.grayscale(frame, width: grayWidth) else { return false }
        let H = frame.height

        // First frame: keep it whole until a scrolled pair reveals the static bands.
        if pendingFrame == nil && !staticLocked {
            pendingFrame = frame
            pendingGray = gray
            frameW = frame.width; frameH = H; outputWidth = frame.width
            return true
        }

        if !staticLocked {
            let (hH, fH) = detectStatic(a: pendingGray, b: gray, height: H)
            let scrollH = H - hH - fH
            if scrollH >= Int(CGFloat(H) * minOverlapRatio) {
                let prevScroll = scrollGray(pendingGray, headerH: hH, footerH: fH, H: H)
                let newScroll = scrollGray(gray, headerH: hH, footerH: fH, H: H)
                let (dy, err) = bestShift(prevGray: prevScroll, prevH: scrollH, newGray: newScroll, newH: scrollH)
                if dy > 0, err <= matchThreshold {
                    // Lock the static bands and seed the middle from the pending frame.
                    headerH = hH; footerH = fH
                    headerImage = pendingFrame?.cropping(to: CGRect(x: 0, y: 0, width: frameW, height: hH))
                    if let m = pendingFrame?.cropping(to: CGRect(x: 0, y: hH, width: frameW, height: scrollH)) {
                        middleStrips = [m]
                    }
                    footerImage = frame.cropping(to: CGRect(x: 0, y: H - fH, width: frameW, height: fH))
                    prevScrollGray = newScroll; prevScrollH = scrollH
                    staticLocked = true
                    return appendNewContent(frame, dy: dy, H: H)
                }
            }
            // No usable scroll yet — advance the pending frame and keep waiting.
            pendingFrame = frame; pendingGray = gray
            return true
        }

        // Steady state: align this frame's scroll region against the previous one.
        let newScroll = scrollGray(gray, headerH: headerH, footerH: footerH, H: H)
        let scrollH = H - headerH - footerH
        let (dy, err) = bestShift(prevGray: prevScrollGray, prevH: prevScrollH, newGray: newScroll, newH: scrollH)
        prevScrollGray = newScroll; prevScrollH = scrollH
        // Keep the freshest footer (the bottom bar may have small live changes).
        if let f = frame.cropping(to: CGRect(x: 0, y: H - footerH, width: frameW, height: footerH)) {
            footerImage = f
        }
        guard dy > 0, err <= matchThreshold else { return false }
        return appendNewContent(frame, dy: dy, H: H)
    }

    /// Appends the `dy` rows that newly scrolled into the bottom of the scroll
    /// region (never the static footer).
    @discardableResult
    private func appendNewContent(_ frame: CGImage, dy: Int, H: Int) -> Bool {
        let cropY = (H - footerH) - dy
        guard cropY >= headerH,
              let strip = frame.cropping(to: CGRect(x: 0, y: cropY, width: frameW, height: dy))
        else { return false }
        middleStrips.append(strip)
        return true
    }

    /// Composes header + scrolling middle + footer into one tall image.
    func result() -> CGImage? {
        // Never saw a scroll → just return the single frame we captured.
        if !staticLocked { return pendingFrame }
        let total = totalHeight
        guard outputWidth > 0, total > 0,
              let ctx = CGContext(data: nil, width: outputWidth, height: total,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CGContext origin is bottom-left, so place from the top down.
        var y = total
        func place(_ img: CGImage?) {
            guard let img else { return }
            y -= img.height
            ctx.draw(img, in: CGRect(x: 0, y: y, width: outputWidth, height: img.height))
        }
        place(headerImage)
        for strip in middleStrips { place(strip) }
        // Free the strips before makeImage() so their copies don't coexist with
        // the freshly composed output bitmap (peak 3× → 2×).
        middleStrips.removeAll()
        place(footerImage)
        return ctx.makeImage()
    }

    // MARK: Matching

    private func scrollGray(_ full: [UInt8], headerH: Int, footerH: Int, H: Int) -> [UInt8] {
        let start = headerH * grayWidth
        let end = (H - footerH) * grayWidth
        guard start < end, end <= full.count else { return full }
        return Array(full[start..<end])
    }

    private func rowDiff(_ a: [UInt8], _ b: [UInt8], _ y: Int) -> Double {
        var sum = 0
        let base = y * grayWidth
        for x in 0..<grayWidth { sum += abs(Int(a[base + x]) - Int(b[base + x])) }
        return Double(sum) / Double(grayWidth)
    }

    /// Rows unchanged from the top / bottom between two frames = fixed bands.
    private func detectStatic(a: [UInt8], b: [UInt8], height H: Int) -> (Int, Int) {
        let cap = Int(CGFloat(H) * maxStaticRatio)
        var hH = 0
        while hH < cap, rowDiff(a, b, hH) < staticRowTolerance { hH += 1 }
        var fH = 0
        while fH < cap, rowDiff(a, b, H - 1 - fH) < staticRowTolerance { fH += 1 }
        return (hH, fH)
    }

    /// Finds the vertical shift minimizing mean abs difference over the overlap.
    private func bestShift(prevGray: [UInt8], prevH: Int, newGray: [UInt8], newH: Int) -> (dy: Int, error: Double) {
        let width = grayWidth
        let base = min(prevH, newH)
        let maxShift = Int(CGFloat(base) * maxShiftRatio)
        let minOverlap = max(1, Int(CGFloat(base) * minOverlapRatio))

        var bestDy = 0
        var bestError = Double.greatestFiniteMagnitude
        var dy = 0
        while dy <= maxShift {
            let overlap = min(prevH - dy, newH)
            if overlap >= minOverlap {
                var sum = 0.0
                var count = 0
                var y = 0
                while y < overlap {
                    let prevRow = (y + dy) * width
                    let newRow = y * width
                    var x = 0
                    while x < width {
                        sum += Double(abs(Int(prevGray[prevRow + x]) - Int(newGray[newRow + x])))
                        count += 1
                        x += 1
                    }
                    y += rowSampleStep
                }
                if count > 0 {
                    let error = sum / Double(count)
                    if error < bestError { bestError = error; bestDy = dy }
                }
            }
            dy += 1
        }
        return (bestDy, bestError)
    }

    /// Renders `image` to a `width`-wide 8-bit grayscale buffer, full height,
    /// row-major with row 0 at the top.
    static func grayscale(_ image: CGImage, width: Int) -> [UInt8]? {
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height))
    }
}
