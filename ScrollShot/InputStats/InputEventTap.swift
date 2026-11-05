import Foundation
import CoreGraphics
import AppKit

/// Shared low-level global keyboard tap using CGEventTap.
///
/// On macOS 26 every event delivered to a CGEventTap leaks inside SkyLight
/// (CGEvent + HIDEvent objects, verified 1:1 with a 20-line repro). NSEvent
/// global monitors do NOT leak. This tap therefore carries ONLY the events
/// that must be modified or consumed — keyboard events for KeyboardRemapper,
/// SmartPasteController and NX_SYSDEFINED for BrightnessKeyInterceptor. Listen-only consumers
/// (InputStats, ShiftInputToggle) use NSEvent monitors instead.
///
/// Requires Accessibility permission.
@MainActor
final class InputEventTap {
    nonisolated(unsafe) static let shared = InputEventTap()

    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()

    /// Keyboard for the remapper, system-defined for brightness/media keys.
    /// No mouse/scroll events: each delivered event leaks ~1 KB on macOS 26,
    /// and mouse-move volume alone was hundreds of MB per day.
    nonisolated private static let eventMask: CGEventMask = {
        let keyboard: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                  | (1 << CGEventType.keyUp.rawValue)
                                  | (1 << CGEventType.flagsChanged.rawValue)
        let sysDefined: CGEventMask = (1 << UInt32(NX_SYSDEFINED))
        return keyboard | sysDefined
    }()

    var isRunning: Bool { tap != nil }

    /// Reference count for modules that need the shared event tap.
    /// KeyboardRemapper, SmartPasteController and BrightnessKeyInterceptor each
    /// register independently so the tap only runs while at least one feature is active.
    nonisolated(unsafe) private var tapUsers = 0

    nonisolated private init() {}

    /// Call when a module starts needing the global event tap.
    nonisolated func registerTapUser() {
        lock.lock(); defer { lock.unlock() }
        tapUsers += 1
        if tapUsers == 1 {
            if !startLocked() {
                tapUsers = 0
            }
        }
    }

    /// Call when a module stops needing the global event tap.
    nonisolated func unregisterTapUser() {
        lock.lock(); defer { lock.unlock() }
        guard tapUsers > 0 else { return }
        tapUsers -= 1
        if tapUsers == 0 {
            stopLocked()
        }
    }

    /// Whether the user has granted Accessibility access to this app.
    nonisolated func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Show the system Accessibility permission prompt and register this app
    /// in Privacy & Security > Accessibility.
    @discardableResult
    nonisolated func promptAccessibilityTrust() -> Bool {
        guard !AppConfig.suppressesPermissionPrompts else {
            Diag.permission.notice("accessibility prompt suppressed by SCROLLSHOT_SKIP_PERMISSION_PROMPTS")
            return false
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Start the global tap. Returns true on success, false if accessibility is denied.
    @discardableResult
    nonisolated func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return startLocked()
    }
    nonisolated private func startLocked() -> Bool {
        guard tap == nil else { return true }
        guard isAccessibilityGranted() else { return false }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<InputEventTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        // .defaultTap because KeyboardRemapper and BrightnessKeyInterceptor
        // need to modify or consume events.
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: ctx
        ) else { return false }
        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }


    nonisolated func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    nonisolated private func stopLocked() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passRetained(event)
        }

        // 1. Keyboard remapping (may modify or consume the event).
        var currentEvent = event
        if KeyboardRemapper.shared.isActive {
            if let result = KeyboardRemapper.shared.handleEvent(currentEvent, type: type) {
                currentEvent = result.takeRetainedValue()
            } else {
                return nil
            }
        }

        // 2. Brightness key interception (only system-defined media keys).
        if BrightnessKeyInterceptor.shared.isEnabled,
           type.rawValue == UInt32(NX_SYSDEFINED) {
            if let result = BrightnessKeyInterceptor.shared.handleEvent(currentEvent, type: type) {
                currentEvent = result.takeRetainedValue()
            } else {
                return nil
            }
        }

        // 3. Smart paste (Ctrl+V → Cmd+V for text in terminals; only keyDown).
        if type == .keyDown, SmartPasteController.shared.isActive {
            if let result = SmartPasteController.shared.handleEvent(currentEvent, type: type) {
                currentEvent = result.takeRetainedValue()
            } else {
                return nil
            }
        }

        return Unmanaged.passRetained(currentEvent)
    }
}
