import AppKit

/// Where the notch card lives on a given screen, and how wide it may be.
///
/// Notch screens: `safeAreaInsets.top > 0`. The notch occupies the middle of
/// the menu bar between the two auxiliary areas, so its width is what remains
/// after subtracting them. Notch-less screens get a fixed 560pt floating bar
/// centered at the top edge instead.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let cardWidth: CGFloat

    /// Taller than any card we render; the window reserves this much below
    /// the notch and the card top-anchors inside (empty space is click-through).
    static let maxCardHeight: CGFloat = 420

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let topInset = screen.safeAreaInsets.top
        hasNotch = topInset > 0
        notchHeight = max(topInset, 0)
        if hasNotch {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            notchWidth = screen.frame.width - left - right
            cardWidth = min(max(notchWidth + 320, 480), screen.frame.width - 40)
        } else {
            notchWidth = 0
            cardWidth = 560
        }
    }

    /// The screen with a notch if any, else the main screen.
    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return NotchGeometry(screen: notched)
        }
        if let main = NSScreen.main { return NotchGeometry(screen: main) }
        return screens.first.map(NotchGeometry.init)
    }

    /// Window frame: top-center of the screen, hanging from the top edge.
    var panelFrame: NSRect {
        let height = max(notchHeight, 24) + Self.maxCardHeight
        return NSRect(
            x: screenFrame.midX - cardWidth / 2,
            y: screenFrame.maxY - height,
            width: cardWidth,
            height: height
        )
    }
}
