import SwiftUI
import AppKit
import Combine

/// Owns the notch panel: hidden (orderOut) while AgentBridgeStore has no
/// pending requests, springs the topmost card out of the notch when one
/// arrives, retracts and hides when the queue drains. Rebuilt when screen
/// parameters change (display (un)plugged, resolution change).
@MainActor
final class NotchPanelController {
    static let shared = NotchPanelController()

    private var window: NotchWindow?
    private var hostingView: NSHostingView<NotchRootView>?
    private var pendingCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func start() {
        guard pendingCancellable == nil else { return }
        rebuildWindow()
        pendingCancellable = AgentBridgeStore.shared.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                self?.updateVisibility(hasPending: !pending.isEmpty)
            }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindow() }
        }
    }

    func stop() {
        pendingCancellable?.cancel()
        pendingCancellable = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }

    // MARK: - Private

    private func rebuildWindow() {
        guard let geometry = NotchGeometry.current() else { return }
        let wasVisible = window?.isVisible ?? false
        let view = NotchRootView(store: AgentBridgeStore.shared, geometry: geometry)
        let hosting = NSHostingView(rootView: view)
        let newWindow = NotchWindow(contentRect: geometry.panelFrame)
        newWindow.contentView = hosting
        newWindow.setFrame(geometry.panelFrame, display: false)
        window?.orderOut(nil)
        window = newWindow
        hostingView = hosting
        if wasVisible { newWindow.orderFrontRegardless() }
    }

    private func updateVisibility(hasPending: Bool) {
        guard let window else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if hasPending {
            window.orderFrontRegardless()
        } else {
            // Let the card's retract animation play before hiding.
            let work = DispatchWorkItem { [weak window] in
                window?.orderOut(nil)
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Brings the terminal that spawned the agent to the front. The hook event
    /// carries `__CFBundleIdentifier` of the launching app; fall back to
    /// Terminal.app when it doesn't (ssh, tmux, IDE-embedded shells…).
    static func activateTerminal(bundleID: String?) {
        let target = (bundleID?.isEmpty == false) ? bundleID! : "com.apple.Terminal"
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
