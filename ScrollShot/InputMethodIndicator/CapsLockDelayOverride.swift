import Foundation
import os

/// macOS intentionally delays Caps Lock activation — a quick tap is ignored,
/// only a slightly longer press toggles — to prevent accidental triggers.
/// `hidutil property --set '{"CapsLockDelayOverride":0}'` removes that delay
/// instantly (the value is nanoseconds; `null` restores the default), no
/// reboot needed. The override resets at reboot, so ScrollShot re-applies it
/// at launch while the toggle is on — the same "watchdog" pattern ExactMouse
/// uses for mouse acceleration.
enum CapsLockDelayOverride {
    private static let enabledKey = "capsLock.delayOverride"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Reads the live override (nanoseconds) back from hidutil; nil = system
    /// default. Used to show the user whether the change actually took effect.
    static func currentOverride() -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--get", "CapsLockDelayOverride"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("null") { return nil }
        // Output is either a bare number or "CapsLockDelayOverride:<ns>".
        guard let token = out.split(whereSeparator: { !($0 == "-" || $0.isNumber) }).first else { return nil }
        return Int(token)
    }

    /// Applies or clears the override right now (effective immediately).
    /// Call at launch and whenever the toggle flips.
    static func applyNow() {
        setOverride(isEnabled ? 0 : nil)
    }

    private static func setOverride(_ nanoseconds: Int?) {
        let value = nanoseconds.map(String.init) ?? "null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", "{\"CapsLockDelayOverride\":\(value)}"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Diag.inputSource.warning("hidutil CapsLockDelayOverride failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
