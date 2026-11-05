import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Switches between English and the user's most recently used CJK input mode
/// when a Shift key is tapped on its own — Karabiner-Elements' `to_if_alone`
/// idea: held as a modifier it does nothing; pressed and released alone
/// (within a timeout) it toggles the input source.
///
/// The toggle target mirrors macOS's own "switch to and from the last used
/// input source" semantics: whatever CJK input mode (简体拼音 / 繁体拼音 / …)
/// the user last had active, tracked via the TIS change notification — not a
/// fixed configured source.
///
/// Observation-only: events are never modified or consumed, so plain NSEvent
/// monitors are sufficient — and, unlike a CGEventTap, they don't leak every
/// delivered event on macOS 26 (see InputStatsEventMonitor).
@MainActor
final class ShiftInputToggle {
    static let shared = ShiftInputToggle()
    private init() {}

    /// Which physical Shift key(s) may act as the toggle.
    enum Side: String, CaseIterable, Identifiable {
        case left, right, any
        var id: String { rawValue }
        var titleKey: String { "settings.shiftToggle.side.\(rawValue)" }
    }

    private static let leftShift: Int64 = 56
    private static let rightShift: Int64 = 60

    /// Lone-tap timeout, mirroring Karabiner's
    /// `basic.to_if_alone_timeout_milliseconds` default (1000 ms): holding
    /// Shift longer than this arms nothing, so "press, think, release" never
    /// flips the input source.
    private static let maxHoldSeconds: TimeInterval = 1.0

    private var candidateKeyCode: Int64?
    private var candidateSince: TimeInterval = 0
    private var tisObserverRegistered = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isActive: Bool { InputSourceSettings.shiftToggleEnabled }

    /// Keeps the event monitors and the TIS observer running exactly while
    /// this feature is on. Call at launch and whenever the toggle flips.
    ///
    /// Uses NSEvent monitors, not the shared CGEventTap: every event delivered
    /// to a CGEventTap leaks inside SkyLight on macOS 26, and this listener is
    /// observe-only so a monitor covers everything it needs. Global monitors
    /// require Accessibility permission (same as the old tap).
    func updateRegistration() {
        if isActive, InputEventTap.shared.isAccessibilityGranted() {
            installMonitors()
            registerTISObserver()
        } else {
            removeMonitors()
            unregisterTISObserver()
        }
        candidateKeyCode = nil
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        // No scrollWheel in the mask: trackpad/mouse inertial scrolling keeps
        // emitting events for hundreds of ms after the gesture ends, and one
        // landing between Shift down/up used to void the candidate — a very
        // common "first tap does nothing" (scroll isn't a key chord anyway).
        // No keyUp either: only a key-DOWN during the hold proves Shift was a
        // modifier; key-ups only added false negatives.
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event) }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Last-used CJK source tracking

    private func registerTISObserver() {
        guard !tisObserverRegistered else { return }
        tisObserverRegistered = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ctx,
            { _, ctx, _, _, _ in
                guard let ctx else { return }
                let me = Unmanaged<ShiftInputToggle>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated { me.noteCurrentCJKSource() }
            },
            kTISNotifySelectedKeyboardInputSourceChanged as CFString,
            nil,
            .deliverImmediately
        )
        // Seed with whatever is active right now.
        noteCurrentCJKSource()
    }

    private func unregisterTISObserver() {
        guard tisObserverRegistered else { return }
        tisObserverRegistered = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
    }

    private func noteCurrentCJKSource() {
        guard InputSourceController.currentIsInputMode,
              let id = InputSourceController.currentInputSourceID else { return }
        InputSourceSettings.shiftToggleLastCJKSourceID = id
    }

    // MARK: - Event handling (observe-only)

    /// Called from the NSEvent monitors (main thread). Never consumes or
    /// edits the event.
    func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let keyCode = Int64(event.keyCode)
            guard isTriggerShift(keyCode) else {
                // Any other modifier/key activity voids the "alone" candidate.
                candidateKeyCode = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if event.modifierFlags.contains(.shift) {
                if candidateKeyCode == keyCode {
                    // 同一颗 Shift 重复下发 down(键盘/接收器重复上报、轴体抖动)
                    // 必须忽略:当成"按了第二个 Shift"会把这次点击作废。
                    return
                }
                if candidateKeyCode != nil, now - candidateSince < Self.maxHoldSeconds {
                    // A second Shift going down while the first is fresh = "not alone".
                    Diag.inputSource.info("Shift toggle: second shift \(keyCode, privacy: .public) voids")
                    candidateKeyCode = nil
                    return
                }
                // Fresh tap — or the previous candidate went STALE (its key-up
                // event was dropped/coalesced by the OS). Replacing the stale
                // candidate instead of voiding this tap: a lost key-up used to
                // poison the NEXT tap too ("需要按好几次才生效").
                candidateKeyCode = keyCode
                candidateSince = now
                Diag.inputSource.info("Shift toggle: candidate \(keyCode, privacy: .public)")
            } else {
                guard candidateKeyCode == keyCode else { return }
                let held = now - candidateSince
                candidateKeyCode = nil
                if held < Self.maxHoldSeconds {
                    Diag.inputSource.info("Shift toggle: tap \(Int(held * 1000), privacy: .public)ms")
                    toggleInputSource()
                } else {
                    Diag.inputSource.info("Shift toggle: held \(Int(held * 1000), privacy: .public)ms, ignored")
                }
            }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Any key-down / click while Shift is held makes it a modifier.
            // keyUp deliberately does NOT void: a dropped/duplicated key-up (or a
            // key released just after Shift went down) used to cancel valid taps.
            if candidateKeyCode != nil {
                Diag.inputSource.info("Shift toggle: voided by type=\(event.type.rawValue, privacy: .public) key=\(event.keyCode, privacy: .public)")
            }
            candidateKeyCode = nil
        default:
            break
        }
    }

    private func isTriggerShift(_ keyCode: Int64) -> Bool {
        guard keyCode == Self.leftShift || keyCode == Self.rightShift else { return false }
        switch InputSourceSettings.shiftToggleSide {
        case .left:  return keyCode == Self.leftShift
        case .right: return keyCode == Self.rightShift
        case .any:   return true
        }
    }

    private func toggleInputSource() {
        attemptToggle(before: InputSourceController.currentInputSourceID, retriesLeft: 2)
    }

    /// `TISSelectInputSource` can be silently ignored while an IME composition
    /// (候选窗) is open — verify the switch actually took effect and retry a
    /// couple of times; this is the "第一次按了没反应" fix at the action layer.
    private func attemptToggle(before: String?, retriesLeft: Int) {
        performToggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard InputSourceController.currentInputSourceID == before else { return }
                if retriesLeft > 0 {
                    self.attemptToggle(before: before, retriesLeft: retriesLeft - 1)
                } else {
                    Diag.inputSource.error("Shift toggle: switch ignored after retries, before=\(before ?? "nil", privacy: .public)")
                }
            }
        }
    }

    private func performToggle() {
        if InputSourceController.currentIsInputMode {
            // On a CJK input mode: remember it, then switch to English.
            InputSourceSettings.shiftToggleLastCJKSourceID = InputSourceController.currentInputSourceID
            guard let latin = InputSourceSettings.resolvedLatinSourceID else { return }
            Diag.inputSource.info("Shift toggle: CJK → \(latin, privacy: .public)")
            InputSourceController.selectInputSource(id: latin)
        } else {
            // On a Latin layout: switch back to the CJK input mode. Explicit
            // setting in Preferences wins over "last used" — a stale lastCJK
            // (e.g. 繁体拼音 from yesterday) used to hijack the toggle even
            // when the user had configured 简体拼音.
            let candidates = [
                InputSourceSettings.shiftToggleCJKSourceID,
                InputSourceSettings.shiftToggleLastCJKSourceID,
                InputSourceSettings.resolvedCJKSourceID,
            ].compactMap { $0 }
            for id in candidates {
                Diag.inputSource.info("Shift toggle: Latin → \(id, privacy: .public)")
                if InputSourceController.selectInputSource(id: id) { return }
            }
        }
    }
}
