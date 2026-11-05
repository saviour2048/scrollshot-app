import AppKit
import SwiftUI

/// Shelf preferences.
@MainActor
enum ShelfSettings {
    /// Auto-present the shelf while a real drag is in progress (the Yoink behavior).
    /// Only effective while the shelf feature itself is on (`shelf.enabled`).
    static var autoPresent: Bool {
        get { UserDefaults.standard.object(forKey: "shelf.autoPresent") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "shelf.autoPresent")
            if newValue, FeatureSwitches.shared.isEnabled(.shelf) { ShelfWindowController.shared.startAutoPresent() }
            else { ShelfWindowController.shared.stopAutoPresent() }
        }
    }

    /// 图片被拖放到终端时，自动把位图复制到剪贴板（供 Claude Code / Kimi CLI
    /// Cmd+V / Ctrl+V 贴成附件）。旧剪贴板内容可从剪贴板历史找回。
    static var copyImageOnTerminalDrop: Bool {
        get { UserDefaults.standard.object(forKey: "shelf.copyImageOnTerminalDrop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shelf.copyImageOnTerminalDrop") }
    }
}

/// The Yoink-style shelf: a small floating panel pinned to the right edge of the
/// screen. It appears automatically when the user starts a real drag (detected
/// by the drag pasteboard changeCount moving and the mouse travelling a short
/// distance), and can also be toggled with a hotkey.
@MainActor
final class ShelfWindowController {
    static let shared = ShelfWindowController()

    private var panel: NSPanel?
    private var dragMonitor: Any?

    // Drag-detection state for auto-present.
    private var mouseDownPoint: NSPoint?
    /// Baseline drag-pasteboard changeCount, captured when the previous gesture
    /// ENDED (leftMouseUp / launch) — NOT at leftMouseDown. The system writes
    /// the drag pasteboard within milliseconds of a drag starting, often before
    /// the queued mouseDown handler runs on the MainActor, so baselining at
    /// mouseDown regularly captured the already-bumped count and the whole
    /// drag went undetected (shelf never appeared).
    private var lastDragChangeCount: Int
    private var hasShownForCurrentDrag = false
    private var receivedDrop = false        // something was dropped ONTO the shelf

    private var pinnedOpen = false          // user opened it explicitly (hotkey / menu)
    private var autoShown = false           // the current visible state came from auto-present

    private let size = NSSize(width: 120, height: 380)
    private let margin: CGFloat = 16
    private let dragDistanceThreshold: CGFloat = 5

    // Cache the shared drag pasteboard reference; creating it repeatedly on
    // every global mouse event is unnecessary and was part of the lag during
    // text selection.
    private let dragPasteboard = NSPasteboard(name: .drag)

    private init() {
        // Capture the current drag pasteboard changeCount at launch. Any real
        // drag that happens afterwards will update it; stale content at launch
        // is ignored.
        lastDragChangeCount = dragPasteboard.changeCount
    }

    // MARK: Public

    /// Start watching for real drags so the shelf can auto-present. Call once at launch.
    func startAutoPresent() {
        guard dragMonitor == nil else { return }
        // Global monitor: track the whole mouse press/drag/release cycle across apps.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Global monitors are delivered on a background thread; hop to MainActor
            // because the controller and window state are MainActor-isolated.
            Task { @MainActor [weak self] in self?.handleGlobalMouse(event) }
        }
    }

    func stopAutoPresent() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
    }

    /// Hotkey toggle: show pinned (stays after drag) or hide.
    func toggle() {
        if panel?.isVisible == true {
            pinnedOpen = false
            autoShown = false
            hide()
        } else {
            pinnedOpen = true
            autoShown = false
            present(on: NSScreen.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Explicit dismiss (× button in the header or after dragging out the last item).
    func dismiss() {
        pinnedOpen = false
        autoShown = false
        hide()
    }

    /// Called by ShelfView after a drop has been processed. On success the shelf
    /// stays open so the user can reach what they just parked; on failure an
    /// auto-presented shelf tucks away again.
    func didReceiveDrop(success: Bool) {
        if success {
            receivedDrop = true
            // A shelf that received content behaves like a pinned shelf until the drag ends.
            pinnedOpen = true
            autoShown = false
        } else if autoShown && !pinnedOpen {
            hide()
        }
    }

    // MARK: Drag detection

    private func handleGlobalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Start tracking a potential drag. Reset all per-drag state.
            // Note: deliberately NOT re-baselining lastDragChangeCount here —
            // see the property's comment for the race that caused missed drags.
            mouseDownPoint = NSEvent.mouseLocation
            hasShownForCurrentDrag = false
            receivedDrop = false

        case .leftMouseDragged:
            guard !pinnedOpen,                 // already pinned open: nothing to do
                  !hasShownForCurrentDrag else { return }

            let loc = NSEvent.mouseLocation
            // Global monitors may not always deliver .leftMouseDown; use the first
            // dragged point as the drag origin in that case.
            if mouseDownPoint == nil { mouseDownPoint = loc }
            guard let start = mouseDownPoint else { return }
            let distance = hypot(loc.x - start.x, loc.y - start.y)
            guard distance >= dragDistanceThreshold else { return }

            // Performance-critical: this handler runs on every leftMouseDragged
            // system-wide. We therefore avoid touching the drag pasteboard at
            // all until (a) the mouse has moved enough to be a real drag and
            // (b) the pasteboard's changeCount has moved. Reading types/content
            // on every event caused severe lag during text selection.
            let currentCC = dragPasteboard.changeCount
            guard currentCC != lastDragChangeCount else { return }
            lastDragChangeCount = currentCC

            guard hasDraggableContent(dragPasteboard) else { return }

            hasShownForCurrentDrag = true
            autoShown = true
            present(on: screenContaining(loc))

        case .leftMouseUp:
            // Gesture over: snapshot the changeCount now, while no drag can be
            // starting. The next drag's first pasteboard write will differ from
            // this baseline — that difference is what detects the drag.
            lastDragChangeCount = dragPasteboard.changeCount
            mouseDownPoint = nil
            hasShownForCurrentDrag = false

            // Auto-presented (not pinned) → tuck away shortly after the drag,
            // BUT only if nothing was dropped onto us. The delay lets the drop's
            // async onDrop handlers fire and call keepOpenAfterDrop() first.
            if autoShown && !pinnedOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self, !self.pinnedOpen, !self.receivedDrop else { return }
                    self.hide()
                }
            }

        default: break
        }
    }

    /// True when the drag pasteboard advertises one of the types we accept.
    /// We only inspect `types` here, not the contents, to avoid interfering with
    /// a live drag session.
    private func hasDraggableContent(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let accepted: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            .string,
            .tiff,
            .png,
            .init("public.image"),
            .init("public.file-url")
        ]
        return types.contains(where: { accepted.contains($0) })
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: Window

    private func present(on screen: NSScreen?) {
        if panel == nil { panel = makePanel() }
        positionAtRightEdge(on: screen ?? NSScreen.main)
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        receivedDrop = false
        autoShown = false
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Content view is a plain container; SwiftUI content sits below the
        // AppKit drop-target overlay. The overlay's hitTest returns nil so
        // normal mouse events reach rows/buttons, while drag events are still
        // delivered to the registered overlay. Matches the Dropshit pattern.
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let hostingView = NSHostingView(rootView: ShelfView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)

        let dropView = ShelfDropTargetView()
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onDropFiles = { urls in
            ShelfStore.shared.addFiles(urls)
            return !urls.isEmpty
        }
        dropView.onDropImage = { data in
            ShelfStore.shared.addImage(data, originalName: nil)
            return true
        }
        dropView.onDropText = { text in
            ShelfStore.shared.addText(text)
            return !text.isEmpty
        }
        contentView.addSubview(dropView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            dropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dropView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dropView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        p.contentView = contentView
        return p
    }

    private func positionAtRightEdge(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - size.width - margin
        let y = vf.midY - size.height / 2
        panel?.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
