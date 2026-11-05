import Foundation
import AppKit

/// Where to scan. `home` needs no special permission; `fullDisk` starts at `/`
/// and needs Full Disk Access (and still skips system roots — see §7 red lines).
enum ScanRange: Sendable {
    case home
    case fullDisk
}

/// Thread-safe cancellation flag shared between the orchestrator (main) and the
/// background scan workers.
final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Result of classifying one path.
private struct Classification {
    let category: DiskItemCategory
    let safety: DiskItemSafety
    let reason: String
    let oneClickEligible: Bool

    static func safe(_ c: DiskItemCategory, _ reason: String, oneClick: Bool = false) -> Classification {
        Classification(category: c, safety: .safe, reason: reason, oneClickEligible: oneClick)
    }
    static func review(_ c: DiskItemCategory, _ reason: String) -> Classification {
        Classification(category: c, safety: .review, reason: reason, oneClickEligible: false)
    }
    static func keep(_ c: DiskItemCategory, _ reason: String) -> Classification {
        Classification(category: c, safety: .keep, reason: reason, oneClickEligible: false)
    }
}

// MARK: - Result emitter (thread-safe, coalesces batches across workers)

/// A streamed change to the result list.
enum DiskScanEvent: Sendable {
    /// Add a new row, or replace the existing row with the same URL (used to
    /// resolve a "计算中…" placeholder into its real size).
    case item(DiskScanItem)
    /// Drop a placeholder whose computed size turned out below the threshold.
    case removePath(String)
}

/// Collects events from many worker threads and forwards coalesced batches +
/// a running progress count to `onBatch`. All forwarding happens off-lock so
/// `onBatch` can hop to the main actor without contending.
private final class Emitter: @unchecked Sendable {
    private let onBatch: @Sendable ([DiskScanEvent], Int) -> Void
    private let lock = NSLock()
    private var buffer: [DiskScanEvent] = []
    private var scanned = 0

    init(_ onBatch: @escaping @Sendable ([DiskScanEvent], Int) -> Void) {
        self.onBatch = onBatch
    }

    func push(_ event: DiskScanEvent) {
        lock.lock()
        buffer.append(event)
        let batch: [DiskScanEvent]? = buffer.count >= 12 ? buffer : nil
        if batch != nil { buffer.removeAll(keepingCapacity: true) }
        let n = scanned
        lock.unlock()
        if let batch { onBatch(batch, n) }
    }

    /// Force the current buffer out now (used so placeholders appear instantly).
    func flush() {
        lock.lock()
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        let n = scanned
        lock.unlock()
        if !batch.isEmpty { onBatch(batch, n) }
    }

    /// Count `k` more traversed entries; emit a progress-only tick on each 5k boundary.
    func bump(_ k: Int) {
        lock.lock()
        let before = scanned
        scanned += k
        let n = scanned
        lock.unlock()
        if n / 5000 != before / 5000 { onBatch([], n) }
    }

    func drain() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        let n = scanned
        lock.unlock()
        onBatch(rest, n)   // final flush, also publishes the final count
    }
}

// MARK: - Parallel scan run

/// Drives the actual traversal across an `OperationQueue`. Directories near the
/// top are fanned out as separate operations (parallelism); below
/// `maxParallelDepth` each subtree is walked serially on one thread (bounds the
/// number of queued operations). Recognized rebuildable dirs are sized as their
/// own operations so big caches don't block discovery.
private final class ScanRun: @unchecked Sendable {
    let threshold: Int64
    let token: ScanToken
    let emitter: Emitter
    let knownSkip: Set<String>
    let opq: OperationQueue

    private let maxParallelDepth = 2

    init(threshold: Int64, token: ScanToken, emitter: Emitter, knownSkip: Set<String>) {
        self.threshold = threshold
        self.token = token
        self.emitter = emitter
        self.knownSkip = knownSkip
        opq = OperationQueue()
        opq.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        opq.qualityOfService = .utility
    }

    func enqueueWalk(_ dir: URL, depth: Int, priority: Operation.QueuePriority) {
        let op = BlockOperation { [self] in
            if token.isCancelled { return }
            walk(dir, depth: depth)
        }
        op.queuePriority = priority
        opq.addOperation(op)
    }

    /// Size a recognized aggregate dir (Caches, node_modules, …) on its own op.
    /// The queue parallelizes *across* aggregates; sizing within one is serial
    /// (it's I/O-bound, so splitting it further doesn't beat the disk).
    func enqueueSize(_ url: URL, _ c: Classification, priority: Operation.QueuePriority) {
        let op = BlockOperation { [self] in
            if token.isCancelled { return }
            let size = DiskScanEngine.directorySize(url, token: token)
            if size >= threshold {
                emitter.push(.item(DiskScanEngine.makeItem(url, isDir: true, size: size,
                                                           modified: DiskScanEngine.modificationDate(url), c: c)))
            }
        }
        op.queuePriority = priority
        opq.addOperation(op)
    }

    /// Resolve a known-root placeholder: size it, then either replace it with the
    /// real size (`.item`) or drop it if it came in under the threshold.
    func enqueueSizeUpdate(_ url: URL, _ c: Classification) {
        let op = BlockOperation { [self] in
            if token.isCancelled { return }
            let size = DiskScanEngine.directorySize(url, token: token)
            if size >= threshold {
                emitter.push(.item(DiskScanEngine.makeItem(url, isDir: true, size: size,
                                                           modified: DiskScanEngine.modificationDate(url), c: c)))
            } else {
                emitter.push(.removePath(url.standardizedFileURL.path))
            }
        }
        op.queuePriority = .veryHigh
        opq.addOperation(op)
    }

    private func walk(_ dir: URL, depth: Int) {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: DiskScanEngine.resourceKeys, options: []
        ) else { return }
        emitter.bump(kids.count)

        for url in kids {
            if token.isCancelled { return }
            guard let v = try? url.resourceValues(forKeys: DiskScanEngine.resourceKeySet) else { continue }
            if v.isSymbolicLink == true { continue }

            let isDir = v.isDirectory == true
            let isPackage = v.isPackage == true

            if isDir && !isPackage {
                if knownSkip.contains(url.standardizedFileURL.path)
                    || DiskScanEngine.isSystemPath(url)
                    || DiskScanEngine.shouldSkipDir(url) { continue }

                if let c = DiskScanEngine.classifyDirectory(url) {
                    enqueueSize(url, c, priority: .normal)           // aggregate; don't descend
                } else if depth < maxParallelDepth {
                    enqueueWalk(url, depth: depth + 1, priority: .low) // fan out near the top
                } else {
                    walk(url, depth: depth)                           // deep: stay on this thread
                }
            } else {
                let size = isPackage
                    ? DiskScanEngine.directorySize(url, token: token)
                    : DiskScanEngine.allocatedSize(v)
                if size >= threshold {
                    emitter.push(.item(DiskScanEngine.makeItem(url, isDir: isPackage, size: size,
                                                              modified: v.contentModificationDate,
                                                              c: DiskScanEngine.classifyFile(url, isPackage: isPackage))))
                }
            }
        }
    }
}

// MARK: - Scan engine (off the main thread)

/// Stateless, value-typed engine. `run` does a two-tier pass: the known
/// reclaimable roots are sized first (high priority → safe items surface fast),
/// then the rest of the tree is walked in parallel for scattered node_modules /
/// large files. No UI / no main-actor state.
struct DiskScanEngine: Sendable {
    let range: ScanRange
    let threshold: Int64

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey
    ]
    static let resourceKeySet = Set(resourceKeys)

    /// System roots we must never descend into or suggest deleting (§7 red lines).
    static let systemRoots: [String] = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/dev", "/cores", "/opt", "/Applications", "/Volumes", "/Network", "/.vol"
    ]

    func run(token: ScanToken, onBatch: @escaping @Sendable ([DiskScanEvent], Int) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let fastRoots = Self.knownReclaimableRoots(under: home)
        let knownSkip = Set(fastRoots.map { $0.0.path })

        let emitter = Emitter(onBatch)
        let runner = ScanRun(threshold: threshold, token: token, emitter: emitter, knownSkip: knownSkip)

        // Tier 1 — show the known reclaimable roots instantly as "计算中…"
        // placeholders, then resolve each one's real size (the I/O-bound part).
        for (url, c) in fastRoots { emitter.push(.item(Self.makeSizingPlaceholder(url, c))) }
        emitter.flush()
        for (url, c) in fastRoots { runner.enqueueSizeUpdate(url, c) }

        // Tier 2 — deep parallel walk of everything else.
        switch range {
        case .home:
            runner.enqueueWalk(home, depth: 0, priority: .low)
        case .fullDisk:
            runner.enqueueWalk(URL(fileURLWithPath: "/", isDirectory: true), depth: 0, priority: .low)
        }

        runner.opq.waitUntilAllOperationsAreFinished()
        emitter.drain()
    }

    // MARK: Known reclaimable roots (tier 1)

    private static func knownReclaimableRoots(under home: URL) -> [(URL, Classification)] {
        let candidates: [(String, Classification)] = [
            ("Library/Caches",
             Classification(category: .cache, safety: .safe, reason: "应用缓存,删除后会自动重建", oneClickEligible: true)),
            ("Library/Developer/Xcode/DerivedData",
             Classification(category: .developer, safety: .safe, reason: "Xcode 编译中间产物,可重新生成", oneClickEligible: true)),
            ("Library/Developer/Xcode/iOS DeviceSupport",
             Classification(category: .developer, safety: .safe, reason: "旧设备调试符号,连接设备后会重建", oneClickEligible: true)),
            ("Library/Developer/Xcode/watchOS DeviceSupport",
             Classification(category: .developer, safety: .safe, reason: "旧设备调试符号,连接设备后会重建", oneClickEligible: true)),
            ("Library/Developer/Xcode/tvOS DeviceSupport",
             Classification(category: .developer, safety: .safe, reason: "旧设备调试符号,连接设备后会重建", oneClickEligible: true)),
            ("Library/Developer/CoreSimulator/Caches",
             Classification(category: .cache, safety: .safe, reason: "模拟器缓存,可重建", oneClickEligible: true)),
            (".cache",
             Classification(category: .cache, safety: .safe, reason: "用户级缓存(.cache),可重建", oneClickEligible: true)),
            (".gradle",
             Classification(category: .buildArtifact, safety: .safe, reason: "Gradle 缓存,可重建", oneClickEligible: true)),
            (".npm/_cacache",
             Classification(category: .cache, safety: .safe, reason: "npm 缓存(_cacache),可重建", oneClickEligible: true)),
            ("Library/Application Support/MobileSync/Backup",
             Classification(category: .backup, safety: .review, reason: "iOS 设备备份,删前确认已不需要", oneClickEligible: false)),
        ]
        return candidates.compactMap { rel, c in
            let url = home.appendingPathComponent(rel).standardizedFileURL
            return dirExists(url) ? (url, c) : nil
        }
    }

    // MARK: Classification (deep tier)

    fileprivate static func makeItem(_ url: URL, isDir: Bool, size: Int64,
                                     modified: Date?, c: Classification) -> DiskScanItem {
        DiskScanItem(url: url, name: url.lastPathComponent, isDirectory: isDir,
                     size: size, modified: modified, category: c.category,
                     safety: c.safety, reason: c.reason, oneClickEligible: c.oneClickEligible)
    }

    /// A known-root row shown before its (slow) size is known.
    fileprivate static func makeSizingPlaceholder(_ url: URL, _ c: Classification) -> DiskScanItem {
        var item = makeItem(url, isDir: true, size: 0, modified: modificationDate(url), c: c)
        item.isSizing = true
        return item
    }

    /// Recognized directories (aggregated as one item, not descended). Returns a
    /// verdict + a plain-language reason; `nil` means "keep descending".
    fileprivate static func classifyDirectory(_ url: URL) -> Classification? {
        let path = url.path
        let lpath = path.lowercased()
        let name = url.lastPathComponent

        // ── Rebuildable caches (safe) ──
        if path.hasSuffix("/Library/Caches") {
            return .safe(.cache, "应用缓存,删除后会自动重建", oneClick: true)
        }
        // Per-app cache dirs (Chrome/Electron/etc. under Application Support).
        if ["Cache", "Code Cache", "GPUCache", "ShaderCache", "DawnCache",
            "Service Worker", "CacheStorage"].contains(name), lpath.contains("/library/") {
            return .safe(.cache, "应用缓存(\(name)),删后会自动重建")
        }

        // ── Xcode / developer ──
        if path.hasSuffix("/Library/Developer/Xcode/DerivedData") {
            return .safe(.developer, "Xcode 编译中间产物,可重新生成", oneClick: true)
        }
        if path.hasSuffix("/iOS DeviceSupport") || path.hasSuffix("/watchOS DeviceSupport")
            || path.hasSuffix("/tvOS DeviceSupport") {
            return .safe(.developer, "旧设备调试符号,连接设备后会重建", oneClick: true)
        }
        if path.hasSuffix("/Library/Developer/CoreSimulator/Caches") {
            return .safe(.cache, "模拟器缓存,可重建", oneClick: true)
        }
        if path.hasSuffix("/Library/Developer/Xcode/Archives") {
            return .review(.developer, "Xcode 历史打包存档——确认不再需要上传/调试后可删。")
        }
        if path.hasSuffix("/Library/Developer/CoreSimulator/Devices") {
            return .review(.developer, "模拟器设备数据——删会重置所有模拟器(应用/数据清空)。")
        }

        // ── Package-manager caches / deps ──
        if name == "node_modules" {
            return .safe(.buildArtifact, "Node 依赖(node_modules),npm/yarn install 可重建", oneClick: true)
        }
        if name == ".gradle" { return .safe(.buildArtifact, "Gradle 缓存,可重建", oneClick: true) }
        if name == ".cache"  { return .safe(.cache, "用户级缓存(.cache),可重建", oneClick: true) }
        if name == ".npm"    { return .safe(.cache, "npm 缓存,可重建", oneClick: true) }
        if name == ".build"  { return .safe(.buildArtifact, "SwiftPM 构建目录(.build),可重建") }
        if name == ".cocoapods" || lpath.hasSuffix("/library/caches/cocoapods") {
            return .safe(.cache, "CocoaPods 缓存,可重建")
        }
        if name == "build" || name == "dist" {
            return .review(.buildArtifact, "可能是构建输出目录——确认无重要内容再删。")
        }

        // ── App updater downloads ──
        if name == "update.noindex" || lpath.contains("/updates.noindex") {
            return .review(.appData, "App 更新下载缓存,通常可删(下次需要会重下)。")
        }

        // ── Backups ──
        if path.hasSuffix("/Library/Application Support/MobileSync/Backup") {
            return .review(.backup, "iOS 设备备份——删前确认这些设备已不需要恢复。")
        }
        return nil
    }

    /// Recognizes common big files by path + extension and explains each in plain
    /// language. Conservative: only genuine rebuildables are `.safe`; personal /
    /// risky things are `.review` (with a helpful "what is this") or `.keep`.
    fileprivate static func classifyFile(_ url: URL, isPackage: Bool) -> Classification {
        let lpath = url.path.lowercased()
        let lname = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let inDownloads = lpath.contains("/downloads/")

        // ── Personal-critical: never suggest deleting ──
        if ext == "photoslibrary" {
            return .keep(.media, "「照片」图库——请在「照片」App 里管理,别在这里删。")
        }
        if lpath.contains("/library/mail/") || lpath.contains("/library/messages/")
            || lpath.contains("com.apple.mail") {
            return .keep(.appData, "邮件/信息数据——不建议删。")
        }

        // ── Virtual machine / container disks ──
        if lpath.contains("com.docker.docker"), ext == "raw" || lname == "docker.raw" {
            return .review(.virtualMachine, "Docker 虚拟磁盘:装着你所有 Docker 容器与镜像。删它会清空它们(之后可重新拉取/构建)。不用 Docker 才删。")
        }
        if ["vmdk", "vdi", "qcow2", "hdd", "pvm", "vmwarevm", "utm", "vbox"].contains(ext) {
            return .review(.virtualMachine, "虚拟机磁盘镜像:删了这台虚拟机的系统与数据就没了。确认不再需要再删。")
        }
        if lpath.contains("/claude/"), ext == "bundle" || lname.contains("vm") {
            return .review(.virtualMachine, "Claude 桌面版的虚拟机/运行时包,删后 App 会重新下载并初始化。")
        }

        // ── On-device AI models ──
        if lpath.contains("ondevicemodel") || lpath.contains("optguide") || lname == "weights.bin" {
            return .review(.model, "应用的设备端 AI 模型,删后需要时会自动重新下载。")
        }

        // ── System dynamic wallpaper videos ──
        if lpath.contains("com.apple.wallpaper"), ["mov", "mp4", "m4v"].contains(ext) {
            return .review(.media, "macOS 动态壁纸视频:删后对应壁纸会失效/需重新下载。")
        }

        // ── Crash / diagnostic dumps ──
        if ["hprof", "dmp", "core", "crash", "diag", "ips"].contains(ext) || lname.contains("java_error") {
            return .review(.log, "崩溃/内存转储(诊断产物),通常可安全删除。")
        }

        // ── Firmware / disk images / installers / archives ──
        if ext == "ipsw" {
            return .review(.download, "iOS/iPadOS 固件(刷机用),确认不再需要可删。")
        }
        if ["dmg", "pkg", "xip"].contains(ext) {
            return .review(.download, "\(inDownloads ? "下载的" : "")安装包/磁盘镜像,装好后通常可删。")
        }
        if ext == "iso" {
            return .review(.download, "光盘镜像(ISO),确认不再需要可删。")
        }
        if ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar"].contains(ext) {
            return .review(.download, "\(inDownloads ? "下载的" : "")压缩包,确认已解压/不需要后可删。")
        }

        // ── Personal media ──
        if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return .review(.media, "视频文件(个人文件)——确认是否还需要再删。")
        }
        if ["psd", "ai", "sketch", "fig", "tiff", "raw", "cr2", "arw", "nef", "dng"].contains(ext) {
            return .review(.media, "图片/设计源文件(个人文件)——请自行判断。")
        }

        // ── Fallbacks ──
        if isPackage {
            return .review(.largeFile, "大型程序包/资料库——没认出具体用途,请自行判断。")
        }
        return .review(.largeFile, "大文件——没认出具体用途,请自行判断是否需要。")
    }

    // MARK: Guards & sizing

    fileprivate static func isSystemPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for root in systemRoots where path == root || path.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    fileprivate static func shouldSkipDir(_ url: URL) -> Bool {
        switch url.lastPathComponent {
        case ".Trash": return true   // already "deleted"; moving it to trash is a no-op
        case ".git":   return true   // VCS internals — never a cleanup target, slow to walk
        default:       return false
        }
    }

    fileprivate static func allocatedSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    fileprivate static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func dirExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Sums allocated sizes under `url` (skipping symlinks). Cancellable.
    fileprivate static func directorySize(_ url: URL, token: ScanToken) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            if token.isCancelled { break }
            let v = try? f.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Orchestrator (main-actor, drives the UI)

/// Result of a move-to-Trash run.
struct TrashOutcome: Sendable {
    let removed: Int                 // items fully cleared
    let skipped: Int                 // items that couldn't be (fully) trashed
    let needsFullDiskAccess: Bool    // failures looked permission-related
}

@MainActor
final class DiskScanner: ObservableObject {
    @Published var items: [DiskScanItem] = []
    @Published var isScanning = false
    @Published var scannedCount = 0

    // User-controlled scan settings (bound from the view).
    @Published var range: ScanRange = .home
    @Published var thresholdMB: Int = 100

    private var activeToken: ScanToken?
    private let queue = DispatchQueue(label: "com.scrollshot.diskscan", qos: .utility)

    /// Whitelist sizes use Finder-style decimal MB (1 MB = 1,000,000 bytes).
    private var thresholdBytes: Int64 { Int64(thresholdMB) * 1_000_000 }

    func startScan() {
        cancelScan()
        let token = ScanToken()
        activeToken = token
        items = []
        scannedCount = 0
        isScanning = true

        let engine = DiskScanEngine(range: range, threshold: thresholdBytes)
        queue.async { [weak self] in
            engine.run(token: token) { events, scanned in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.activeToken === token else { return }
                        self.apply(events)
                        self.scannedCount = scanned
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.activeToken === token else { return }
                    self.isScanning = false
                    self.activeToken = nil
                }
            }
        }
    }

    /// Apply a batch of streamed events: add new rows, resolve "计算中…"
    /// placeholders in place (preserving the user's checkbox), or drop
    /// placeholders that came in under threshold. Keeps the list ordered with
    /// still-sizing rows pinned on top.
    private func apply(_ events: [DiskScanEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .item(let incoming):
                if let idx = items.firstIndex(where: { $0.url == incoming.url }) {
                    var updated = incoming
                    updated.isSelected = items[idx].isSelected
                    items[idx] = updated
                } else {
                    items.append(incoming)
                }
            case .removePath(let path):
                items.removeAll { $0.url.path == path }
            }
        }
        items.sort {
            if $0.isSizing != $1.isSizing { return $0.isSizing }   // placeholders on top
            return $0.size > $1.size
        }
    }

    func cancelScan() {
        activeToken?.cancel()
        activeToken = nil
        isScanning = false
    }

    /// Check every highest-confidence rebuildable item (the "一键清缓存" action).
    /// Does not delete anything — the user still confirms via "移到废纸篓".
    func selectOneClick() {
        for i in items.indices where items[i].oneClickEligible {
            items[i].isSelected = true
        }
    }

    func clearSelection() {
        for i in items.indices { items[i].isSelected = false }
    }

    var selectedItems: [DiskScanItem] { items.filter(\.isSelected) }
    var hasSelection: Bool { items.contains(where: \.isSelected) }
    var selectedTotalSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedTotalText: String {
        ByteCountFormatter.string(fromByteCount: selectedTotalSize, countStyle: .file)
    }

    /// Moves the selected items to the Trash (never permanent). For a folder that
    /// can't be moved whole (e.g. ~/Library/Caches has system-owned entries), it
    /// retries by trashing the folder's *contents* — so locked/protected items
    /// just get skipped instead of failing the whole batch.
    func moveSelectedToTrash(completion: @escaping @MainActor (TrashOutcome) -> Void) {
        let targets = items.filter { $0.isSelected && $0.safety != .keep }
        guard !targets.isEmpty else {
            completion(TrashOutcome(removed: 0, skipped: 0, needsFullDiskAccess: false)); return
        }

        NSWorkspace.shared.recycle(targets.map(\.url)) { [weak self] trashed1, error1 in
            let done1 = Set(trashed1.keys)
            // Directories that failed as a whole → retry by clearing their contents.
            let failed = targets.filter { !done1.contains($0.url) && $0.isDirectory }
            let retry: [(item: DiskScanItem, children: [URL])] = failed.map { item in
                let kids = (try? FileManager.default.contentsOfDirectory(
                    at: item.url, includingPropertiesForKeys: nil, options: [])) ?? []
                return (item, kids)
            }
            let childURLs = retry.flatMap(\.children)

            func finish(_ done2: Set<URL>, permission: Bool) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        var cleared = Set<UUID>()
                        var skipped = 0
                        for t in targets {
                            if done1.contains(t.url) { cleared.insert(t.id); continue }
                            if let entry = retry.first(where: { $0.item.id == t.id }),
                               !entry.children.isEmpty, entry.children.allSatisfy({ done2.contains($0) }) {
                                cleared.insert(t.id)
                            } else {
                                skipped += 1
                            }
                        }
                        self.items.removeAll { cleared.contains($0.id) }
                        completion(TrashOutcome(removed: cleared.count, skipped: skipped,
                                                needsFullDiskAccess: skipped > 0 && permission))
                    }
                }
            }

            let perm1 = Self.isPermissionError(error1)
            if childURLs.isEmpty {
                finish([], permission: perm1)
            } else {
                NSWorkspace.shared.recycle(childURLs) { trashed2, error2 in
                    finish(Set(trashed2.keys), permission: perm1 || Self.isPermissionError(error2))
                }
            }
        }
    }

    nonisolated static func isPermissionError(_ error: Error?) -> Bool {
        guard let e = error as NSError? else { return false }
        let codes: Set<Int> = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
        if e.domain == NSCocoaErrorDomain, codes.contains(e.code) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            return codes.contains(underlying.code)
        }
        return false
    }

    /// Best-effort Full Disk Access probe: TCC.db is only readable with FDA.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: probe.path)
    }
}
