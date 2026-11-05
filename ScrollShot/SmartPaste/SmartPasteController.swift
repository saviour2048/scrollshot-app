import AppKit
import CoreGraphics
import os

/// 「智能粘贴」：在终端 App 里让 Ctrl+V 和 Cmd+V 都按剪贴板内容自动选择粘贴方式。
///
/// 背景：Claude Code CLI 里 Ctrl+V 会把剪贴板里的图片贴成附件，但它不认
/// Cmd+V 贴图；而纯文字又得用 Cmd+V。用户要记两个键。本模块在终端前台时
/// 拦截「恰好只有 Ctrl 的 V」和「恰好只有 Cmd 的 V」：
///   - Ctrl+V + 剪贴板有位图 → 放行，交给 CLI 原生处理；
///   - Ctrl+V + 单个图片文件 → 先把剪贴板重写成纯位图（复用 ShelfImageCopy）
///     再放行——实测(2026-10-22) Kimi CLI 对文件剪贴板只贴路径引用，
///     哪怕剪贴板同时带着位图数据；旧剪贴板内容可从剪贴板历史找回；
///   - Ctrl+V + 无位图、有纯文字（含非图片文件路径）→ 吞掉，合成一个 Cmd+V 贴文字；
///   - Cmd+V + 剪贴板有位图 / 单个图片文件 → 吞掉，（图片文件先转位图再）
///     合成一个 Ctrl+V 贴图（终端本来就贴不了图，转给 CLI 处理只有收益。
///     代价：单个图片文件失去 Cmd+V 贴路径的原生行为，要贴路径可拖入终端）；
///   - Cmd+V + 文字 → 放行，走终端原生粘贴；
///   - 剪贴板为空 → 放行，保留 shell readline 的 quoted-insert 原义（Ctrl+V）
///     和终端原生行为（Cmd+V）。
///
/// 与 KeyboardRemapper / BrightnessKeyInterceptor 一样，本类不自建 tap，
/// 只作为共享 InputEventTap 的一个消费者注册（需要辅助功能权限）。
@MainActor
final class SmartPasteController {
    static let shared = SmartPasteController()

    nonisolated private static let enabledKey = "smartPaste.enabled"
    /// 追加自定义终端 bundleID 的 UserDefaults 键（字符串数组），例如：
    /// `defaults write com.scrollshot.app smartPaste.extraTerminalBundleIDs -array com.example.MyTerminal`
    nonisolated private static let extraTerminalsKey = "smartPaste.extraTerminalBundleIDs"

    /// 自己合成的 ⌘V 打的标记，事件再次流经自己的 tap 时据此放行（防递归）。
    nonisolated private static let sourceMarker: Int64 = 0x5353_5056  // "SSPV"

    nonisolated private static let log = Logger(subsystem: "com.scrollshot.app", category: "smartPaste")

    /// 内置终端列表。追加自定义终端请用上面的 extraTerminalsKey，不改代码。
    nonisolated private static let builtInTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
    ]

    /// 内置的「条件终端」：bundleID -> 焦点元素（或其祖先）AXDOMClassList 必须包含的类名。
    /// 用于「整个 App 不是终端、但内嵌了终端面板」的容器：
    ///   - Obsidian（md.obsidian）的终端面板是 xterm.js（类名含 "xterm"）；
    ///     笔记编辑器是 CodeMirror（cm-content），不会命中，编辑器里 Cmd+V 贴图保持原生。
    /// extras 条目同样支持 "bundleID|requiredClass" 语法追加自定义条件终端。
    nonisolated private static let builtInGatedTerminals: [String: String] = [
        "md.obsidian": "xterm",
    ]

    /// 已执行过 AXManualAccessibility 激活的 pid。Chromium/Electron 的 AX 子树是惰性
    /// 启用的，不设这个属性读到的 web 内容是空的。只在主 runloop（事件回调）访问。
    nonisolated(unsafe) private static var axActivatedPIDs = Set<pid_t>()

    /// 剪贴板上的位图类型。与 ClipboardMonitor.imageTypes 保持一致口径；
    /// 这里只做「是/否」判断，不解码数据。
    nonisolated private static let bitmapTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif",
        "public.heic", "public.heif", "public.bmp", "public.webp",
    ]

    /// 功能开关（默认开）。只读写 UserDefaults；真正的注册/注销走 start()/stop()，
    /// 由 FeatureSwitches.apply 驱动，避免 setter 里注册导致引用计数重复。
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 共享 InputEventTap 分发时的快速门槛（每个 keyDown 都会问到，保持便宜）。
    nonisolated var isActive: Bool { Self.isEnabled }

    private var registered = false

    nonisolated private init() {}

    /// 按当前开关状态注册为共享事件 tap 的用户。幂等。
    func start() {
        guard !registered, Self.isEnabled else { return }
        // 无辅助功能权限时 tap 起不来；registerTapUser 失败会内部回滚计数，
        // 但那样 stop() 的 unregister 会减掉别人的计数，所以这里先自行把关。
        guard InputEventTap.shared.isAccessibilityGranted() else {
            Self.log.notice("smartPaste enabled but accessibility not granted — not registering")
            return
        }
        InputEventTap.shared.registerTapUser()
        registered = true
        Self.log.info("smartPaste started")
    }

    func stop() {
        guard registered else { return }
        InputEventTap.shared.unregisterTapUser()
        registered = false
        Self.log.info("smartPaste stopped")
    }

    // MARK: - Event handling

    /// 由 InputEventTap 分发（回调跑在主 runloop 上，可直接读 NSPasteboard /
    /// NSWorkspace）。返回 nil 表示吞掉事件。
    nonisolated func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // 先跑最便宜的门槛：类型、键码、防递归标记。
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 9,  // kVK_ANSI_V
              event.getIntegerValueField(.eventSourceUserData) != Self.sourceMarker
        else { return Unmanaged.passRetained(event) }

        // 恰好只有一个修饰键：Ctrl 或 Cmd（无另一个/Shift/Option）；Caps Lock / Fn 不影响判定。
        let flags = event.flags
        let hasCtrl = flags.contains(.maskControl)
        let hasCmd = flags.contains(.maskCommand)
        guard hasCtrl != hasCmd,
              flags.intersection([.maskShift, .maskAlternate]).isEmpty
        else { return Unmanaged.passRetained(event) }

        // 只在终端前台时拦截。
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              Self.isTerminal(bundleID, pid: frontApp.processIdentifier)
        else { return Unmanaged.passRetained(event) }

        let kind = Self.clipboardKind()

        // 多个文件(Finder 复制 N 个): CLI 原生 Ctrl+V 吃不了多个 file-url,
        // 终端原生 Cmd+V 也贴不出文本(Finder 复制不带 string 类型)——
        // 吞掉按键, 直接键入全部路径文本(效果同拖放进终端)。
        if case .multipleFiles(let paths) = kind {
            Self.typeText(Self.quotedPaths(paths))
            Self.log.debug("smartPaste: multi-file → type \(paths.count) paths")
            return nil
        }

        if hasCmd {
            // Cmd+V：剪贴板是图（位图 / 单个图片文件）时接管——终端原生
            // Cmd+V 贴不了图，转成 Ctrl+V 让 CLI 贴成附件；文字放行走原生。
            switch kind {
            case .image:
                Self.postControlV()
                Self.log.debug("smartPaste: ⌘V → ⌃V (image paste)")
                return nil
            case .singleImageFile(let path):
                Self.convertImageFileToBitmap(path)
                Self.postControlV()
                Self.log.debug("smartPaste: ⌘V → ⌃V (image file → bitmap)")
                return nil
            default:
                return Unmanaged.passRetained(event)
            }
        }

        switch kind {
        case .image:
            // 剪贴板是位图：放行 Ctrl+V，CLI 原生把图片贴成附件。
            return Unmanaged.passRetained(event)
        case .singleImageFile(let path):
            // 单个图片文件：先重写成纯位图剪贴板再放行——Kimi 对文件剪贴板
            // 只贴路径引用，转位图后 Ctrl+V 才能贴成图片附件。
            Self.convertImageFileToBitmap(path)
            Self.log.debug("smartPaste: ⌃V image file → bitmap clipboard, pass through")
            return Unmanaged.passRetained(event)
        case .empty:
            // 剪贴板为空或单个非图片文件：放行——保留 readline quoted-insert
            // 和终端原生 Cmd+V 贴路径。
            return Unmanaged.passRetained(event)
        case .text:
            Self.postCommandV()
            Self.log.debug("smartPaste: ⌃V → ⌘V (text paste)")
            return nil
        case .multipleFiles:
            return nil  // 上面已处理
        }
    }

    /// 把单个图片文件重写成纯位图(PNG)剪贴板（复用暂存架的编码）。
    /// 解码失败时剪贴板不动，放行后 CLI 按文件处理（贴路径），不丢功能。
    nonisolated private static func convertImageFileToBitmap(_ path: String) {
        ShelfImageCopy.copyToPasteboard(paths: [path])
    }

    // MARK: - 判定

    /// 把 "bundleID" 或 "bundleID|requiredClass" 拆成判定条目。
    /// requiredClass 非空时，还需焦点元素的 AXDOMClassList 命中该类名才算终端。
    nonisolated static func parseTerminalEntry(_ entry: String) -> (bundleID: String, requiredClass: String?) {
        guard let sep = entry.firstIndex(of: "|") else { return (entry, nil) }
        let bundleID = String(entry[entry.startIndex..<sep])
        let token = String(entry[entry.index(after: sep)...])
        return (bundleID, token.isEmpty ? nil : token)
    }

    /// 判定前台/指定 App 是否为终端（含条件终端的 AX 门控）。internal：暂存架
    /// 的「拖到终端自动复制图片」复用同一判定。
    nonisolated static func isTerminal(_ bundleID: String, pid: pid_t) -> Bool {
        if builtInTerminals.contains(bundleID) { return true }
        if let token = builtInGatedTerminals[bundleID] {
            return focusedElementHasClass(pid: pid, token: token)
        }
        let extra = UserDefaults.standard.stringArray(forKey: extraTerminalsKey) ?? []
        for entry in extra {
            let parsed = parseTerminalEntry(entry)
            guard parsed.bundleID == bundleID else { continue }
            if let token = parsed.requiredClass {
                return focusedElementHasClass(pid: pid, token: token)
            }
            return true
        }
        return false
    }

    /// 焦点元素（含祖先链）的 AXDOMClassList 是否包含 token。
    /// 任何一步失败（无焦点、AX 未激活、属性缺失）都返回 false —— 宁可不拦截，
    /// 也不能在 Obsidian 编辑器里把原生 Cmd+V 贴图吞掉。
    nonisolated private static func focusedElementHasClass(pid: pid_t, token: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        if axActivatedPIDs.insert(pid).inserted {
            // Chromium/Electron 惰性启用 AX 子树，第一次查询前必须先开。
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, true as CFTypeRef)
        }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value
        else { return false }
        var current: AXUIElement? = (element as! AXUIElement)
        var depth = 0
        while let el = current, depth < 12 {
            var classValue: AnyObject?
            if AXUIElementCopyAttributeValue(el, "AXDOMClassList" as CFString, &classValue) == .success,
               let classes = classValue as? [String],
               classes.contains(where: { $0.contains(token) }) {
                return true
            }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(el, "AXParent" as CFString, &parent) == .success,
                  let p = parent
            else { return false }
            current = (p as! AXUIElement)
            depth += 1
        }
        return false
    }

    enum ClipboardKind: Equatable {
        case image                  // 位图（非文件）
        case text                   // 纯文字
        case empty                  // 空、单个非图片文件、或两者都无
        case singleImageFile(String)  // 单个图片文件：先转位图剪贴板再贴
        case multipleFiles([String])  // 2+ 个文件：键入全部路径文本
    }

    /// 只读 type 列表，不实际取数据——事件路径上一次 pasteboard 读开销可接受。
    nonisolated private static func clipboardKind() -> ClipboardKind {
        let types = Set((NSPasteboard.general.types ?? []).map { $0.rawValue })
        let isFile = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
        // 有文件才需要读 URL 列表(稍重); 其它情况不读数据。
        let paths = isFile ? filePathsOnClipboard() : []
        return classifyClipboard(types: types, filePaths: paths)
    }

    /// 纯分类, 便于测试。注意: Finder 复制文件除了 file-url / 图标位图,
    /// 还可能附带文件名 string 类型(2026-10-22 实测 macOS 26 如此; 2026-10-20
    /// 的实测没有)——所以"有文件"必须先于 string 判定, 否则单文件会被误判成
    /// .text, Ctrl+V 被换成 Cmd+V 贴出文件名文本, 图片文件永远贴不上。
    nonisolated static func classifyClipboard(types: Set<String>, filePaths: [String]) -> ClipboardKind {
        let isFile = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
            || !filePaths.isEmpty
        if filePaths.count > 1 {
            return .multipleFiles(filePaths)
        }
        if isFile {
            // 单个图片文件单独归类(即使附带文件名 string / 图标位图)——
            // Kimi 对文件剪贴板只贴路径引用, 需要先转成纯位图再贴。
            if let path = filePaths.first,
               ShelfImageCopy.imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                return .singleImageFile(path)
            }
            // 单个非图片文件: 放行, 终端原生 Cmd+V 贴路径。
            return .empty
        }
        if !types.isDisjoint(with: bitmapTypes) {
            return .image
        }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) {
            return .text
        }
        return .empty
    }

    /// 剪贴板上的文件路径列表(file URL)。
    nonisolated private static func filePathsOnClipboard() -> [String] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { $0.isFileURL }.map(\.path)
    }

    /// 多文件路径 → 键入文本: 每个路径双引号包裹、空格分隔(与终端拖放一致),
    /// 内部的 " 和 \ 做转义。
    nonisolated static func quotedPaths(_ paths: [String]) -> String {
        paths.map { path in
            let escaped = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    // MARK: - 合成按键

    /// 吞掉物理 Ctrl+V 后补一个 Cmd+V（keyDown + keyUp）。
    nonisolated private static func postCommandV() {
        postMarkedV(flags: .maskCommand)
    }

    /// 吞掉物理 Cmd+V 后补一个 Ctrl+V（keyDown + keyUp）。
    nonisolated private static func postControlV() {
        postMarkedV(flags: .maskControl)
    }

    /// 吞掉物理按键后直接把文本"键入"前台终端: 逐段合成无修饰键的按键事件,
    /// Unicode 字符串由 CGEventKeyboardSetUnicodeString 携带(不受键盘布局影响,
    /// 支持中文路径)。分段是防止超长字符串在个别 App 里丢失。
    nonisolated private static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 20
        var offset = 0
        while offset < units.count {
            let chunk = Array(units[offset..<min(offset + chunkSize, units.count)])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            // 无修饰键: 我们自己的 tap 只拦 Ctrl/Cmd+V, 不会误回收; marker 双保险。
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.sourceMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.sourceMarker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            offset += chunkSize
        }
    }

    private nonisolated static func postMarkedV(flags: CGEventFlags) {        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.sourceMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.sourceMarker)
        // 不能 post 到 .cghidEventTap：物理按住的修饰键会在 HID 层合并回来
        // （Ctrl+V 变 ⌃⌘V，见 KeyboardRemapper.postArrow 的同类注释——
        // 那里恰恰依赖这个合并）。post 到 session tap 则按我们设置的 flags 原样
        // 投递；事件会再次流经自己的 tap，靠 sourceMarker 放行。
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
