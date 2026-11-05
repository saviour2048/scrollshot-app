import AppKit
import ImageIO

/// 暂存架图片 → 终端的图片附件搬运工。
///
/// 问题：暂存架拖出的条目只带 fileURL，终端收到后插入的是「路径文本」，
/// 而 Claude Code / Kimi CLI 的图片附件走剪贴板位图（Ctrl+V）。本 helper 在
/// 「图片被拖到终端窗口」时把图片以 PNG 写进剪贴板，用户随即 Cmd+V / Ctrl+V
/// 即可贴成附件（配合 SmartPaste 时两个键等效）。剪贴板旧内容可从剪贴板历史
/// 找回，不会真正丢失。
enum ShelfImageCopy {

    /// 视为图片的文件扩展名（小写）。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "webp", "tiff", "tif",
    ]

    /// 一个暂存架条目里所有可解码为图片的本地文件路径。
    /// - `.image` 条目：暂存架自己存的图片文件；
    /// - `.file` 条目：路径里按扩展名筛出的图片文件（可多个）。
    static func imagePaths(for item: ShelfItem, imageURL: URL?) -> [String] {
        switch item.kind {
        case .image:
            return imageURL.map { [$0.path] } ?? []
        case .file:
            return (item.filePaths ?? []).filter {
                imageExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }
        case .text:
            return []
        }
    }

    /// 把若干图片文件以 PNG 写进通用剪贴板（每张图一个 pasteboard item）。
    /// 返回成功写入的张数；解码失败的文件跳过。
    @discardableResult
    static func copyToPasteboard(paths: [String]) -> Int {
        let items: [NSPasteboardItem] = paths.compactMap { path in
            guard let png = pngData(forFileAtPath: path) else { return nil }
            let pb = NSPasteboardItem()
            pb.setData(png, forType: .png)
            return pb
        }
        guard !items.isEmpty else { return 0 }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        return items.count
    }

    /// 落点处最上层窗口的所属 App（排除自身），用于判断拖放目标是终端。
    /// `screenPoint` 是 Cocoa 屏幕坐标（左下原点），CGWindowList 用 Quartz
    /// 坐标（主屏左上原点），这里做一次 Y 翻转。
    static func destinationApp(atScreenPoint screenPoint: NSPoint) -> (bundleID: String, pid: pid_t)? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(quartzPoint),
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier
            else { continue }
            return (bundleID, pid)
        }
        return nil
    }

    /// 读图并转成 PNG 数据（HEIC 等格式经 ImageIO 解码，CLI 端统一收 PNG）。
    private static func pngData(forFileAtPath path: String) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
