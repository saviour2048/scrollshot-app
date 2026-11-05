import AppKit
import CoreGraphics
import ApplicationServices
import os

/// What the frozen overlay produced.
enum OverlayResult {
    case image(CGImage)              // normal screenshot, ready to save
    case longCapture(LongCaptureRegion)  // user chose 长截图 for this region
    case cancelled
}

/// Presents one borderless, top-most window per display, each showing that
/// display's frozen screenshot. The user selects a region on one of them; the
/// modal session returns the result.
@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var result: OverlayResult = .cancelled

    /// Runs a modal selection session for the frozen screenshots.
    ///
    /// Using `NSApp.runModal(for:)` guarantees the overlay window is the key
    /// window and receives events without relying on asynchronous app
    /// activation or manual event-tracking loops. The modal session blocks
    /// until the user finishes, cancels, or chooses long capture.
    func runModal(shots: [DisplayShot]) -> OverlayResult {
        guard windows.isEmpty else {
            Diag.capture.debug("runModal ignored: overlay already up")
            return .cancelled
        }

        result = .cancelled

        windows = shots.map { shot in
            let window = OverlayWindow(shot: shot)
            window.canvas.onFinish = { [weak self] image in
                self?.result = .image(image)
                NSApp.stopModal()
            }
            window.canvas.onCancel = { [weak self] in
                self?.result = .cancelled
                NSApp.stopModal()
            }
            window.canvas.onLongCapture = { [weak self] region in
                self?.result = .longCapture(region)
                NSApp.stopModal()
            }
            window.orderFrontRegardless()
            return window
        }

        // Key the window under the cursor (correct on multi-monitor: the main
        // screen's window is not necessarily where the user is looking).
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first

        if let keyWindow {
            keyWindow.makeKeyAndOrderFront(nil)
            Diag.capture.info("overlay modal started: \(self.windows.count, privacy: .public) window(s), keyed=\(keyWindow.isKeyWindow, privacy: .public)")
            // Diagnostics: does the overlay actually cover the menu bar?
            for w in self.windows {
                let f = w.frame
                let sf = w.screen?.frame ?? .zero
                let vf = w.screen?.visibleFrame ?? .zero
                Diag.capture.info("overlay geom: win=\(Int(f.minX),privacy:.public),\(Int(f.minY),privacy:.public),\(Int(f.width),privacy:.public)x\(Int(f.height),privacy:.public) maxY=\(Int(f.maxY),privacy:.public) | screen maxY=\(Int(sf.maxY),privacy:.public) visible maxY=\(Int(vf.maxY),privacy:.public) | policy=\(NSApp.activationPolicy().rawValue,privacy:.public) active=\(NSApp.isActive,privacy:.public)")
            }
            installMouseTap()
            NSApp.runModal(for: keyWindow)
        }

        // Modal ended — tear down the tap and dismiss every overlay window.
        removeMouseTap()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        // Hand the result off but don't keep the (large) image referenced by
        // `self.result` after the session ends.
        let r = result
        result = .cancelled
        return r
    }

    // MARK: - Menu-bar-strip mouse tap
    //
    // A window at CGShieldingWindowLevel covers the menu bar but does NOT receive
    // the *initial* mouseDown in the top ~24px strip: the WindowServer routes that
    // strip to the menu bar's owner, and an .accessory app can't own/hide the menu
    // bar to change that. So — like CleanShot X (also an LSUIElement app that
    // requires Accessibility) — we run a CGEventTap during capture, catch the
    // mouseDown *before* the WindowServer dispatches it to the menu bar, and drive
    // the selection ourselves. Only drags that START in the strip are intercepted;
    // everything below flows through the normal responder chain.

    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var tapDragCanvas: OverlayCanvasView?

    /// Run-loop modes to service the tap in — including the ones our own
    /// `runModal` / drag-tracking use, or the tap would go unanswered (and get
    /// auto-disabled) during capture.
    private static let tapModes: [CFRunLoopMode] = [
        .commonModes,
        CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString),
        CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString),
    ]

    private func installMouseTap() {
        guard AXIsProcessTrusted() else {
            Diag.capture.info("overlay mouse tap: Accessibility not granted — menu-bar-start selection unavailable (drag up into it still works)")
            return
        }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: overlayMouseTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Diag.capture.error("overlay mouse tap: CGEvent.tapCreate returned nil")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapRunLoopSource = src
        let main = CFRunLoopGetMain()
        for mode in Self.tapModes { CFRunLoopAddSource(main, src, mode) }
        CGEvent.tapEnable(tap: tap, enable: true)
        Diag.capture.info("overlay mouse tap installed")
    }

    private func removeMouseTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = tapRunLoopSource {
            let main = CFRunLoopGetMain()
            for mode in Self.tapModes { CFRunLoopRemoveSource(main, src, mode) }
        }
        eventTap = nil
        tapRunLoopSource = nil
        tapDragCanvas = nil
    }

    /// Runs on the main thread (the tap source is on the main run loop). Returns
    /// `nil` to swallow the event, or the event to pass it through.
    fileprivate func handleMouseTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)

        case .leftMouseDown:
            let g = cocoaGlobalPoint(from: event)
            guard let (canvas, point) = targetCanvasAndPoint(for: event) else {
                Diag.capture.info("tap ↓ (\(Int(g.x),privacy:.public),\(Int(g.y),privacy:.public)) → NO overlay window hit — frame doesn't contain the point")
                return Unmanaged.passRetained(event)
            }
            let strip = isInMenuBarStrip(event, canvas: canvas)
            let wants = canvas.wantsTapSelection(at: point)
            Diag.capture.info("tap ↓ (\(Int(g.x),privacy:.public),\(Int(g.y),privacy:.public)) strip=\(strip,privacy:.public) wants=\(wants,privacy:.public)")
            guard strip, wants else { return Unmanaged.passRetained(event) }
            tapDragCanvas = canvas
            canvas.beginTapSelection(at: point)
            return nil

        case .leftMouseDragged:
            guard let canvas = tapDragCanvas else { return Unmanaged.passRetained(event) }
            if let point = canvasPoint(for: event, in: canvas) { canvas.updateTapSelection(at: point) }
            return nil

        case .leftMouseUp:
            guard let canvas = tapDragCanvas else { return Unmanaged.passRetained(event) }
            canvas.endTapSelection()
            tapDragCanvas = nil
            return nil

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: Coordinate mapping (CGEvent global → canvas)

    /// CGEvent locations are top-left origin on the primary display; AppKit is
    /// bottom-left. Flip via the primary screen height.
    private func cocoaGlobalPoint(from event: CGEvent) -> CGPoint {
        let cg = event.location
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: cg.x, y: primaryHeight - cg.y)
    }

    private func targetCanvasAndPoint(for event: CGEvent) -> (OverlayCanvasView, CGPoint)? {
        let cocoa = cocoaGlobalPoint(from: event)
        // Inclusive edge test: a click jammed against the very top pixel row has
        // cocoa.y == frame.maxY, which `CGRect.contains` treats as OUTSIDE — so
        // those (very common: people shove the cursor to the top edge) fell
        // through this tap to the menu bar. Match all edges inclusively.
        guard let window = windows.first(where: { w in
            cocoa.x >= w.frame.minX && cocoa.x <= w.frame.maxX &&
            cocoa.y >= w.frame.minY && cocoa.y <= w.frame.maxY
        }) else { return nil }
        let windowBase = window.convertPoint(fromScreen: cocoa)
        return (window.canvas, window.canvas.convert(windowBase, from: nil))
    }

    private func canvasPoint(for event: CGEvent, in canvas: OverlayCanvasView) -> CGPoint? {
        guard let window = canvas.window else { return nil }
        let windowBase = window.convertPoint(fromScreen: cocoaGlobalPoint(from: event))
        return canvas.convert(windowBase, from: nil)
    }

    private func isInMenuBarStrip(_ event: CGEvent, canvas: OverlayCanvasView) -> Bool {
        guard let screen = canvas.window?.screen else { return false }
        let y = cocoaGlobalPoint(from: event).y
        return y > screen.visibleFrame.maxY && y <= screen.frame.maxY
    }
}

/// C callback for the overlay mouse tap. Fires on the main run loop, so the
/// main-actor controller state is safe to touch under `assumeIsolated`.
private func overlayMouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let controller = Unmanaged<OverlayController>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handleMouseTap(type: type, event: event) }
}

/// Borderless, non-activating panel covering exactly one screen.
///
/// A `.nonactivatingPanel` becomes the key window and receives mouse + keyboard
/// WITHOUT requiring this menu-bar (.accessory) app to win full activation —
/// the canonical Raycast/Alfred/Spotlight pattern. A plain `NSWindow` relies on
/// `NSApp.activate` succeeding before the user drags, which is racy on modern
/// macOS and drops the first drag ("first try fails, second works").
final class OverlayWindow: NSPanel {
    let canvas: OverlayCanvasView

    init(shot: DisplayShot) {
        canvas = OverlayCanvasView(shot: shot)
        super.init(
            contentRect: shot.screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.pinnedLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(shot.screen.frame, display: true)
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Pin the window level ABOVE the menu bar, permanently. `NSApp.runModal`
    /// silently demotes the modal window to `.modalPanel` (layer 8) — below the
    /// menu bar (24/25) — so the overlay rendered UNDER the live menu bar: a
    /// selection over the strip WORKED (tap + crop both included it) but looked
    /// un-selected because the bar drew on top. Measured via CGWindowList:
    /// layer=8; an async re-assert got demoted again. Refusing the demotion at
    /// the setter is the only reliable pin.
    private static let pinnedLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    override var level: NSWindow.Level {
        get { super.level }
        set { super.level = Self.pinnedLevel }
    }

    /// Never let AppKit shrink this overlay below the menu bar. When the app is
    /// in REGULAR activation mode (the AI-chat window flips it for ⌘Tab
    /// visibility), `setFrame` gets constrained to the visible frame — the
    /// overlay then stopped covering the menu bar and the selection clamped
    /// beneath it, silently breaking menu-bar capture. As an accessory app
    /// (yesterday's conditions) the constraint never applied, which is why this
    /// only surfaced today.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Esc anywhere in the overlay (incl. when a toolbar control has focus,
    /// which sends `cancelOperation:` up the responder chain) exits capture.
    override func cancelOperation(_ sender: Any?) {
        canvas.handleEscape()
    }
}
