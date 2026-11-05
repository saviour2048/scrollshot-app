import AppKit

/// 一个菜单栏项在某一刻的窗口状态。
struct MenuBarItemSample: Equatable {
    /// 该项窗口所在的屏 id；nil = 只剩停在 (0,-33) 的影子窗口，也就是这一项
    /// 根本没有真正显示出来（被系统折叠了）。
    let screenID: UInt32?
    let frame: CGRect

    /// 刚创建还没被系统摆位的占位帧（实测：原点 (0,0)、宽度已定）。
    /// 这种采样不能算「被折叠」，否则启动/重建瞬间会误判。
    var isPlaceholder: Bool { frame.origin == .zero && frame.width > 0 }

    /// 真的画在菜单栏上（而不是影子窗口、也不是占位帧）。
    var isShown: Bool { screenID != nil && frame.minY > 1 && !isPlaceholder }
}

/// 判定「此刻菜单栏不够用」。两条判据都来自 2026-10-28 在 macOS 27.0.1 上的
/// 最小 demo 实测（1920pt 单屏，40 个 60pt 的状态项）：
///
/// - 空间够（3 项）：每项 1 个真实窗口 + 1 个常驻影子窗口停在 (0,−33)。
/// - 空间不够（40 项）：只有 12 个真实窗口留下，28 项的两个窗口都停在 (0,−33)；
///   留下的项里还有 7 个被系统叠在同一个 x（叠罗汉 bug）。
///
/// 所以：有项只剩影子窗口 → 被折叠；同屏两个真实窗口横向重叠超过一半 → 叠罗汉。
enum MenuBarLayoutClassifier {
    static func isCrowded(_ samples: [MenuBarItemSample]) -> Bool {
        // 占位帧（还没摆位）不参与判定，等下一次采样（2s 后）再说。
        let known = samples.filter { !$0.isPlaceholder }
        guard !known.isEmpty else { return false }
        if known.contains(where: { !$0.isShown }) { return true }
        for i in known.indices {
            for j in known.indices where j > i {
                let a = known[i], b = known[j]
                guard let sid = a.screenID, sid == b.screenID else { continue }
                let overlap = a.frame.intersection(b.frame)
                if !overlap.isNull, overlap.width > min(a.frame.width, b.frame.width) / 2 {
                    return true
                }
            }
        }
        return false
    }
}

/// 刘海几何（与 NSScreen 解耦，便于用假数据做单测与离屏渲染模拟）。
///
/// 语义陷阱（0.8.74~0.8.83 的真 bug）：`auxiliaryTopRightArea` 是刘海**右边**
/// 那块区域，它的 `minX` 是刘海**右沿**；刘海左沿是 `auxiliaryTopLeftArea.maxX`。
struct MenuBarNotchGeometry: Equatable {
    /// `NSScreen.auxiliaryTopLeftArea`（刘海左边那块，App 菜单区）。
    var leftArea: CGRect?
    /// `NSScreen.auxiliaryTopRightArea`（刘海右边那块，状态项区）。
    var rightArea: CGRect?

    /// 刘海本身占据的区间：左沿 = 左区右边界，右沿 = 右区左边界。
    var notch: CGRect? {
        guard let l = leftArea, let r = rightArea, r.minX > l.maxX else { return nil }
        return CGRect(x: l.maxX, y: l.minY, width: r.minX - l.maxX, height: max(l.height, r.height))
    }

    /// 贴刘海左边画数值条时，小条（宽 width、高 height）应落的 frame。
    /// 右边缘至少离刘海左沿 10pt，绝不与刘海相交。
    func stripFrame(width: CGFloat, height: CGFloat) -> CGRect? {
        guard let notch else { return nil }
        return CGRect(x: notch.minX - width - 10, y: notch.minY, width: width, height: height)
    }
}

/// 合并的防抖：连续 N 次采样都「拥挤」才合并，避免换屏 / 登录瞬间的占位帧误判。
/// （每次采样间隔 ≈ 传感器 tick 2s）
struct MenuBarMergeDecider {
    var strikesRequired = 2
    private(set) var strikes = 0

    /// 返回 true = 现在该合并。
    mutating func observe(crowded: Bool) -> Bool {
        guard crowded else { strikes = 0; return false }
        strikes += 1
        guard strikes >= strikesRequired else { return false }
        strikes = 0
        return true
    }

    mutating func reset() { strikes = 0 }
}

/// 从我们自己的 NSStatusItem 上取几何，供判定与现场取证用。
@MainActor
enum MenuBarLayoutProbe {
    static func samples(for items: [NSStatusItem]) -> [MenuBarItemSample] {
        items.map { item in
            guard let window = item.button?.window, let screen = window.screen else {
                return MenuBarItemSample(screenID: nil, frame: .zero)
            }
            return MenuBarItemSample(screenID: screenID(of: screen), frame: window.frame)
        }
    }

    /// 状态项可用的左边界（全局坐标）：有刘海的屏要跳过刘海区域。
    static func statusAreaLeftEdge(of screen: NSScreen) -> CGFloat {
        (screen.auxiliaryTopRightArea?.minX) ?? screen.frame.minX
    }

    /// 状态项可用的宽度：有刘海的屏只有右半边；外接屏就是整块屏宽。
    static func statusAreaWidth(of screen: NSScreen) -> CGFloat {
        (screen.auxiliaryTopRightArea?.width) ?? screen.frame.width
    }

    static func screenID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 现场取证开关：`SCROLLSHOT_MENUBAR_PROBE=1` 启动时，把每次采样追加到
    /// `/tmp/scrollshot-menubar.log`，用来在真实双屏场景下核对判定是否成立。
    static let loggingEnabled = ProcessInfo.processInfo.environment["SCROLLSHOT_MENUBAR_PROBE"] == "1"
    private static let logPath = "/tmp/scrollshot-menubar.log"

    /// 我们 App 全部状态栏窗口（含各屏 replicant），用来排查「哪块屏上被折叠」。
    static func allStatusWindows() -> [(UInt32?, CGRect)] {
        NSApp.windows
            .filter { $0.className.contains("StatusBar") }
            .map { ($0.screen.map(screenID(of:)), $0.frame) }
    }

    /// 按屏判定「有没有挤爆」：把每个屏的窗口分组，任意一组里两个窗口横向重叠
    /// 超过一半就算挤（macOS 27 的叠罗汉），存在停在屏外的影子项也算。
    ///
    /// 过滤掉两类无害窗口：
    /// - `screen == nil`：常驻影子窗口，永远在 (0,−33)；
    /// - `x == 0` 且贴在菜单栏高度上：这一项没有被摆到这块屏（实测：非主屏上
    ///   我们所有项都停在 x=0，而同一时刻那些项在别的屏上是正常显示的）。
    static func isAnyDisplayCrowded(_ windows: [(UInt32?, CGRect)]) -> Bool {
        var byScreen: [UInt32: [CGRect]] = [:]
        for (sid, frame) in windows {
            guard let sid else { continue }
            guard frame.minX > 1 else { continue }
            byScreen[sid, default: []].append(frame)
        }
        for (_, frames) in byScreen {
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let overlap = frames[i].intersection(frames[j])
                    if !overlap.isNull, overlap.width > min(frames[i].width, frames[j].width) / 2 {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func log(_ samples: [MenuBarItemSample], crowded: Bool, merged: Bool) {
        guard loggingEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var parts = ["\(stamp) merged=\(merged ? 1 : 0) crowded=\(crowded ? 1 : 0)"]
        for (i, s) in samples.enumerated() {
            parts.append("item\(i)=[screen:\(s.screenID.map(String.init) ?? "nil") x:\(Int(s.frame.minX)) y:\(Int(s.frame.minY)) w:\(Int(s.frame.width))]")
        }
        let wins = allStatusWindows().map { "\($0.0.map(String.init) ?? "nil")@\(Int($0.1.minX)),\(Int($0.1.minY)),\(Int($0.1.width))" }
        parts.append("windows=" + wins.joined(separator: "|"))
        let line = parts.joined(separator: " ") + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}
