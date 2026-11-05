import AppKit
import IOKit
import IOKit.hidsystem

/// Disables macOS pointer acceleration for precise control, with an adjustable
/// tracking speed.
///
/// On-device investigation (2026-07-20): the floaty feel ("发飘") was NOT the
/// acceleration curve — the per-service `HIDUseLinearScalingMouseAcceleration`
/// write below does switch the curve off (approach borrowed from LinearMouse,
/// MIT). The floatiness came from a ~9× tracking speed
/// (HIDMouseAcceleration ≈ 6.18, likely set by Logi Options+): with the curve
/// off, high speed feels floaty while the system default (0.6875) feels slow.
/// Hence the speed slider — the curve stays off, speed is the user's choice.
///
/// Follow-up (2026-08-03, macOS 26.5 on-device + apple-oss-distributions
/// IOHIDFamily source):
/// - On macOS 26 the linear-scaling key is **create-on-write** — absent from
///   the registry until first set. The old existence check therefore rejected
///   every device and the feature silently did nothing (the legacy global API
///   is deprecated and inert: IOHIDGetMouseAcceleration reads 0.0).
/// - Semantics (IOHIDPointerScrollFilter/IOHIDAcceleration.cpp): linear
///   scaling installs a fixed-gain accelerator multiplying every delta by the
///   tracking-speed value — so 0.6875 is NOT raw 1:1; the filter bypasses
///   completely only when the multiplier is exactly 1.0 (or the value is -1,
///   which skips node creation altogether — the ExactMouse feel).
/// - The speed is written per-device (device-level properties override the
///   global one, which Logi Options+ also writes) as well as globally.
///
/// Devices lacking the linear-scaling property (pre-Sonoma) fall back to the
/// legacy global `IOHIDSetMouseAcceleration(-1)`. macOS re-applies its
/// defaults on wake and on device (re)connect, so we re-apply on those events
/// only — no periodic timer.
@MainActor
final class MouseAccelerationController {
    static let shared = MouseAccelerationController()

    /// Per-service HID property (Sonoma+): 1 = linear scaling (accel off).
    private static let linearScalingKey = "HIDUseLinearScalingMouseAcceleration" as CFString
    /// macOS default tracking speed (0.6875).
    private static let defaultAcceleration = 0.6875
    private static let legacyDisabledValue = -1.0

    private var wakeObserver: NSObjectProtocol?
    /// Hotplug watch via pure IOKit registry notifications — deliberately NOT
    /// IOHIDManager: every `IOHIDDeviceOpen` leaks a `GPProcessMonitor` (plus an
    /// XPC connection to gamepolicyd) inside IOHIDLib on macOS 26, which over
    /// weeks of uptime pinned ScrollShot at ~800 MB / 8000+ Mach ports.
    private var hotplugPort: IONotificationPortRef?
    private var hotplugIterator: io_iterator_t = 0
    /// True when at least one device accepted the linear-scaling property on
    /// the last apply — only then is the tracking-speed setting meaningful
    /// (the legacy fallback forces sensitivity off anyway).
    private var linearScalingActive = false

    private init() {}

    // MARK: Settings

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mouseAccel.disableAcceleration") }
        set { UserDefaults.standard.set(newValue, forKey: "mouseAccel.disableAcceleration") }
    }

    /// Tracking speed while acceleration is off, in `IOHIDSetMouseAcceleration`
    /// units (system default ≈ 0.6875; higher = faster).
    static var speed: Double {
        get { UserDefaults.standard.object(forKey: "mouseAccel.speed") as? Double ?? defaultAcceleration }
        set { UserDefaults.standard.set(newValue, forKey: "mouseAccel.speed") }
    }

    /// Whether ScrollShot manages the tracking speed at all. Stays false until
    /// the user drags the slider once — so speed can be left to the system or
    /// tools like Logi Options+ while we only disable the curve.
    static var speedCustomized: Bool {
        get { UserDefaults.standard.bool(forKey: "mouseAccel.speedCustomized") }
        set { UserDefaults.standard.set(newValue, forKey: "mouseAccel.speedCustomized") }
    }

    /// The acceleration to restore when the feature is turned off (captured once,
    /// before we first disable, so we give the user their original feel back).
    private static var restoreValue: Double {
        get {
            let v = UserDefaults.standard.object(forKey: "mouseAccel.restoreValue") as? Double
            return (v ?? defaultAcceleration) > 0 ? (v ?? defaultAcceleration) : defaultAcceleration
        }
        set { UserDefaults.standard.set(newValue, forKey: "mouseAccel.restoreValue") }
    }

    // MARK: Lifecycle

    /// Apply the persisted setting. Call at launch and whenever the toggle flips.
    func reload() {
        if Self.enabled {
            captureRestoreValueIfNeeded()
            apply()
            startWatching()
        } else {
            stopWatching()
            restore()
        }
    }

    // MARK: Apply / restore

    private func apply() {
        var supportedAny = false
        forEachMouseService { service in
            // Write unconditionally. On Sonoma the key pre-exists; on macOS 26
            // it is create-on-write (absent until first set), so the old
            // "exists → supported" check disqualified every device and the
            // feature silently fell through to the dead legacy path.
            if IORegistryEntrySetCFProperty(service, Self.linearScalingKey, 1 as CFNumber) == KERN_SUCCESS {
                supportedAny = true
            }
        }
        linearScalingActive = supportedAny
        if supportedAny {
            // Curve off via linear scaling. Speed only if the user asked us to
            // manage it (otherwise leave it to the system / Logi Options+).
            if Self.speedCustomized { setTrackingSpeed(Self.speed) }
        } else {
            // Pre-Sonoma fallback: legacy global disable (curve + sensitivity).
            setGlobalAcceleration(Self.legacyDisabledValue)
        }
    }

    /// Live-applies the tracking speed (settings slider) and marks speed as
    /// managed by ScrollShot from now on. No-op while the legacy fallback is
    /// active, where sensitivity is forced off anyway.
    func applyTrackingSpeed() {
        Self.speedCustomized = true
        guard Self.enabled, linearScalingActive else { return }
        setTrackingSpeed(Self.speed)
    }

    private func restore() {
        forEachMouseService { service in
            // Same rationale as apply(): write unconditionally (macOS 26
            // create-on-write), otherwise a feature toggle-off would leave
            // linear scaling stuck on.
            if IORegistryEntrySetCFProperty(service, Self.linearScalingKey, 0 as CFNumber) == KERN_SUCCESS {
                IORegistryEntrySetCFProperty(service, Self.accelerationValueKey(service), Self.restoreValue as CFNumber)
            }
        }
        linearScalingActive = false
        // Always restore the global value too, in case the legacy fallback (or
        // an older ScrollShot build) left it disabled.
        setGlobalAcceleration(Self.restoreValue)
    }

    /// Writes the tracking speed per-device AND globally. Per-device wins over
    /// the global value in the HID event filter, and device-level writers
    /// (Logi Options+) would otherwise override us.
    private func setTrackingSpeed(_ value: Double) {
        forEachMouseService { service in
            IORegistryEntrySetCFProperty(service, Self.accelerationValueKey(service), value as CFNumber)
        }
        setGlobalAcceleration(value)
    }

    /// The per-device key holding the acceleration/tracking-speed value —
    /// `HIDPointerAccelerationType` names it (normally "HIDMouseAcceleration").
    private static func accelerationValueKey(_ service: io_service_t) -> CFString {
        if let raw = IORegistryEntryCreateCFProperty(service, "HIDPointerAccelerationType" as CFString, kCFAllocatorDefault, 0),
           let type = raw.takeRetainedValue() as? String, !type.isEmpty {
            return type as CFString
        }
        return "HIDMouseAcceleration" as CFString
    }

    private func captureRestoreValueIfNeeded() {
        guard UserDefaults.standard.object(forKey: "mouseAccel.restoreValue") == nil else { return }
        var current = Self.defaultAcceleration
        if getGlobalAcceleration(&current), current > 0 {
            Self.restoreValue = current
        } else {
            Self.restoreValue = Self.defaultAcceleration
        }
    }

    // MARK: Event-driven re-apply (wake + hotplug; no timer)

    private func startWatching() {
        stopWatching()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }

        // Registry-only arrival notification (no device open → no IOHIDLib leak).
        let port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           CFRunLoopMode.defaultMode)
        var iterator: io_iterator_t = 0
        let kr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
            { _, iterator in
                // A (re)connected device comes up with the system default curve.
                var drained = false
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                    drained = true
                }
                if drained {
                    MainActor.assumeIsolated { MouseAccelerationController.shared.apply() }
                }
            }, nil, &iterator)
        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        // Drain the initial arm set synchronously; reload() already applied.
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
        hotplugPort = port
        hotplugIterator = iterator
    }

    private func stopWatching() {
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        if hotplugIterator != 0 {
            IOObjectRelease(hotplugIterator)
            hotplugIterator = 0
        }
        if let p = hotplugPort {
            IONotificationPortDestroy(p)
            hotplugPort = nil
        }
    }

    // MARK: IOKit plumbing

    /// Enumerates the io_service_t of every attached USB/Bluetooth mouse using
    /// the IOKit registry only — never `IOHIDDeviceOpen` (see `hotplugPort`).
    private func forEachMouseService(_ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if Self.isMouseService(service) { body(service) }
            IOObjectRelease(service)
        }
    }

    /// A HID service counts as a mouse when its primary (or any listed) usage is
    /// GenericDesktop / Mouse — the same set the old IOHIDManager matching found.
    private static func isMouseService(_ service: io_service_t) -> Bool {
        func intProperty(_ key: String) -> Int? {
            guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
                return nil
            }
            return (raw.takeRetainedValue() as? NSNumber)?.intValue
        }
        let page = Int(kHIDPage_GenericDesktop), usage = Int(kHIDUsage_GD_Mouse)
        if intProperty("PrimaryUsagePage") == page, intProperty("PrimaryUsage") == usage {
            return true
        }
        guard let raw = IORegistryEntryCreateCFProperty(service, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0),
              let pairs = raw.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        return pairs.contains {
            ($0["DeviceUsagePage"] as? NSNumber)?.intValue == page
                && ($0["DeviceUsage"] as? NSNumber)?.intValue == usage
        }
    }

    private func setGlobalAcceleration(_ value: Double) {
        withParamConnection { conn in
            IOHIDSetMouseAcceleration(conn, value)
        }
    }

    private func getGlobalAcceleration(_ out: inout Double) -> Bool {
        var ok = false
        withParamConnection { conn in
            ok = IOHIDGetMouseAcceleration(conn, &out) == KERN_SUCCESS
        }
        return ok
    }

    private func withParamConnection(_ body: (io_connect_t) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS else { return }
        defer { IOServiceClose(conn) }
        body(conn)
    }
}
