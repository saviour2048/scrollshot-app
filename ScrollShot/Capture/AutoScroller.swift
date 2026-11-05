import AppKit
import CoreGraphics
import ApplicationServices

/// Posts scroll-wheel events to auto-scroll the content under a point.
/// Requires the Accessibility ("辅助功能") permission to post events.
enum AutoScroller {
    /// Whether the app is currently trusted to post events.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access (shows the system dialog).
    static func requestTrust() {
        guard !AppConfig.suppressesPermissionPrompts else {
            Diag.permission.notice("auto-scroller accessibility prompt suppressed by SCROLLSHOT_SKIP_PERMISSION_PROMPTS")
            return
        }
        // Use the raw key string to avoid SDK differences in how
        // `kAXTrustedCheckOptionPrompt` is imported into Swift.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Moves the cursor to an AppKit-global point — ONCE at the start of auto
    /// scrolling. We deliberately don't do this every tick, otherwise the
    /// cursor is hijacked and the user can't click anything.
    static func warp(toAppKitPoint appKitPoint: CGPoint) {
        CGWarpMouseCursorPosition(cgPoint(fromAppKit: appKitPoint))
    }

    /// Posts a scroll-down event at the cursor's current location.
    /// (Negative wheel1 scrolls content downward; flip the sign if reversed.)
    static func postScrollDown(pixels: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-pixels),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Converts an AppKit-global point (bottom-left origin) to a CoreGraphics
    /// global point (top-left origin), used by the cursor / event APIs.
    private static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
