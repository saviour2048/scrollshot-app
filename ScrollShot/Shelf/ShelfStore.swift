import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One item parked on the shelf (Yoink-style). Files are copied into the shelf's
/// own store folder so they survive the source app closing or the original file
/// being moved/deleted; images dragged as raw bitmap data are stored as PNG;
/// text is stored verbatim.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case file, text, image }
    let id: UUID
    var kind: Kind
    var addedAt: Date
    var filePaths: [String]?   // .file: copied file paths inside the shelf store (may be several)
    var text: String?          // .text
    var imageFileName: String? // .image: PNG stored beside index.json

    var title: String {
        switch kind {
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            return names.first ?? "文件"
        case .text:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:
            return "图片"
        }
    }

    var subtitle: String {
        switch kind {
        case .file:
            let n = (filePaths ?? []).count
            return n > 1 ? "\(n) 个文件" : ((filePaths?.first as NSString?)?.pathExtension ?? "文件")
        case .text: return "文本 · \(text?.count ?? 0) 字"
        case .image: return "图片"
        }
    }
}

/// Persisted collection of shelf items. Mirrors ClipboardStore's on-disk layout
/// (index.json + sidecar files) so the two features behave consistently.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    private let maxItems = 50
    /// Thumbnail width for shelf image rows: rows are 34pt, so this is decoded
    /// instead of the full-size PNG.
    private let imageThumbnailMaxPixelSize = 256
    private let fm = FileManager.default
    private var dir: URL {
        let d = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ScrollShot/Shelf")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private init() { load() }

    func imageURL(for item: ShelfItem) -> URL? {
        item.imageFileName.map { dir.appendingPathComponent($0) }
    }

    // MARK: Mutation

    /// Add one or more files as a stack. Each file is copied into the shelf store
    /// preserving its original name so dragging them back out keeps the name.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var copiedPaths: [String] = []
        for url in urls {
            guard let dest = copyFileIntoStore(url) else { continue }
            copiedPaths.append(dest.path)
        }
        guard !copiedPaths.isEmpty else { return }
        items.insert(ShelfItem(id: UUID(), kind: .file, addedAt: Date(),
                               filePaths: copiedPaths, text: nil, imageFileName: nil), at: 0)
        prune()
        save()
    }

    func addText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.insert(ShelfItem(id: UUID(), kind: .text, addedAt: Date(),
                               filePaths: nil, text: t, imageFileName: nil), at: 0)
        prune()
        save()
    }

    func addImage(_ data: Data, originalName: String? = nil) {
        let base = (originalName as NSString?)?.deletingPathExtension ?? "Image"
        let ext = (originalName as NSString?)?.pathExtension ?? "png"
        let name = uniqueFileName(base: base, extension: ext)
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        writeThumbnail(forImageFileName: name)
        items.insert(ShelfItem(id: UUID(), kind: .image, addedAt: Date(),
                               filePaths: nil, text: nil, imageFileName: name), at: 0)
        prune()
        save()
    }

    /// Remove immediately and delete backing files (for explicit user actions
    /// like the right-click menu or clearing the shelf).
    func remove(_ item: ShelfItem) {
        deleteFiles(for: item)
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Remove from the UI immediately but keep backing files around for a short
    /// while so the destination app (Finder) can finish copying the dragged-out
    /// files. Prevents Finder error -43.
    func removeAfterDragOut(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
        // Delay deletion: Finder's drop is asynchronous and may still be reading
        // the file after the drag session reports completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.deleteFiles(for: item)
        }
    }

    /// 拖到终端的条目: 从 UI 移除但**保留底稿文件**。终端/CLI 收到的只是路径
    /// 文本, 之后还会按路径读文件——2 秒宽限是为 Finder 异步拷贝设计的, 对
    /// CLI 远远不够(实测 agent 几秒后 ReadMediaFile 时已 404)。残留文件由
    /// load() 里的孤儿清理(>7 天)回收。
    func removeAfterTerminalDragOut(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items { deleteFiles(for: item) }
        items.removeAll()
        save()
    }

    private func deleteFiles(for item: ShelfItem) {
        if let f = item.imageFileName {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
            // Also delete the companion thumbnail.
            let thumb = dir.appendingPathComponent(f).deletingPathExtension().appendingPathExtension("thumb.png")
            try? fm.removeItem(at: thumb)
        }
        if let paths = item.filePaths {
            for path in paths { try? fm.removeItem(atPath: path) }
        }
    }

    /// Evict the oldest entries past the cap, deleting their backing files.
    private func prune() {
        while items.count > maxItems {
            let oldest = items.removeLast()
            deleteFiles(for: oldest)
        }
    }

    /// Writes a downsampled `<name-without-ext>.thumb.png` beside the image.
    /// Uses ImageIO so the full image is never decoded into memory.
    private func writeThumbnail(forImageFileName name: String) {
        let url = dir.appendingPathComponent(name)
        let thumbURL = url.deletingPathExtension().appendingPathExtension("thumb.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: imageThumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (data as Data).write(to: thumbURL, options: .atomic)
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = decoded
        }
        sweepOrphanedFiles()
    }

    /// 回收不再被索引引用的底稿文件（拖到终端的条目保留文件, 见
    /// removeAfterTerminalDragOut）。超过 7 天才删, 给进行中的 CLI 会话留窗口。
    private func sweepOrphanedFiles() {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let referenced = referencedFileNames()
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for name in Self.orphanCandidates(contents: contents, referenced: referenced) {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date, mtime < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// 索引引用的文件名集合（含图片条目的缩略图伴生文件）。
    private func referencedFileNames() -> Set<String> {
        var names = Set<String>()
        for item in items {
            for p in item.filePaths ?? [] { names.insert((p as NSString).lastPathComponent) }
            if let f = item.imageFileName {
                names.insert(f)
                names.insert((f as NSString).deletingPathExtension + ".thumb.png")
            }
        }
        return names
    }

    /// 纯过滤, 便于测试: 目录内容里既非索引也非引用的文件。
    nonisolated static func orphanCandidates(contents: [String], referenced: Set<String>) -> [String] {
        contents.filter { $0 != "index.json" && !referenced.contains($0) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: Helpers

    /// Copy a file/folder into the shelf store, keeping its original name and
    /// appending a counter if a name collision exists.
    private func copyFileIntoStore(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        let dest = uniqueURL(name: name)
        do {
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            print("ScrollShot Shelf: failed to copy \(url) to store: \(error)")
            return nil
        }
    }

    private func uniqueURL(name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var counter = 1
        repeat {
            candidate = dir.appendingPathComponent("\(base) (\(counter))\(suffix)")
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func uniqueFileName(base: String, extension: String) -> String {
        let ext = `extension`.isEmpty ? "" : ".\(`extension`)"
        var candidate = "\(base)\(ext)"
        guard fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) else { return candidate }
        var counter = 1
        repeat {
            candidate = "\(base) (\(counter))\(ext)"
            counter += 1
        } while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path)
        return candidate
    }
}
