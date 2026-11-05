import AppKit
import SwiftUI

/// Menu-bar status item for input statistics. Click opens a popover dashboard;
/// right-click shows the main app menu.
@MainActor
final class InputStatsStatusItemController {
    static let shared = InputStatsStatusItemController()

    private var statusItem: NSStatusItem?
    private var meterView: InputStatsMeterView?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    private init() {}

    /// Show or hide the status item based on the setting.
    func reload() {
        let enabled = InputStatsSettings.enabled
        let show = enabled && InputStatsSettings.showInMenuBar

        if show {
            guard statusItem == nil else {
                render()
                return
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let view = InputStatsMeterView(frame: NSRect(x: 0, y: 0, width: 34, height: NSStatusBar.system.thickness))
            view.autoresizingMask = [.width, .height]
            view.onClick = { [weak self] event in self?.handleClick(event) }
            item.button?.image = nil
            item.button?.title = ""
            item.button?.addSubview(view)
            meterView = view
            statusItem = item

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 340, height: 460)
            popover.contentViewController = NSHostingController(rootView: InputStatsDashboardView())
            self.popover = popover

            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if let popover = self?.popover, popover.isShown {
                    popover.performClose(nil)
                }
            }

            InputStatsStore.shared.onUpdate = { [weak self] in self?.render() }
            render()
        } else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            popover = nil
            meterView = nil
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
            eventMonitor = nil
            InputStatsStore.shared.onUpdate = nil
        }
    }

    private func handleClick(_ event: NSEvent) {
        guard let button = statusItem?.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover?.performClose(nil)
            let menu = MainMenuBarController.shared.makeMainMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func render() {
        guard let view = meterView else { return }
        let stats = InputStatsStore.shared.today
        // Menu bar: compact K/M form (saves space). Tooltip keeps full numbers.
        view.set(top: InputStatsFormat.compact(stats.keyPresses),
                 bottom: InputStatsFormat.compact(stats.totalClicks))
        statusItem?.length = view.fittingWidth
        statusItem?.button?.toolTip = String(format: L("inputStats.tooltip"),
                                             InputStatsFormat.number(stats.keyPresses),
                                             InputStatsFormat.number(stats.totalClicks))
    }
}

/// Two-line menu-bar meter: keyboard icon on the left, key count on top,
/// click count on the bottom. Matches the existing usage-meter layout.
private final class InputStatsMeterView: NSView {
    var onClick: ((NSEvent) -> Void)?

    private var top = ""
    private var bottom = ""
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private let iconSize: CGFloat = 14
    private let gap: CGFloat = 3
    private let pad: CGFloat = 5

    private lazy var icon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Stats")?
            .withSymbolConfiguration(config)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func set(top: String, bottom: String) {
        guard top != self.top || bottom != self.bottom else { return }
        self.top = top
        self.bottom = bottom
        needsDisplay = true
    }

    var fittingWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let tw = max((top as NSString).size(withAttributes: attrs).width,
                     (bottom as NSString).size(withAttributes: attrs).width)
        let textW = (top.isEmpty && bottom.isEmpty) ? 0 : ceil(tw)
        return ceil(pad + iconSize + gap + textW + pad)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        var x = pad

        if let icon {
            icon.draw(in: NSRect(x: x, y: (h - iconSize) / 2, width: iconSize, height: iconSize),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1.0)
        }
        x += iconSize + gap

        guard !top.isEmpty || !bottom.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.maximumLineHeight = 9.5
        para.minimumLineHeight = 9.5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let text = bottom.isEmpty ? top : "\(top)\n\(bottom)"
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        str.draw(in: NSRect(x: x, y: (h - sz.height) / 2, width: ceil(sz.width) + 2, height: ceil(sz.height)))
    }

    override func mouseDown(with event: NSEvent) { onClick?(event) }
    override func rightMouseDown(with event: NSEvent) { onClick?(event) }
}
