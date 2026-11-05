import AppKit
import SwiftUI

/// Hosts `PreferencesView` in an AppKit window we fully control.
///
/// The SwiftUI `Settings` scene can only be opened from AppKit via the private
/// `showSettingsWindow:` selector, which stopped working on recent macOS — so
/// "偏好设置…" opened nothing. Hosting the same SwiftUI view in our own NSWindow
/// via `NSHostingController` sidesteps that entirely and works on every version.
@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private init() {}

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let w = NSWindow(contentViewController: hosting)
            w.title = L("settings.title")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 800, height: 600))
            w.center()
            window = w
        }
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
