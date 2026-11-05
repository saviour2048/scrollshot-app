import AppKit

/// Hosts the long-screenshot editor window: the shared annotation toolbar on
/// top and a scrollable editable canvas below. Reuses `AnnotationBar` and
/// `AnnotationEditorView` so editing a long image works exactly like the
/// screenshot flow.
@MainActor
final class AnnotationEditorWindowController {
    static let shared = AnnotationEditorWindowController()

    private var window: NSWindow?

    private init() {}

    func open(image: CGImage, scale: CGFloat) {
        window?.close()

        let editor = AnnotationEditorView(image: image, scale: scale)
        let bar = AnnotationBar(showsLongCapture: false)
        editor.setColor(bar.currentColor)
        editor.setWidth(bar.currentWidth)

        bar.onSelectTool = { [weak editor] tool in editor?.selectTool(tool) }
        bar.onColor = { [weak editor] color in editor?.setColor(color) }
        bar.onWidth = { [weak editor] width in editor?.setWidth(width) }
        bar.onUndo = { [weak editor] in editor?.undo() }
        bar.onCopy = { [weak editor] in editor?.copy() }
        bar.onSave = { [weak self, weak editor] in
            editor?.save()
            self?.close()
        }
        bar.onCancel = { [weak self] in self?.close() }

        // Prevent the scroll view from resizing the document view to fit its
        // visible bounds; the editor must keep the full image size so long
        // screenshots are scrollable rather than clipped.
        editor.autoresizingMask = []

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false          // let the glass show through
        scrollView.documentView = editor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let barSize = bar.contentSize
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Liquid Glass window background (glass on Tahoe; vibrancy on older).
        let glass = NSVisualEffectView()
        glass.material = .windowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false

        let titleStrip: CGFloat = 38            // clears the transparent title bar / traffic lights
        let topInset = titleStrip + barSize.height + 14

        let container = NSView()
        container.addSubview(glass)
        container.addSubview(scrollView)
        container.addSubview(bar)                 // toolbar floats above the content
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: titleStrip),
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.widthAnchor.constraint(equalToConstant: barSize.width),
            bar.heightAnchor.constraint(equalToConstant: barSize.height),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let displayWidth = CGFloat(image.width) / max(1, scale)
        let displayHeight = CGFloat(image.height) / max(1, scale)

        // Fit the window inside the current screen, leaving a margin so it never
        // extends past the visible frame (menu bar / Dock).
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let maxWidth = visibleFrame.width - 48
        let maxHeight = visibleFrame.height - 48

        // Size the window to fit the image when possible, up to the usable
        // screen area. Only fall back to scrolling if the image is larger than
        // the screen; previously the 540/780 caps made long screenshots look
        // clipped even when screen space was available.
        let contentWidth = min(max(displayWidth, barSize.width) + 40, maxWidth)
        let contentHeight = max(440, min(displayHeight + topInset + 24, maxHeight))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrollShot · 长截图编辑"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = container
        window.isReleasedWhenClosed = false

        // Center in the visible frame so the whole window is reachable.
        let origin = CGPoint(
            x: visibleFrame.midX - contentWidth / 2,
            y: visibleFrame.midY - contentHeight / 2
        )
        window.setFrameOrigin(origin)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}
