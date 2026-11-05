import AppKit
import os
import SwiftUI

/// A shelf row backed by a real AppKit dragging SOURCE. SwiftUI's `.onDrag`
/// gives no completion callback, so it can't tell when an item was dragged out;
/// `NSDraggingSource.draggingSession(_:endedAt:operation:)` does. On a
/// successful drag-out we remove the item from the shelf — matching Yoink,
/// where dragged-out items leave the shelf (unless locked).
struct DraggableShelfRow: NSViewRepresentable {
    let item: ShelfItem
    let imageURL: URL?              // captured so the NSView needn't touch the @MainActor store
    let onDragOut: () -> Void
    /// 落点是终端时改走这个回调: 底稿文件保留(终端只拿到路径文本, 之后还要读)。
    let onDragOutToTerminal: () -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView() }

    func updateNSView(_ nsView: ShelfDragView, context: Context) {
        nsView.configure(item: item, imageURL: imageURL, onDragOut: onDragOut,
                         onDragOutToTerminal: onDragOutToTerminal, onRemove: onRemove)
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    private var item: ShelfItem?
    private var imageURL: URL?
    private var onDragOut: (() -> Void)?
    private var onDragOutToTerminal: (() -> Void)?
    private var onRemove: (() -> Void)?
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(item: ShelfItem, imageURL: URL?, onDragOut: @escaping () -> Void,
                   onDragOutToTerminal: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.item = item
        self.imageURL = imageURL
        self.onDragOut = onDragOut
        self.onDragOutToTerminal = onDragOutToTerminal
        self.onRemove = onRemove
        host.rootView = AnyView(ShelfRowContent(item: item, imageURL: imageURL))
    }

    // Take mouse events so we can start the drag (rows have no inner controls).
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        let writers = pasteboardWriters(for: item)
        guard !writers.isEmpty else { return }
        let img = snapshot()
        let dragItems = writers.map { writer -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: writer)
            di.setDraggingFrame(bounds, contents: img)
            return di
        }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        // Show a stacked cursor when multiple files are dragged out together.
        session.draggingFormation = dragItems.count > 1 ? .stack : .default
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if let item, !ShelfImageCopy.imagePaths(for: item, imageURL: imageURL).isEmpty {
            let copyImage = NSMenuItem(title: "复制为图片", action: #selector(copyImageToPasteboard), keyEquivalent: "")
            copyImage.target = self
            menu.addItem(copyImage)
        }
        let remove = NSMenuItem(title: "移除", action: #selector(removeItem), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// 右键「复制为图片」：把位图写进剪贴板，供终端里 Cmd+V / Ctrl+V 贴成附件。
    @objc private func copyImageToPasteboard() {
        guard let item else { return }
        ShelfImageCopy.copyToPasteboard(paths: ShelfImageCopy.imagePaths(for: item, imageURL: imageURL))
    }

    @objc private func removeItem() { onRemove?() }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy by default: the destination receives the data; we remove the shelf
        // item ourselves once the drop lands. Allowing move as well lets Finder
        // show the correct badge, but the shelf copy remains until we clean up.
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Dropped somewhere that accepted it → remove from the shelf (Yoink).
        guard !operation.isEmpty else { return }

        // 落点是终端? 终端收到拖拽只插入路径文本、不拷贝文件:
        //  - 图片顺手复制到剪贴板(Cmd+V / Ctrl+V 贴成附件);
        //  - 底稿文件必须保留(CLI 之后会按路径读), 由 ShelfStore 孤儿清理回收。
        let dest = ShelfImageCopy.destinationApp(atScreenPoint: screenPoint)
        let toTerminal = dest.map { SmartPasteController.isTerminal($0.bundleID, pid: $0.pid) } ?? false
        if toTerminal {
            if ShelfSettings.copyImageOnTerminalDrop, let item {
                let paths = ShelfImageCopy.imagePaths(for: item, imageURL: imageURL)
                if !paths.isEmpty {
                    let copied = ShelfImageCopy.copyToPasteboard(paths: paths)
                    if copied > 0 {
                        os.Logger(subsystem: "com.scrollshot.app", category: "shelf")
                            .info("shelf: copied \(copied) image(s) to clipboard for terminal drop")
                    }
                }
            }
            onDragOutToTerminal?()
        } else {
            onDragOut?()
        }
    }

    /// One pasteboard item per file URL so a multi-file stack drags all of its
    /// files out at once; a single item for image/text.
    private func pasteboardWriters(for item: ShelfItem) -> [NSPasteboardItem] {
        switch item.kind {
        case .file:
            return (item.filePaths ?? []).compactMap { path in
                let url = URL(fileURLWithPath: path)
                let pb = NSPasteboardItem()
                pb.setString(url.absoluteString, forType: .fileURL)
                return pb
            }
        case .image:
            guard let url = imageURL else { return [] }
            let pb = NSPasteboardItem()
            pb.setString(url.absoluteString, forType: .fileURL)
            return [pb]
        case .text:
            guard let text = item.text, !text.isEmpty else { return [] }
            let pb = NSPasteboardItem()
            pb.setString(text, forType: .string)
            return [pb]
        }
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

/// The visual content of a shelf row (shared by the AppKit drag view).
struct ShelfRowContent: View {
    let item: ShelfItem
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 9) {
            thumbnail
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.kind {
        case .file:
            if let path = item.filePaths?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "doc").foregroundColor(.secondary)
            }
        case .image:
            let thumbURL = imageURL?.deletingPathExtension().appendingPathExtension("thumb.png")
            if let url = thumbURL, FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if let url = imageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundColor(.secondary)
            }
        case .text:
            ZStack {
                Color.accentColor.opacity(0.12)
                Image(systemName: "text.alignleft").foregroundColor(.accentColor)
            }
        }
    }
}
