import Cocoa
import CoreGraphics
import ApplicationServices
import os

/// Global keyboard remapper using a CGEventTap.
///
/// Designed for the workflow: hold left ⌘ for native shortcuts like ⌘+Tab,
/// and use right ⌘ as a layer key so that hjkl produce plain arrow keys.
/// macOS `CGEventFlags` does not expose left/right Command publicly, but the
/// physical key codes on the `flagsChanged` events (55 = left, 54 = right)
/// let us track the two sides independently.
///
/// Note: this class no longer creates its own event tap. It registers as a
/// consumer with the shared `InputEventTap` router so only one global tap runs
/// for InputStats, KeyboardRemapper and BrightnessKeyInterceptor combined.
final class KeyboardRemapper {
    static let shared = KeyboardRemapper()
    private init() {}

    private let lock = NSLock()
    private var rules: [KeyMappingRule] = []

    // Physical modifier tracking.  Modifier keys are delivered primarily as
    // `flagsChanged` events; their keyCode tells us which side changed.
    private var leftCommandHeld = false
    private var rightCommandHeld = false

    /// Tracks keys currently being remapped so their key-up can be translated the
    /// same way. Key = physical key code; value = (injected key code, whether it
    /// was re-injected at the HID level vs. edited in place).
    private var heldMappings: [Int: (to: Int, viaHID: Bool)] = [:]

    /// Device-dependent modifier flag bits (IOKit `IOLLEvent.h`). Unlike
    /// `CGEventFlags.maskCommand` (one shared bit), these distinguish the two
    /// physical Command keys — essential when both are held at once.
    private static let deviceLeftCommand:  UInt64 = 0x8   // NX_DEVICELCMDKEYMASK
    private static let deviceRightCommand: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    /// Whether any rules are currently enabled. Used by the shared event router
    /// to decide whether to keep the global tap running.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !rules.isEmpty
    }

    /// Replace the active rule set. The shared `InputEventTap` is registered or
    /// unregistered automatically based on whether any rules are enabled.
    func update(rules: [KeyMappingRule]) {
        lock.lock()
        let wasActive = !self.rules.isEmpty
        self.rules = rules.filter { $0.isEnabled }
        let isActive = !self.rules.isEmpty
        lock.unlock()

        Diag.capture.info("KeyboardRemapper.update: \(self.rules.count, privacy: .public) enabled rule(s) → \(isActive ? "active" : "inactive", privacy: .public)")

        if !wasActive && isActive {
            InputEventTap.shared.registerTapUser()
        } else if wasActive && !isActive {
            InputEventTap.shared.unregisterTapUser()
        }
    }

    // MARK: - Event handling

    func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the OS disabled it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return Unmanaged.passRetained(event)
        }

        lock.lock()
        let currentRules = rules
        lock.unlock()

        guard !currentRules.isEmpty else {
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event, currentRules)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Read the CURRENT physical state of each Command key from the
        // device-dependent flag bits. Deciding "is right ⌘ down?" from the shared
        // `maskCommand` bit is wrong when both ⌘ keys are involved: releasing
        // right ⌘ while left ⌘ stays held leaves `maskCommand` set, which used to
        // leave `rightCommandHeld` stuck true (the user holds BOTH ⌘ keys).
        let raw = event.flags.rawValue
        let leftDown  = (raw & Self.deviceLeftCommand)  != 0
        let rightDown = (raw & Self.deviceRightCommand) != 0
        leftCommandHeld = leftDown
        rightCommandHeld = rightDown
        Diag.capture.debug("flagsChanged raw=0x\(raw, format: .hex, privacy: .public) L⌘=\(leftDown) R⌘=\(rightDown)")
        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown(_ event: CGEvent, _ currentRules: [KeyMappingRule]) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // Modifier keys themselves are handled via flagsChanged; swallow any
        // stray keyDown/keyUp for them so the system state stays clean.
        if keyCode == KeyCode.leftCommand.rawValue || keyCode == KeyCode.rightCommand.rawValue {
            return nil
        }

        // When right ⌘ is held, use it as a navigation layer.
        if rightCommandHeld {
            if let rule = currentRules.first(where: {
                $0.fromKeyCode == keyCode && $0.fromModifiers == .command
            }) {
                if leftCommandHeld {
                    // In the ⌘-Tab switcher (held open by LEFT ⌘): the switcher grabs
                    // nav keys UPSTREAM of this tap, so a pass-through edit goes to the
                    // app behind it. Re-inject the arrow at the HID level instead; the
                    // physically-held ⌘ supplies the Command the switcher needs.
                    // (Arrows aren't in any rule → re-injected event passes back
                    // through untouched, no loop.)
                    postArrow(rule.toKeyCode, keyDown: true)
                    heldMappings[keyCode] = (rule.toKeyCode, true)
                    Diag.capture.debug("remap↓ HID/switcher \(keyCode, privacy: .public)→\(rule.toKeyCode, privacy: .public)")
                    return nil
                }
                // Normal app (right ⌘ only): deliver the arrow to the focused app by
                // editing THIS event (keyCode + flags). Re-injecting at HID would let
                // the physically-held right ⌘ merge back in as ⌘+Arrow (= jump to
                // line start/end); a pass-through edit is NOT re-merged. We strip the
                // right-⌘ layer trigger but KEEP Shift/Option/Control, so
                // right ⌘+Shift+H → Shift+← extends the selection (multi-select),
                // right ⌘+Option+H → word move, etc.
                let outFlags = arrowFlags(from: event)
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(rule.toKeyCode))
                event.flags = outFlags
                heldMappings[keyCode] = (rule.toKeyCode, false)
                Diag.capture.debug("remap↓ inplace/app \(keyCode, privacy: .public)→\(rule.toKeyCode, privacy: .public) flags=0x\(outFlags.rawValue, format: .hex, privacy: .public)")
                return Unmanaged.passRetained(event)
            }

            // Not a mapped key: pass it through with Command so right-⌘+X/C/V/etc.
            // still work like normal Command shortcuts.
            var flags = event.flags
            flags.insert(.maskCommand)
            event.flags = flags
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == KeyCode.leftCommand.rawValue || keyCode == KeyCode.rightCommand.rawValue {
            return nil
        }

        if let m = heldMappings.removeValue(forKey: keyCode) {
            if m.viaHID {
                postArrow(m.to, keyDown: false)
                return nil
            }
            // Mirror the in-place key-down: arrow key-up to the focused app, with
            // the same modifiers-minus-Command.
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(m.to))
            event.flags = arrowFlags(from: event)
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }

    /// The event's modifier flags with ONLY the right-⌘ layer trigger removed
    /// (shared `maskCommand` + both device ⌘ bits). Shift / Option / Control are
    /// kept, so right ⌘+Shift+H → Shift+← (extend selection), right ⌘+Option+H →
    /// Option+← (word move), etc.
    private func arrowFlags(from event: CGEvent) -> CGEventFlags {
        let commandBits = CGEventFlags.maskCommand.rawValue
            | Self.deviceLeftCommand | Self.deviceRightCommand
        return CGEventFlags(rawValue: event.flags.rawValue & ~commandBits)
    }

    /// Re-injects an arrow keypress at the HID level so it re-enters like a physical
    /// key — the only way the ⌘-Tab switcher's upstream keyboard grab receives it.
    /// Used ONLY for the switcher path; the physically-held ⌘ merges back in to give
    /// the ⌘+Arrow the switcher navigates on.
    private func postArrow(_ keyCode: Int, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(keyCode),
                                  keyDown: keyDown) else { return }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
    }

}
