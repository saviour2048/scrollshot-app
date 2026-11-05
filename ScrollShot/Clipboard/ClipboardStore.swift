import AppKit
import Combine
import CoreGraphics
import ImageIO

/// Persisted clipboard history. Text lives inline in `index.json`; images are
/// PNGs beside it. Newest first; pinned items are protected from pruning.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipboardItem] = []

    private let maxItems = 300
    private let maxImageDimension: CGFloat = 400
    /// Single text-entry caps: beyond 64KB the RTF copy is dropped (redundant
    /// with the plain text); beyond 256KB the text itself is truncated.
    private static let maxRTFTextBytes = 64 * 1024
    private static let maxTextBytes = 256 * 1024
    private let fm = FileManager.default

    /// In-memory thumbnail cache so the UI does not decode the same PNG repeatedly
    /// while scrolling or switching selection.
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// Apps whose clipboard changes are never recorded (password managers etc.).
    /// Users can extend this later; concealed-type detection is the main guard.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.agilebits.onepassword", "com.agilebits.onepassword7", "com.1password.1password",
        "com.lastpass.LastPass", "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal",
    ]

    private lazy var dir: URL = {
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ScrollShot/Clipboard")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private init() {
        thumbnailCache.countLimit = 100
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageFileName.map { dir.appendingPathComponent($0) }
    }

    func thumbnailURL(for item: ClipboardItem) -> URL? {
        item.imageFileName.map { dir.appendingPathComponent($0).deletingPathExtension().appendingPathExtension("thumb.png") }
    }

    /// Returns a downsampled thumbnail image for UI display. Uses an in-memory
    /// cache and falls back to generating/loading the thumbnail file on demand.
    /// Synchronous variant for callers already on the main actor that can tolerate
    /// a quick cache hit; misses decode on the calling thread.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = "\(item.id.uuidString)-thumb" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        let url = thumbnailURL(for: item) ?? imageURL(for: item)
        guard let url, fm.fileExists(atPath: url.path),
              let image = Self.downsampledImage(at: url, maxPixelSize: maxImageDimension) else { return nil }

        let cost = max(1, Int(image.size.width * image.size.height * 4))
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Asynchronous variant that decodes off the main thread. Use from SwiftUI views.
    func thumbnail(for item: ClipboardItem) async -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = "\(item.id.uuidString)-thumb" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        let url = thumbnailURL(for: item) ?? imageURL(for: item)
        let maxSize = maxImageDimension
        guard let url else { return nil }

        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Self.downsampledImage(at: url, maxPixelSize: maxSize)
        }.value

        guard let image else { return nil }
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    func clearCache() {
        thumbnailCache.removeAllObjects()
    }

    // MARK: Mutations

    func add(_ item: ClipboardItem, imageData: Data?) {
        // Skip if identical to the newest entry (re-copy / our own paste).
        if let newest = items.first, newest.kind == item.kind {
            if item.kind == .text, newest.text == item.text { return }
            if item.kind == .file, newest.filePaths == item.filePaths { return }
        }
        var stored = item
        if stored.kind == .text, let text = stored.text {
            let byteCount = text.utf8.count
            if byteCount > Self.maxRTFTextBytes {
                stored.rtfData = nil
            }
            if byteCount > Self.maxTextBytes {
                // Rebuild through the initializer so `searchText` reflects the cut.
                stored = ClipboardItem(id: stored.id, kind: stored.kind,
                                       text: Self.truncateUTF8(text, toBytes: Self.maxTextBytes),
                                       rtfData: stored.rtfData, imageFileName: stored.imageFileName,
                                       filePaths: stored.filePaths, sourceApp: stored.sourceApp,
                                       sourceBundleID: stored.sourceBundleID, timestamp: stored.timestamp,
                                       charCount: stored.charCount, wordCount: stored.wordCount,
                                       pinned: stored.pinned)
                stored.textTruncated = true
            }
        }
        if item.kind == .image, let imageData {
            let name = "\(item.id.uuidString).png"
            let url = dir.appendingPathComponent(name)
            try? imageData.write(to: url)
            stored.imageFileName = name
            // Generate a small thumbnail file so the UI never has to decode the
            // full PNG just to show a list icon or preview.
            generateThumbnailFile(for: stored)
        }
        items.insert(stored, at: 0)
        prune()
        save()
    }

    func delete(_ item: ClipboardItem) {
        removeImageFile(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned = !items[i].pinned
        save()
    }

    func clearAll() {
        items.forEach(removeImageFile)
        items.removeAll()
        clearCache()
        save()
    }

    // MARK: Helpers

    private func removeImageFile(_ item: ClipboardItem) {
        if let f = item.imageFileName {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
            // Also delete the companion thumbnail.
            let thumb = dir.appendingPathComponent(f).deletingPathExtension().appendingPathExtension("thumb.png")
            try? fm.removeItem(at: thumb)
        }
    }

    /// Writes a downsampled `<id>.thumb.png` beside the original PNG.
    private func generateThumbnailFile(for item: ClipboardItem) {
        guard item.kind == .image,
              let sourceURL = imageURL(for: item),
              fm.fileExists(atPath: sourceURL.path),
              let thumbURL = thumbnailURL(for: item),
              let thumbnail = Self.downsampledImage(at: sourceURL, maxPixelSize: maxImageDimension),
              let tiff = thumbnail.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: thumbURL, options: .atomic)
    }

    /// Efficient ImageIO downsample. The full image is never decoded into memory.
    /// Kept static/nonisolated so it can run on a background queue from SwiftUI.
    nonisolated private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Truncate on a UTF-8 byte boundary so the stored string never exceeds the cap.
    private static func truncateUTF8(_ s: String, toBytes limit: Int) -> String {
        var count = 0
        return String(s.prefix {
            count += $0.utf8.count
            return count <= limit
        })
    }

    private func prune() {
        guard items.count > maxItems else { return }
        // Drop the oldest UNPINNED entries (and their image files) down to the cap.
        var kept: [ClipboardItem] = []
        var unpinnedKept = 0
        let unpinnedBudget = max(0, maxItems - items.filter { $0.pinned }.count)
        for item in items { // already newest-first
            if item.pinned {
                kept.append(item)
            } else if unpinnedKept < unpinnedBudget {
                kept.append(item); unpinnedKept += 1
            } else {
                removeImageFile(item)
            }
        }
        items = kept
    }
}
