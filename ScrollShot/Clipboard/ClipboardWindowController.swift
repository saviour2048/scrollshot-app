import AppKit
import SwiftUI

/// The ⌥⌘C search window. Remembers which app was frontmost so it can paste
/// back into it. A local keyDown monitor drives navigation by **keycode**, so
/// ↑↓ — and J/K while the invocation modifiers (⌥⌘) are still held — both move
/// the selection (the standard `moveDown:` selectors only fire for bare arrows).
@MainActor
final class ClipboardWindowController {
    static let shared = ClipboardWindowController()

    private var window: NSPanel?
    private var targetApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let model = ClipboardPickerModel()

    private init() {
        model.onChoose = { [weak self] item, plain in self?.paste(item, plain: plain) }
    }

    func toggle() {
        if let w = window, w.isVisible { hide() } else { show() }
    }

    func show() {
        targetApp = NSWorkspace.shared.frontmostApplication
        model.query = ""
        model.typeFilter = .all
        model.selected = 0
        // ONE window, reused forever. Recreating a panel per show left the old
        // hosting hierarchy around in some states — a stale window whose list
        // no longer updated ("左边是假的"), stacked under the live one.
        if window == nil { window = makeWindow() }
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .scrollShotPickerFocus, object: nil)
        // AppKit-level focus pinning — see LauncherWindowController.show().
        for delay in [0.06, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pinFocusToSearchField()
            }
        }
    }

    private func pinFocusToSearchField() {
        // This runs on a delay after show(); forcing first responder while the
        // panel is hiding or the field editor is mid-resign throws an
        // NSException in _newFirstResponderAfterResigning (crash 2026-07-15).
        guard let w = window, w.isVisible else { return }
        func findField(_ v: NSView?) -> NSTextField? {
            guard let v else { return nil }
            if let t = v as? NSTextField, t.isEditable { return t }
            for sub in v.subviews { if let f = findField(sub) { return f } }
            return nil
        }
        guard let field = findField(w.contentView), field.window === w else { return }
        if w.firstResponder === field { return }
        if let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
           (editor.delegate as? NSTextField) === field { return }
        w.makeFirstResponder(field)
    }

    func hide() {
        removeKeyMonitor()
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let root = ClipboardHistoryView(model: model, onClose: { [weak self] in self?.hide() })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true      // dismiss when the user clicks away
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 720, height: 460))
        return panel
    }

    // MARK: Keyboard navigation

    private func installKeyMonitor() {
        removeKeyMonitor()   // hidesOnDeactivate can skip hide() — never stack monitors
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.window, event.window === panel else { return event }
                // IME composing (marked text): every key belongs to the input
                // method — don't hijack ↵/JK from a pinyin composition.
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                let hasMod = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                let cmd = event.modifierFlags.contains(.command)
                switch event.keyCode {
                case 125: self.model.move(1);  return nil     // ↓
                case 126: self.model.move(-1); return nil     // ↑
                case 36, 76: self.model.choose(plain: cmd); return nil  // ↵ 粘贴 / ⌘↵ 纯文本
                case 53: self.hide(); return nil              // Esc
                default:
                    guard hasMod else { return event }
                    switch event.keyCode {
                    case 38: self.model.move(1);  return nil   // ⌘/⌥ + J → down
                    case 40: self.model.move(-1); return nil   // ⌘/⌥ + K → up
                    case 4, 37: return nil                     // H / L → swallow (⌘H = Hide, etc.)
                    default: break
                    }
                    if cmd {
                        switch event.keyCode {
                        case 51: self.model.deleteSelected(); return nil  // ⌘⌫ → delete
                        case 35: self.model.pinSelected();    return nil  // ⌘P → pin
                        case 3:                                            // ⌘F → focus search
                            NotificationCenter.default.post(name: .scrollShotPickerFocus, object: nil)
                            self.pinFocusToSearchField()
                            return nil
                        default: break
                        }
                    }
                    return event
                }
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: Paste

    private func paste(_ item: ClipboardItem, plain: Bool = false) {
        hide()
        ClipboardMonitor.shared.writeToPasteboard(item, asPlainText: plain)
        // Return focus to where the user was, then press ⌘V for them.
        targetApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.pressCommandV() }
    }

    /// Synthesize ⌘V (needs Accessibility — already granted for the remapper).
    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
