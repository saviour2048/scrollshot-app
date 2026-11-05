import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Runs a long (scroll) capture for an already-chosen region: shows the
/// bottom-left panel, grabs a frame every ~0.3 s while the user (manual) or the
/// app (auto) scrolls, stitches incrementally, and on 完成 opens the stitched
/// long image in the annotation editor.
@MainActor
final class LongCaptureController {
    static let shared = LongCaptureController()

    private let capturer = ScreenCapturer()
    private let stitcher = FrameStitcher()
    /// All `stitcher` access (add / result) happens here, off the main thread.
    private let stitchQueue = DispatchQueue(label: "com.scrollshot.stitch")

    private var panel: LongCapturePanel?
    private var timer: Timer?
    private var region: LongCaptureRegion?
    private var filter: SCContentFilter?   // built once per session (avoids per-frame system query)

    private var active = false
    private var auto = false
    private var didWarpCursor = false
    private var frameInFlight = false
    private var tickCount = 0
    private var noGrowthCount = 0
    private var escMonitorLocal: Any?
    private var escMonitorGlobal: Any?

    private let tickInterval: TimeInterval = 0.3
    private let autoStopIdleTicks = 6

    private init() {}

    func begin(region: LongCaptureRegion) {
        guard !active else { return }
        active = true
        auto = false
        didWarpCursor = false
        self.region = region
        let stitcher = self.stitcher
        stitchQueue.async { stitcher.reset() }   // serialized before any add
        tickCount = 0
        noGrowthCount = 0
        installEscapeHatch()

        let panel = LongCapturePanel()
        panel.onAuto = { [weak self] in self?.enableAuto() }
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.show(atBottomLeftOf: region.screen)
        self.panel = panel

        // Build the capture filter ONCE (excluding the panel), then start ticking.
        let excluded = panel.windowID.map { [$0] } ?? []
        Task { [weak self] in
            guard let self else { return }
            do {
                self.filter = try await self.capturer.makeFilter(
                    displayID: region.displayID,
                    excludingWindowIDs: excluded
                )
            } catch {
                NSLog("ScrollShot: makeFilter failed: \(error.localizedDescription)")
            }
            guard self.active else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    // MARK: Scrolling

    private func enableAuto() {
        guard active else { return }
        // Auto-scroll posts CGEvents, which the system silently drops unless the
        // app is trusted for Accessibility. If we're not trusted, scrolling would
        // do nothing and the user would just get a stub image — so surface it
        // clearly (prompt + open Settings) instead of failing silently.
        if !AutoScroller.isTrusted() {
            AutoScroller.requestTrust()                       // shows the system dialog
            NSWorkspace.shared.open(AppConfig.accessibilitySettingsURL ?? URL(fileURLWithPath: "/"))
            panel?.setAuto(false)
            panel?.note("自动滚动需要「辅助功能」权限。请在系统设置里打开 ScrollShot 开关,然后彻底退出并重新打开 ScrollShot —— 授权对正在运行的进程不会立即生效。期间可继续用滚轮手动滚动。")
            return
        }
        auto = true
        didWarpCursor = false
        noGrowthCount = 0
        panel?.setAuto(true)
        panel?.note("自动滚动中…按 Esc 或把鼠标移出选区即可停下,再点「完成/取消」。")
    }

    private func tick() {
        guard active else { return }
        captureFrame()
        if auto { performAutoScroll() }
    }

    private func performAutoScroll() {
        guard let region else { return }
        // Position the cursor over the region ONCE, then never grab it again —
        // so the user keeps control of the mouse and can click 完成/取消.
        if !didWarpCursor {
            AutoScroller.warp(toAppKitPoint: CGPoint(x: region.globalRect.midX, y: region.globalRect.midY))
            didWarpCursor = true
            return
        }
        // Only scroll while the cursor is still over the region. Moving the mouse
        // out (e.g. toward the panel) pauses auto-scroll — an easy escape.
        guard region.globalRect.contains(NSEvent.mouseLocation) else { return }
        let step = min(max(region.globalRect.height * 0.3, 60), 300)
        AutoScroller.postScrollDown(pixels: Int(step))
    }

    // MARK: Escape hatch

    private func installEscapeHatch() {
        // Esc cancels the session, whether ScrollShot or the scrolled app is active.
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
    }

    private func removeEscapeHatch() {
        [escMonitorLocal, escMonitorGlobal].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        escMonitorLocal = nil
        escMonitorGlobal = nil
    }

    // MARK: Capture

    private func captureFrame() {
        guard active, !frameInFlight, let region, let filter else { return }
        frameInFlight = true
        let stitcher = self.stitcher
        let sourceRect = region.sourceRect
        let scale = region.scale
        let isAuto = auto
        let showPreview = (tickCount % 2 == 0)
        tickCount += 1

        Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await self.capturer.capture(filter: filter, sourceRect: sourceRect, scale: scale)
                // Stitch off the main thread so scrolling / UI stays smooth.
                self.stitchQueue.async {
                    let grew = stitcher.add(frame)
                    let height = stitcher.totalHeight
                    let frames = stitcher.frameCount
                    let hitCap = !stitcher.canAccept
                    // The panel previews at ~208 pt wide (~416 px on a Retina
                    // display) — hand it a thumbnail, not the full frame.
                    let preview: NSImage?
                    if showPreview,
                       frame.width > 0,
                       let scaled = ImageUtils.scale(
                           frame,
                           width: 480,
                           height: max(1, Int((CGFloat(frame.height) * 480 / CGFloat(frame.width)).rounded())),
                           interpolation: .medium) {
                        preview = ImageUtils.nsImage(from: scaled)
                    } else {
                        preview = nil
                    }
                    Task { @MainActor in
                        self.frameInFlight = false
                        guard self.active else { return }
                        self.panel?.update(height: height, frames: frames, preview: preview)
                        if hitCap {
                            self.finish()   // hard cap: stop before strips eat memory
                        } else if isAuto {
                            self.checkAutoStop(grew: grew, frames: frames)
                        }
                    }
                }
            } catch {
                NSLog("ScrollShot: long capture frame failed: \(error.localizedDescription)")
                self.frameInFlight = false
            }
        }
    }

    private func checkAutoStop(grew: Bool, frames: Int) {
        guard frames > 2 else { return }
        noGrowthCount = grew ? 0 : (noGrowthCount + 1)
        if noGrowthCount >= autoStopIdleTicks { finish() }
    }

    // MARK: Finish / cancel

    private func finish() {
        guard active else { return }
        stopTimer()
        removeEscapeHatch()
        active = false
        let scale = region?.scale ?? 2
        let stitcher = self.stitcher
        panel?.close()
        panel = nil
        region = nil
        filter = nil

        // Compose on the stitch queue so any in-flight `add`s finish first.
        stitchQueue.async {
            let result = stitcher.result()
            stitcher.reset()   // release all intermediate frames after composition
            Task { @MainActor in
                guard let result else {
                    self.presentInfo("没有捕获到内容。请重试,记得向下滚动页面。")
                    return
                }
                AnnotationEditorWindowController.shared.open(image: result, scale: scale)
            }
        }
    }

    private func cancel() {
        guard active else { return }
        stopTimer()
        removeEscapeHatch()
        active = false
        panel?.close()
        panel = nil
        region = nil
        filter = nil

        // Discard any captured frames so memory returns to baseline.
        let stitcher = self.stitcher
        stitchQueue.async {
            stitcher.reset()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func presentInfo(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
