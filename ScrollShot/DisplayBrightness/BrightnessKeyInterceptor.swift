import Cocoa
import CoreGraphics
import ApplicationServices
import IOKit

/// Intercepts the hardware brightness keys (F1/F2 as media keys) and routes them
/// to external displays via `M1DDCBrightnessController`.
///
/// Requires Accessibility permission. Uses a CGEventTap on system-defined events,
/// which is how macOS delivers brightness/volume/eject keys.
///
/// Note: this class no longer creates its own event tap. It registers as a
/// consumer with the shared `InputEventTap` router so only one global tap runs
/// for InputStats, KeyboardRemapper and BrightnessKeyInterceptor combined.
final class BrightnessKeyInterceptor {
    static let shared = BrightnessKeyInterceptor()
    private init() {}

    private let lock = NSLock()
    private static let enabledKey = "brightness.interceptBrightnessKeys"

    var isEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        }
        set {
            lock.lock()
            let wasEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            lock.unlock()

            if !wasEnabled && newValue {
                InputEventTap.shared.registerTapUser()
            } else if wasEnabled && !newValue {
                InputEventTap.shared.unregisterTapUser()
            }

            Diag.brightness.debug("BrightnessKeyInterceptor.isEnabled = \(newValue)")
        }
    }

    func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return Unmanaged.passRetained(event)
        }

        guard type.rawValue == UInt32(NX_SYSDEFINED),
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
            return Unmanaged.passRetained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8

        guard keyCode == NX_KEYTYPE_BRIGHTNESS_UP || keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN else {
            return Unmanaged.passRetained(event)
        }

        // 0x0A = key down, 0x0B = key up. Ignore repeats and up events.
        guard keyState == 0x0A else {
            return nil
        }

        if keyCode == NX_KEYTYPE_BRIGHTNESS_UP {
            M1DDCBrightnessController.shared.brightnessUp()
        } else {
            M1DDCBrightnessController.shared.brightnessDown()
        }

        // Consume the event so macOS doesn't also show the built-in OSD.
        return nil
    }
}
