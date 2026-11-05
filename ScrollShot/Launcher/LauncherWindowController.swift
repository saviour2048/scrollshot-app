import AppKit
import SwiftUI

/// The ⌥Space launcher window. Same NSPanel + keycode key-monitor pattern as the
/// clipboard picker (↑↓ / ⌥⌘-held J/K to move, ↵ to run, esc to back out / close).
@MainActor
final class LauncherWindowController {
    static let shared = LauncherWindowController()

    private var window: NSPanel?
    private var keyMonitor: Any?
    private let model: LauncherModel

    private init() {
        model = LauncherModel(commands: LauncherWindowController.builtInCommands())
        model.onRun = { [weak self] in self?.hide() }
    }

    func toggle() {
        if let w = window, w.isVisible { hide() } else { show() }
    }

    func show() {
        AppIndex.shared.buildIfNeeded()
        model.reset()
        // ONE window, reused forever (same stale-duplicate hazard as the
        // clipboard picker — see ClipboardWindowController.show()).
        if window == nil { window = makeWindow() }
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .scrollShotPickerFocus, object: nil)
        // AppKit-level focus pinning: on window reuse, SwiftUI's stale FocusState
        // can steal the field editor back right after AppKit restores it (the
        // "caret flashes then vanishes" bug). Force first responder onto the
        // search field, twice, to outlast any late SwiftUI pass.
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
        let root = LauncherView(model: model, onClose: { [weak self] in self?.hide() })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 640, height: 400))
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()   // hidesOnDeactivate can skip hide() — never stack monitors
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.window, event.window === panel else { return event }
                // While an input method is composing (marked text, e.g. pinyin),
                // EVERY key belongs to the IME — otherwise our Return handler
                // fires instead of committing the composition (user-reported:
                // typing Chinese hijacked ↵ into "run selected item").
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                let hasMod = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                switch event.keyCode {
                case 125: self.model.move(1);  return nil     // ↓
                case 126: self.model.move(-1); return nil     // ↑
                case 36, 76: self.model.submit(); return nil  // ↵
                case 53:                                       // Esc
                    if self.model.escape() { return nil }      // consumed (left arg mode)
                    self.hide(); return nil
                default:
                    guard hasMod else { return event }
                    switch event.keyCode {
                    case 38: self.model.move(1);  return nil   // ⌘/⌥ + J → down
                    case 40: self.model.move(-1); return nil   // ⌘/⌥ + K → up
                    case 4, 37: return nil                     // H / L → swallow
                    case 3:                                     // ⌘F → focus search
                        NotificationCenter.default.post(name: .scrollShotPickerFocus, object: nil)
                        self.pinFocusToSearchField()
                        return nil
                    default: return event
                    }
                }
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// ScrollShot's own actions + macOS system commands, exposed in the launcher.
    private static func builtInCommands() -> [LauncherCommand] {
        scrollShotCommands() + SystemCommands.all
    }

    private static func scrollShotCommands() -> [LauncherCommand] {
        [
            LauncherCommand(id: "llm", title: L("cmd.aiChat"),
                            systemImage: "bubble.left.and.text.bubble.right",
                            keywords: ["llm", "ai", "chat", "gpt", "claude", "deepseek", L("cmd.aiChat")]) {
                ChatWindowController.shared.show()
            },
            LauncherCommand(id: "capture", title: L("cmd.capture"),
                            systemImage: "camera.viewfinder", keywords: [L("cmd.capture"), "capture", "screenshot"]) {
                CaptureController.shared.trigger()
            },
            LauncherCommand(id: "clipboard", title: L("cmd.clipboard"),
                            systemImage: "doc.on.clipboard", keywords: [L("cmd.clipboard"), "clipboard", "paste"]) {
                ClipboardWindowController.shared.show()
            },
            LauncherCommand(id: "shelf", title: L("cmd.shelf"),
                            systemImage: "tray.and.arrow.down", keywords: [L("cmd.shelf"), "shelf", "yoink", "drag"]) {
                ShelfWindowController.shared.toggle()
            },
            LauncherCommand(id: "disk", title: L("cmd.disk"),
                            systemImage: "internaldrive", keywords: [L("cmd.disk"), "disk", "clean"]) {
                DiskScanWindowController.shared.open()
            },
            LauncherCommand(id: "prefs", title: L("cmd.preferences"),
                            systemImage: "gearshape", keywords: [L("cmd.preferences"), "settings", "prefs"]) {
                PreferencesWindowController.shared.show()
            },
            LauncherCommand(id: "translate", title: L("cmd.translate"),
                            systemImage: "character.bubble",
                            keywords: [L("cmd.translate"), "translate", "翻译", "fy"]) {
                TranslationWindowController.shared.show()
            },
        ]
    }
}
