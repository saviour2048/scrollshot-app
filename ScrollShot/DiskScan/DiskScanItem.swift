import Foundation

/// How confident we are that an item is safe to remove. Drives the badge and
/// whether the row is selectable / swept by "one-click cache clean".
enum DiskItemSafety: Sendable {
    /// Rebuildable / discardable. Gets the "可安全删除" badge.
    case safe
    /// Shown, selectable, but unchecked by default — the user must judge.
    case review
    /// Never suggest deleting (system / unknown-important). Not selectable.
    case keep
}

/// What kind of thing this is — used for the category tag and the reason text.
enum DiskItemCategory: Sendable {
    case cache          // 应用缓存
    case buildArtifact  // 构建产物 / 依赖
    case developer      // Xcode / 开发者数据
    case download       // 下载 / 安装包 / 压缩包
    case backup         // 设备备份
    case virtualMachine // 虚拟机 / 容器磁盘
    case model          // 设备端 AI 模型
    case media          // 个人媒体(视频/图片)
    case appData        // 应用数据
    case log            // 日志 / 诊断转储
    case largeFile      // 其他大文件
    case system         // 系统(只展示)

    var label: String {
        switch self {
        case .cache:          return "缓存"
        case .buildArtifact:  return "构建产物"
        case .developer:      return "开发者"
        case .download:       return "下载"
        case .backup:         return "备份"
        case .virtualMachine: return "虚拟机"
        case .model:          return "AI 模型"
        case .media:          return "媒体"
        case .appData:        return "应用数据"
        case .log:            return "日志"
        case .largeFile:      return "大文件"
        case .system:         return "系统"
        }
    }
}

/// One row in the disk-scan results: a large file or an aggregated directory.
struct DiskScanItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Allocated size in bytes (aggregate for directories).
    let size: Int64
    let modified: Date?
    let category: DiskItemCategory
    let safety: DiskItemSafety
    /// One-line, human reason for the safety verdict.
    let reason: String
    /// Eligible for the "一键清缓存" batch — only the highest-confidence rebuildables.
    let oneClickEligible: Bool

    /// User has checked this row for removal. Defaults off (nothing pre-selected).
    var isSelected: Bool = false

    /// True while a known reclaimable item is shown as a placeholder and its
    /// size is still being computed (progressive display).
    var isSizing: Bool = false

    /// e.g. "1.2 GB"
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Path with the home directory abbreviated to `~`.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.deletingLastPathComponent().path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// e.g. "2026-06-10"
    var modifiedText: String {
        guard let modified else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: modified)
    }
}
