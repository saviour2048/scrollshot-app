import AppKit
import CoreGraphics

/// A region chosen in the frozen overlay and handed off to long (scroll) capture.
struct LongCaptureRegion {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Display-relative, top-left origin, in points (ready for ScreenCaptureKit).
    let sourceRect: CGRect
    /// Global AppKit coordinates (bottom-left origin) — for panel placement and
    /// auto-scroll cursor positioning.
    let globalRect: CGRect
    let scale: CGFloat
}
