import AppKit
import CoreGraphics

/// Input statistics event source: NSEvent global + local monitors.
///
/// This used to share the CGEventTap with the keyboard remapper, but on
/// macOS 26 every event delivered to a CGEventTap leaks inside SkyLight
/// (CGEvent + HIDEvent, verified 1:1 with a minimal repro — hundreds of MB
/// per day at mouse-move volume). NSEvent monitors do not leak, so all
/// listen-only input statistics now come from monitors; the CGEventTap is
/// reserved for features that must modify or consume events.
@MainActor
final class InputStatsEventMonitor {
    static let shared = InputStatsEventMonitor()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let mouseSampleInterval: TimeInterval = 1.0 / 30.0
    /// Accessed only on `batchQueue`.
    nonisolated(unsafe) private var lastMouseSampleTime: TimeInterval = 0
    /// Accessed only on `batchQueue`.
    nonisolated(unsafe) private var lastMouseLocation: NSPoint?

    /// Batches mouse-move samples on a background queue and flushes them to
    /// MainActor once every 100 ms. This avoids creating ~30 Task hops/s.
    private let batchQueue = DispatchQueue(label: "com.scrollshot.inputstats.batch")
    /// Accessed only on `batchQueue`.
    nonisolated(unsafe) private var pendingMouseDistance: CGFloat = 0
    /// Accessed only on `batchQueue`.
    nonisolated(unsafe) private var pendingMouseEnd: NSPoint?
    /// Accessed only on `batchQueue`.
    nonisolated(unsafe) private var batchTimer: DispatchSourceTimer?

    private init() {}

    /// Installs or removes the monitors to match `InputStatsSettings.enabled`.
    /// Global monitors require Accessibility permission; without it (like the
    /// old event tap) nothing is installed.
    func updateMonitors() {
        if InputStatsSettings.enabled, InputEventTap.shared.isAccessibilityGranted() {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown,
            .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Own-app events don't reach the global monitor; observe them locally
        // so typing into ScrollShot's own windows counts too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        batchQueue.async { [weak self] in
            self?.lastMouseLocation = nil
            self?.lastMouseSampleTime = 0
            self?.pendingMouseDistance = 0
            self?.pendingMouseEnd = nil
            self?.batchTimer?.cancel()
            self?.batchTimer = nil
        }
    }

    /// InputStats is listen-only: it never modifies or consumes the event.
    /// Heavy work is batched on a serial queue or offloaded via Task.
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let name = Self.keyName(for: Int64(event.keyCode))
            InputStatsStore.shared.recordKeyPress(keyName: name)

        case .leftMouseDown:
            InputStatsStore.shared.recordLeftClick()
        case .rightMouseDown:
            InputStatsStore.shared.recordRightClick()

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let loc = NSEvent.mouseLocation
            batchQueue.async { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastMouseSampleTime < self.mouseSampleInterval { return }
                self.lastMouseSampleTime = now
                if let last = self.lastMouseLocation {
                    let dx = loc.x - last.x
                    let dy = loc.y - last.y
                    self.pendingMouseDistance += hypot(dx, dy)
                }
                self.lastMouseLocation = loc
                self.pendingMouseEnd = loc
                self.scheduleBatchFlush()
            }

        case .scrollWheel:
            let distance = hypot(event.deltaX, event.deltaY)
            InputStatsStore.shared.recordScroll(delta: distance)

        default:
            break
        }
    }

    nonisolated private func scheduleBatchFlush() {
        guard batchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: batchQueue)
        timer.schedule(deadline: .now() + .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.flushMouseBatch()
        }
        timer.resume()
        batchTimer = timer
    }

    nonisolated private func flushMouseBatch() {
        let distance = pendingMouseDistance
        let end = pendingMouseEnd
        pendingMouseDistance = 0
        pendingMouseEnd = nil
        batchTimer = nil
        guard distance > 0, let end else { return }
        Task { @MainActor in
            InputStatsStore.shared.recordMouseMove(distance: distance, endPoint: end)
        }
    }

    /// A best-effort display name for a keycode. We intentionally do not try to
    /// map every key — just enough to make the key-breakdown list readable.
    nonisolated private static func keyName(for keyCode: Int64) -> String {
        switch keyCode {
        case 0:  return "A"
        case 1:  return "S"
        case 2:  return "D"
        case 3:  return "F"
        case 4:  return "H"
        case 5:  return "G"
        case 6:  return "Z"
        case 7:  return "X"
        case 8:  return "C"
        case 9:  return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 52: return "Enter"
        case 53: return "Esc"
        case 54: return "RightCmd"
        case 55: return "LeftCmd"
        case 56: return "LeftShift"
        case 57: return "CapsLock"
        case 58: return "LeftOption"
        case 59: return "LeftCtrl"
        case 60: return "RightShift"
        case 61: return "RightOption"
        case 62: return "RightCtrl"
        case 63: return "Fn"
        case 64: return "F17"
        case 65: return "Keypad."
        case 67: return "Keypad*"
        case 69: return "Keypad+"
        case 71: return "KeypadClear"
        case 72: return "VolumeUp"
        case 73: return "VolumeDown"
        case 74: return "Mute"
        case 75: return "Keypad/"
        case 76: return "KeypadEnter"
        case 78: return "Keypad-"
        case 79: return "F18"
        case 80: return "F19"
        case 81: return "Keypad="
        case 82: return "Keypad0"
        case 83: return "Keypad1"
        case 84: return "Keypad2"
        case 85: return "Keypad3"
        case 86: return "Keypad4"
        case 87: return "Keypad5"
        case 88: return "Keypad6"
        case 89: return "Keypad7"
        case 91: return "Keypad8"
        case 92: return "Keypad9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "ForwardDelete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PageDown"
        case 122: return "F1"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default: return "Key\(keyCode)"
        }
    }
}
