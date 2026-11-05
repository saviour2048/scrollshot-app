import AppKit
import SwiftUI
import Combine
import os

/// Dedicated menu-bar item for external display brightness.
///
/// Visible only when at least one DDC-compatible external display is detected.
/// Click shows a popover with sliders; right-click shows the main app menu.
@MainActor
final class BrightnessStatusItemController: ObservableObject {
    static let shared = BrightnessStatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Subscribes to the controller's publishers (idempotent).
    private func subscribeIfNeeded() {
        guard cancellables.isEmpty else { return }
        M1DDCBrightnessController.shared.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        M1DDCBrightnessController.shared.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        M1DDCBrightnessController.shared.$showMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    /// Show the status item when displays are available and the user has not
    /// hidden it; hide otherwise.
    func reload() {
        let controller = M1DDCBrightnessController.shared
        let hasDisplays = !controller.displays.isEmpty
        let hasFatalError = controller.errorMessage != nil && controller.displays.isEmpty
        let shouldShow = controller.showMenuBarIcon && hasDisplays && !hasFatalError

        if shouldShow {
            guard statusItem == nil else { return }
            Diag.brightness.debug("Creating status item for \(controller.displays.count) display(s)")
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "sun.max.fill",
                                         accessibilityDescription: L("settings.brightness"))
            item.button?.action = #selector(handleClick)
            item.button?.target = self
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        } else {
            if let error = controller.errorMessage {
                Diag.brightness.warning("Hiding status item: \(error, privacy: .public)")
            } else {
                Diag.brightness.debug("Hiding status item: no external displays")
            }
            tearDown()
        }
    }

    func refresh() {
        M1DDCBrightnessController.shared.refreshDisplays()
    }

    /// Initializes the singleton, subscribes to display changes and creates the
    /// status item if displays are available. No-op while the feature is off.
    func start() {
        guard FeatureSwitches.shared.isEnabled(.brightness) else { return }
        subscribeIfNeeded()
        reload()
    }

    /// Feature toggled off: drop the status item AND the Combine subscriptions
    /// so nothing brightness-related stays resident.
    func stop() {
        cancellables.removeAll()
        tearDown()
    }

    private func tearDown() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover?.performClose(nil)
            let menu = MainMenuBarController.shared.makeMainMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        guard let popover else {
            let newPopover = NSPopover()
            newPopover.behavior = .transient
            newPopover.animates = true
            newPopover.contentSize = NSSize(width: 280, height: max(120, 70 + M1DDCBrightnessController.shared.displays.count * 60))
            newPopover.contentViewController = NSHostingController(rootView: BrightnessPopoverView())
            self.popover = newPopover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if let popover = self?.popover, popover.isShown {
                    popover.performClose(nil)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            newPopover.contentViewController?.view.window?.makeKey()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentSize = NSSize(width: 280, height: max(120, 70 + M1DDCBrightnessController.shared.displays.count * 60))
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Popover shown from the brightness status item: a compact list of sliders.
private struct BrightnessPopoverView: View {
    @StateObject private var controller = M1DDCBrightnessController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.brightness"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("brightness.refresh")) {
                    controller.refreshDisplays()
                }
                .controlSize(.small)
            }

            if let error = controller.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.displays.isEmpty {
                Text(L("brightness.noDisplays"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(controller.displays) { display in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.name)
                            .font(.system(size: 12))
                        Slider(value: Binding(
                            get: { Double(controller.brightnessValues[display.uuid] ?? 50) },
                            set: { controller.writeBrightness(display: display, value: Int($0)) }
                        ), in: 0...100, step: 1)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 260)
    }
}
