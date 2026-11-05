import AppKit
import CoreGraphics
import os

/// Lightweight structured logging for diagnosing permission / capture issues.
/// View live with: `log stream --predicate 'subsystem == "com.scrollshot.app"'`
/// or Console.app (filter subsystem `com.scrollshot.app`).
enum Diag {
    static let permission = Logger(subsystem: "com.scrollshot.app", category: "permission")
    static let capture = Logger(subsystem: "com.scrollshot.app", category: "capture")
    static let brightness = Logger(subsystem: "com.scrollshot.app", category: "brightness")
    static let inputSource = Logger(subsystem: "com.scrollshot.app", category: "inputSource")
    static let battery = Logger(subsystem: "com.scrollshot.app", category: "battery")
}

/// Top-level orchestrator for the Flameshot-style flow:
/// hotkey/menu → check permission → freeze every display → show overlay →
/// save to Desktop + copy to clipboard.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private let capturer = ScreenCapturer()
    private let overlay = OverlayController()
    private var isRunning = false

    private init() {}

    func trigger() {
        guard !isRunning else {
            Diag.capture.debug("trigger ignored: a capture is already in progress")
            return
        }
        Diag.capture.info("capture triggered")
        isRunning = true
        Task { [weak self] in
            await self?.run()
            self?.isRunning = false
        }
    }

    /// Pre-warm ScreenCaptureKit so the first capture is fast (call once at launch).
    func prewarm() { capturer.prewarm() }

    private func run() async {
        guard await ensurePermission() else { return }

        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let fullRect = CGRect(origin: .zero, size: screen.frame.size)
            do {
                let image = try await capturer.captureRegion(
                    displayID: displayID,
                    sourceRect: fullRect,
                    scale: screen.backingScaleFactor
                )
                shots.append(DisplayShot(screen: screen, image: image))
            } catch {
                NSLog("ScrollShot: failed to capture display \(displayID): \(error.localizedDescription)")
            }
        }

        guard !shots.isEmpty else {
            Diag.capture.notice("no display shots captured — overlay not shown (permission?)")
            return
        }
        Diag.capture.info("captured \(shots.count, privacy: .public) display(s) → presenting overlay")
        let result = overlay.runModal(shots: shots)
        finish(with: result)
    }

    private func finish(with result: OverlayResult) {
        switch result {
        case .cancelled:
            break
        case let .image(image):
            ImageUtils.copyToPasteboard(image)
            do {
                let url = try ImageUtils.saveToDesktop(image)
                NSLog("ScrollShot: saved \(url.path)")
            } catch {
                presentError("保存到桌面失败：\(error.localizedDescription)")
            }
        case let .longCapture(region):
            // Overlay has dismissed; hand off to scroll capture.
            LongCaptureController.shared.begin(region: region)
        }
    }

    // MARK: Permission

    private func ensurePermission() async -> Bool {
        if capturer.hasPermission() {
            Diag.permission.info("screen-recording preflight = granted → capture proceeds")
            return true
        }
        // Only reached when macOS reports no grant for THIS binary's signing
        // identity — this is what triggers the system "Screen Recording" prompt.
        if AppConfig.suppressesPermissionPrompts {
            Diag.permission.notice("screen-recording preflight = NOT granted — prompt suppressed by SCROLLSHOT_SKIP_PERMISSION_PROMPTS")
            return false
        }
        Diag.permission.notice("screen-recording preflight = NOT granted → CGRequestScreenCaptureAccess (system prompt shown)")
        capturer.requestPermission()
        let granted = capturer.hasPermission()
        Diag.permission.notice("after prompt: preflight granted = \(granted, privacy: .public) (a fresh grant only takes effect after relaunch)")
        if granted { return true }
        presentPermissionAlert()
        return false
    }

    private func presentPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "请在 系统设置 ▸ 隐私与安全性 ▸ 屏幕录制 勾选 ScrollShot，然后重新运行 App。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = AppConfig.screenRecordingSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A single display's frozen screenshot plus the screen it belongs to.
struct DisplayShot {
    let screen: NSScreen
    let image: CGImage
}
