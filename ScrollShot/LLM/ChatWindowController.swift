import AppKit
import SwiftUI

/// Hosts the AI chat in its own window. While the chat is open the app runs as
/// a REGULAR app (Dock icon + ⌘Tab) so the window is findable like any other
/// app; back to accessory when it closes. The window frame is autosaved, so
/// position/size survive reopen and relaunch.
///
/// Keyboard: ⌘N new session, ⌘↑/⌘↓ walk the sessions sidebar. Only ⌘-chords are
/// intercepted, so IME composition in the input is untouched.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    static let shared = ChatWindowController()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private static let frameName = "ScrollShot.ChatWindow"
    private override init() { super.init() }

    func show() {
        NSApp.setActivationPolicy(.regular)      // visible in ⌘Tab while open
        NSApp.activate(ignoringOtherApps: true)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ChatView()))
            w.title = "AI 对话"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 560))
            w.minSize = NSSize(width: 660, height: 420)
            // Restore the user's last position/size; center only the first time.
            let restored = w.setFrameUsingName(Self.frameName)
            w.setFrameAutosaveName(Self.frameName)
            if !restored { w.center() }
            w.delegate = self
            window = w
        }
        // Every entry starts a fresh session; the old ones stay in the sidebar.
        ChatStore.shared.beginFreshSession()
        installKeyMonitor()
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        // Focus the input so the user can type immediately.
        NotificationCenter.default.post(name: .scrollShotChatFocus, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        // Drop back to a menu-bar-only app.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Keyboard (⌘-chords only — IME-safe)

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, event.window === w else { return event }
                // IME composing → every key belongs to the input method.
                if let tv = w.firstResponder as? NSTextView, tv.hasMarkedText() { return event }
                let cmd = event.modifierFlags.contains(.command)
                switch event.keyCode {
                case 45 where cmd:                         // ⌘N → new session
                    ChatStore.shared.beginFreshSession()
                    NotificationCenter.default.post(name: .scrollShotChatFocus, object: nil)
                    return nil
                case 126, 125:                             // ↑ / ↓
                    if cmd {                               // ⌘↑↓ always switch sessions
                        self.switchSession(event.keyCode == 126 ? -1 : 1)
                        return nil
                    }
                    // Plain arrows, Telegram/Discord-style dual behavior: while
                    // the input has TEXT they edit the text (caret/lines); when
                    // it's EMPTY they walk the sessions sidebar — no modifier
                    // needed, both cases covered.
                    if let tv = w.firstResponder as? NSTextView, !tv.string.isEmpty { return event }
                    self.switchSession(event.keyCode == 126 ? -1 : 1)
                    return nil
                default: return event
                }
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Walk the sidebar (recents order: newest first) up/down from the current.
    private func switchSession(_ delta: Int) {
        let list = ChatStore.shared.recents
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == ChatStore.shared.currentID } ?? 0
        let next = min(max(0, idx + delta), list.count - 1)
        ChatStore.shared.select(list[next].id)
    }
}
