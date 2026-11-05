import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreImage

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, used to match `SCDisplay`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case emptyRegion
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "未获得屏幕录制权限。"
        case .displayNotFound:
            return "找不到所选区域对应的显示器。"
        case .emptyRegion:
            return "选区为空。"
        case .captureFailed(let message):
            return "截图失败：\(message)"
        }
    }
}

/// Wraps ScreenCaptureKit for permission handling and single-frame region capture.
///
/// Permission is checked/requested through the CoreGraphics TCC entry points,
/// which are the canonical way to drive the "Screen Recording" privacy grant.
final class ScreenCapturer {

    // MARK: Permission

    /// Non-prompting check of the current screen-recording authorization.
    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for screen-recording access if it has not been granted yet.
    /// Returns whether access is granted afterwards.
    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Warm up ScreenCaptureKit at launch so the first real capture isn't delayed
    /// by the cold `SCShareableContent` query — otherwise the overlay appears
    /// noticeably late on the first shot (and the user re-presses the hotkey).
    func prewarm() {
        guard hasPermission() else { return }
        Task.detached {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    // MARK: Capture

    /// Captures a single frame of `sourceRect` (points, top-left origin relative
    /// to the display) at the display's backing scale.
    func captureRegion(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        scale: CGFloat,
        excludingWindowIDs: [CGWindowID] = []
    ) async throws -> CGImage {
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }
        guard hasPermission() else {
            throw CaptureError.permissionDenied
        }

        // NOTE(shadows): the filter path below re-composites windows WITHOUT
        // their shadows, so overlapping windows lose their visual boundary.
        // We tried `SCScreenshotManager.captureImage(in:)` (macOS 15.2+, system-
        // screenshot pipeline, shadows intact in standalone tests) but IN-APP it
        // broke capture entirely (frozen shot showed bare desktop) — reverted.
        // Revisit only with in-app verification; `ignoreShadowsDisplay=false`
        // also does not help (tested).
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let excluded = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // Frozen-shot path (macOS 14.2+, nothing excluded): ONE SCStream frame
        // with `includeMenuBar = true`. Verified headless, same-moment vs the
        // system pipeline: top strip identical (menu bar present) and full-image
        // diff shows only text noise (shadows present). The SCScreenshotManager
        // path below keeps the menu bar but drops window shadows; the earlier
        // stream attempt without `includeMenuBar` dropped the MENU BAR (its
        // default differs between stream and screenshot APIs) — that flag is
        // the whole story.
        if #available(macOS 14.2, *), excludingWindowIDs.isEmpty {
            filter.includeMenuBar = true
            let config = Self.makeConfig(sourceRect: sourceRect, scale: scale)
            return try await SingleFrameGrabber().grab(filter: filter, configuration: config)
        }

        return try await capture(filter: filter, sourceRect: sourceRect, scale: scale)
    }

    /// Builds a reusable content filter once (the expensive `SCShareableContent`
    /// query) — used by long capture so it isn't re-run on every frame.
    func makeFilter(
        displayID: CGDirectDisplayID,
        excludingWindowIDs: [CGWindowID] = []
    ) async throws -> SCContentFilter {
        guard hasPermission() else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let excluded = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        // Long capture grabs via SCStream, whose default drops the menu bar;
        // keep it so regions touching the top of the screen capture faithfully
        // (same flag the frozen-shot path sets, same macOS 14.2+ requirement).
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }
        return filter
    }

    /// Shared stream/screenshot configuration for a region at a given scale.
    private static func makeConfig(sourceRect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        // Snap the region to the display's physical pixel grid. Selection rects
        // come straight from mouse drags and are usually fractional; sampling a
        // fractional sourceRect makes ScreenCaptureKit bilinearly RESAMPLE every
        // frame (uniform softness, worst on long captures where every frame is
        // affected). Expanding outward keeps edge content while making the
        // sampling pixel-aligned.
        let pixel = 1.0 / max(1, scale)
        func snapDown(_ v: CGFloat) -> CGFloat { (v / pixel).rounded(.down) * pixel }
        func snapUp(_ v: CGFloat) -> CGFloat { (v / pixel).rounded(.up) * pixel }
        let snapped = CGRect(
            x: snapDown(sourceRect.minX),
            y: snapDown(sourceRect.minY),
            width: max(pixel, snapUp(sourceRect.maxX) - snapDown(sourceRect.minX)),
            height: max(pixel, snapUp(sourceRect.maxY) - snapDown(sourceRect.minY))
        )

        let config = SCStreamConfiguration()
        config.sourceRect = snapped
        config.width = max(1, Int((snapped.width * scale).rounded()))
        config.height = max(1, Int((snapped.height * scale).rounded()))
        config.showsCursor = false
        if #available(macOS 14.0, *) {
            config.scalesToFit = false
            config.captureResolution = .best
        }
        return config
    }

    /// Captures one frame using a pre-built filter (no per-frame system query).
    func capture(filter: SCContentFilter, sourceRect: CGRect, scale: CGFloat) async throws -> CGImage {
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }
        let config = Self.makeConfig(sourceRect: sourceRect, scale: scale)

        // SCStream single-frame — the SAME engine the frozen-shot path uses.
        // This used to go through `SCScreenshotManager.captureImage` (macOS 14+),
        // which honors the requested 2x output SIZE but samples the content at
        // 1x and bilinearly upscales — every long-capture frame came out soft
        // (visible as fat/blurry text vs. normal screenshots). Verified against
        // real stitched output on macOS 26.5.
        return try await SingleFrameGrabber().grab(filter: filter, configuration: config)
    }
}

/// Spins up a short-lived `SCStream` and resolves with the first complete
/// frame. Used by the frozen-shot path and by long capture (see
/// `capture(filter:sourceRect:scale:)` — `SCScreenshotManager` upscales from
/// 1x, so it is not used anywhere in this app).
private final class SingleFrameGrabber: NSObject, SCStreamOutput, @unchecked Sendable {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var finished = false
    private let ciContext = CIContext(options: nil)
    private let lock = NSLock()

    func grab(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                self.stream = stream
                try stream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "com.scrollshot.framegrabber")
                )
                stream.startCapture { [weak self] error in
                    if let error { self?.finish(.failure(error)) }
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard isComplete(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        finish(.success(cgImage))
    }

    /// Only act on frames whose status is `.complete`; dirty/idle frames are skipped.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let stream = self.stream
        self.stream = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        stream?.stopCapture { _ in }
        switch result {
        case .success(let image):
            continuation?.resume(returning: image)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
