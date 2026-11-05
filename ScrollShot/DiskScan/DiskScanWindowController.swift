import AppKit
import SwiftUI

/// Hosts the disk-cleanup window: a Liquid Glass window wrapping the SwiftUI
/// `DiskScanView`. Independent of the screenshot flow (HANDOFF.md §7). Reuses
/// the same window (and scan results) across reopens.
///
/// While the window is open the app temporarily becomes a regular (Dock) app so
/// the user can switch back to it after visiting System Settings — a menu-bar
/// `.accessory` app's window has no Dock icon / Cmd-Tab slot to return to.
@MainActor
final class DiskScanWindowController: NSObject, NSWindowDelegate {
    static let shared = DiskScanWindowController()

    private var window: NSWindow?
    private let scanner = DiskScanner()

    private override init() { super.init() }

    func open() {
        if let window {
            showInDock()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingView(rootView: DiskScanView(scanner: scanner))
        host.translatesAutoresizingMaskIntoConstraints = false

        // Liquid Glass window background (glass on Tahoe; vibrancy on older).
        let glass = NSVisualEffectView()
        glass.material = .windowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(glass)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrollShot · 磁盘清理"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Show a Dock icon (regular app) while the cleanup window is up, so the user
    /// can return to it via Dock / Cmd-Tab after a detour to System Settings.
    private func showInDock() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only when the cleanup window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}
