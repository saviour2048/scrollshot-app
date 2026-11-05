import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An AppKit-native drop target overlay for the shelf.
///
/// SwiftUI's `.onDrop` with `NSItemProvider` is unreliable for reading original
/// file URLs from Finder (image files often collapse to bitmap data). This view
/// sits on top of the SwiftUI content, receives drag events, and lets normal
/// mouse events pass through to the rows/buttons underneath.
///
/// Pattern matches open-source Dropover clones (Dropshit, DropShelf, Dropp):
/// register dragged types on an `NSView`, read file URLs via
/// `NSPasteboard.readObjects(forClasses: [NSURL.self], ...)`.
struct ShelfDropTarget: NSViewRepresentable {
    var onDropFiles: ([URL]) -> Bool
    var onDropImage: (Data) -> Bool
    var onDropText: (String) -> Bool

    func makeNSView(context: Context) -> ShelfDropTargetView {
        let view = ShelfDropTargetView()
        view.onDropFiles = onDropFiles
        view.onDropImage = onDropImage
        view.onDropText = onDropText
        return view
    }

    func updateNSView(_ nsView: ShelfDropTargetView, context: Context) {
        nsView.onDropFiles = onDropFiles
        nsView.onDropImage = onDropImage
        nsView.onDropText = onDropText
    }
}

final class ShelfDropTargetView: NSView {
    var onDropFiles: (([URL]) -> Bool) = { _ in false }
    var onDropImage: ((Data) -> Bool) = { _ in false }
    var onDropText: ((String) -> Bool) = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            .tiff,
            .png,
            .init(UTType.image.identifier),
            .init(UTType.data.identifier)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // Let normal mouse events pass through to SwiftUI buttons/rows underneath.
    // Drag events still fire on this registered view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var success = false

        // 1. Files: read every file URL as a stack.
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            success = onDropFiles(urls)
        }
        // 2. Image data (e.g. dragged from a web page).
        else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                let img = images.first,
                let tiff = img.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
            success = onDropImage(png)
        }
        // 4. Plain text.
        else if let s = pb.string(forType: .string), !s.isEmpty {
            success = onDropText(s)
        }

        ShelfWindowController.shared.didReceiveDrop(success: success)
        return success
    }

    private func canAccept(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        || pb.canReadObject(forClasses: [NSImage.self], options: nil)
        || pb.string(forType: .string) != nil
    }
}
