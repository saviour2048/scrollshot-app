import AppKit

/// Borderless, non-activating panel that floats above the menu bar (and over
/// full-screen apps) right at the notch. Fully transparent; the card's dark
/// material is drawn by the SwiftUI content.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        // Hidden with orderOut when idle instead of toggling
        // ignoresMouseEvents — a hidden window can never swallow a click.
    }

    // A panel is key-able only with .nonactivatingPanel + this override when
    // it has no title bar; the card's buttons need first-mouse clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
