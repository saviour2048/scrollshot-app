import AppKit

/// The window arrangements the user can trigger by hotkey.
enum Tile: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf:    return "左半屏"
        case .rightHalf:   return "右半屏"
        case .topHalf:     return "上半屏"
        case .bottomHalf:  return "下半屏"
        case .topLeft:     return "左上角"
        case .topRight:    return "右上角"
        case .bottomLeft:  return "左下角"
        case .bottomRight: return "右下角"
        case .maximize:    return "最大化"
        case .center:      return "居中"
        case .nextDisplay:     return "移到下一屏"
        case .previousDisplay: return "移到上一屏"
        }
    }
}

/// Computes tile frames (in AppKit bottom-left coordinates) and applies them to
/// the frontmost window via `AXWindow`.
enum WindowTiler {

    /// Moves the frontmost window into `tile`.
    @discardableResult
    static func apply(_ tile: Tile) -> Bool {
        guard let window = AXWindow.frontmost() else {
            NSSound.beep()
            return false
        }
        let axFrame = window.frame                 // AX (top-left) coords
        guard !axFrame.isNull else { NSSound.beep(); return false }

        let appKitFrame = axFrame.axFlipped        // → AppKit (bottom-left)
        let screen = screenContaining(appKitFrame) ?? NSScreen.main

        if tile == .nextDisplay || tile == .previousDisplay {
            return moveToDisplay(window, appKitFrame: appKitFrame, from: screen,
                                 direction: tile == .nextDisplay ? 1 : -1)
        }

        guard let visible = screen?.visibleFrame else { return false }

        var target = targetRect(tile, in: visible, windowSize: appKitFrame.size)
        target = clamp(target, into: visible)      // keep it on-screen
        window.setFrame(target.axFlipped)          // flip back to AX and set
        return true
    }

    // MARK: Geometry (AppKit bottom-left coordinates; y grows upward)

    static func targetRect(_ tile: Tile, in vf: CGRect, windowSize: CGSize) -> CGRect {
        let w = (vf.width / 2).rounded(.down)
        let h = (vf.height / 2).rounded(.down)
        switch tile {
        case .maximize:    return vf
        case .leftHalf:    return CGRect(x: vf.minX,     y: vf.minY,     width: w,        height: vf.height)
        case .rightHalf:   return CGRect(x: vf.maxX - w, y: vf.minY,     width: w,        height: vf.height)
        case .topHalf:     return CGRect(x: vf.minX,     y: vf.maxY - h, width: vf.width, height: h)
        case .bottomHalf:  return CGRect(x: vf.minX,     y: vf.minY,     width: vf.width, height: h)
        case .topLeft:     return CGRect(x: vf.minX,     y: vf.maxY - h, width: w,        height: h)
        case .topRight:    return CGRect(x: vf.maxX - w, y: vf.maxY - h, width: w,        height: h)
        case .bottomLeft:  return CGRect(x: vf.minX,     y: vf.minY,     width: w,        height: h)
        case .bottomRight: return CGRect(x: vf.maxX - w, y: vf.minY,     width: w,        height: h)
        case .center:
            let cw = min(windowSize.width, vf.width)
            let ch = min(windowSize.height, vf.height)
            return CGRect(x: (vf.width - cw) / 2 + vf.minX,
                          y: (vf.height - ch) / 2 + vf.minY,
                          width: cw, height: ch)
        case .nextDisplay, .previousDisplay:
            return vf   // handled in apply(); never tiled within one screen
        }
    }

    // MARK: Cross-display move

    /// Moves the window to the next/previous screen (in `NSScreen.screens`
    /// order, wrapping around), preserving its relative position and scaling
    /// its size by the ratio of the two screens' visible frames.
    private static func moveToDisplay(_ window: AXWindow, appKitFrame: CGRect,
                                      from source: NSScreen?, direction: Int) -> Bool {
        let screens = NSScreen.screens
        guard screens.count > 1, let source,
              let index = screens.firstIndex(of: source) else {
            NSSound.beep()
            return false
        }
        let target = screens[(index + direction + screens.count) % screens.count]
        let svf = source.visibleFrame
        let tvf = target.visibleFrame

        let sx = tvf.width / svf.width
        let sy = tvf.height / svf.height
        var frame = appKitFrame
        frame.origin.x = tvf.minX + (frame.minX - svf.minX) * sx
        frame.origin.y = tvf.minY + (frame.minY - svf.minY) * sy
        frame.size.width  = min(frame.width * sx, tvf.width)
        frame.size.height = min(frame.height * sy, tvf.height)
        frame = clamp(frame, into: tvf)
        window.setFrame(frame.axFlipped)   // setFrame does size→position→size, safe cross-display
        return true
    }

    /// Nudges a rect fully inside `vf` (some apps clamp size and end up off-screen).
    private static func clamp(_ rect: CGRect, into vf: CGRect) -> CGRect {
        var r = rect
        if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width }
        if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
        r.origin.x = max(r.origin.x, vf.minX)
        r.origin.y = max(r.origin.y, vf.minY)
        return r
    }

    // MARK: Screen selection

    private static func screenContaining(_ appKitRect: CGRect) -> NSScreen? {
        var best: NSScreen? = NSScreen.main
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(appKitRect)
            if screen.frame.contains(appKitRect) { return screen }
            let area = inter.width * inter.height
            if area > bestArea { bestArea = area; best = screen }
        }
        return best
    }
}

// MARK: - AppKit ↔ AX coordinate flip

extension CGRect {
    /// Flips between AppKit (bottom-left origin) and AX/CoreGraphics (top-left
    /// origin) about the primary display's top edge. Applying it twice is identity.
    var axFlipped: CGRect {
        guard !isNull, let primary = NSScreen.screens.first else { return self }
        return CGRect(x: origin.x, y: primary.frame.maxY - maxY, width: width, height: height)
    }
}
