import AppKit

/// 键盘事件监听:全局 + 本地两条 NSEvent monitor(只读观察,不需要辅助功能
/// 权限;安全输入框里的按键系统本来就不下发,属预期盲区)。
///
/// 监听只在诊断窗口打开期间运行——窗口开 = start,窗口关 = stop,
/// 不是一个常驻后台功能。
@MainActor
final class KeyChatterMonitor: ObservableObject {
    static let shared = KeyChatterMonitor()

    struct KeyRow: Identifiable, Equatable {
        let id: UInt16        // keyCode
        let name: String
        let presses: Int
        let bounces: Int
        let lastGapMs: Double?
    }

    struct BounceEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let key: String
        let gapMs: Double
    }

    @Published private(set) var running = false
    @Published private(set) var totalPresses = 0
    @Published private(set) var rows: [KeyRow] = []
    @Published private(set) var recentBounces: [BounceEntry] = []
    @Published var thresholdMs: Double = 40 {
        didSet { detector.thresholdMs = thresholdMs }
    }

    private var detector = KeyChatterDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyNames: [UInt16: String] = [:]
    private var lastSignature: String?

    /// 墙钟锚点，用于把 `NSEvent.timestamp`（开机以来的秒数）换算成 Date。
    ///
    /// 连击间隔**必须**用事件时间戳，不能用处理时间：SwiftUI 每来一个按键就
    /// 重绘一次表格，主线程一卡，积压的 keyUp/keyDown 会在一帧内被连续处理，
    /// 把真实相隔几百毫秒的两次按键压成 ~16ms，从而报出根本不存在的"硬件连击"。
    private let bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)

    private func eventDate(_ e: NSEvent) -> Date {
        bootDate.addingTimeInterval(e.timestamp)
    }

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        // 全局监视器覆盖其他应用里的击键(诊断的主要场景);本地监视器覆盖
        // 在诊断窗口自身里的击键。回调线程不保证主线程,统一 hop 回 MainActor。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            Task { @MainActor [weak self] in self?.handle(e) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        running = false
    }

    func reset() {
        detector.reset(thresholdMs: thresholdMs)
        totalPresses = 0
        rows = []
        recentBounces = []
        keyNames = [:]
    }

    /// 连击 ≥3 次的键:疑似硬件抖动。
    var suspectedKeyNames: [String] {
        detector.suspectedKeys().map { keyNames[$0] ?? "keyCode \($0)" }
    }

    private func handle(_ e: NSEvent) {
        // 去重：万一同一事件同时从两条通道进来（全局 + 本地），只处理一次。
        let signature = "\(e.type.rawValue)|\(e.keyCode)|\(e.timestamp)"
        if signature == lastSignature { return }
        lastSignature = signature

        let code = e.keyCode
        let at = eventDate(e)
        if e.type == .keyUp {
            detector.keyUp(code, at: at)
            return
        }
        keyNames[code] = keyNames[code] ?? Self.name(for: e)
        if let b = detector.keyDown(code, isRepeat: e.isARepeat, at: at) {
            let name = keyNames[code] ?? "keyCode \(code)"
            recentBounces.append(BounceEntry(at: b.at, key: name, gapMs: b.gapMs))
            if recentBounces.count > 100 { recentBounces.removeFirst(recentBounces.count - 100) }
            refreshRows()
        }
        totalPresses = detector.totalPresses
    }

    private func refreshRows() {
        rows = detector.perKey
            .map { code, stat in
                KeyRow(id: code,
                       name: keyNames[code] ?? "keyCode \(code)",
                       presses: stat.presses,
                       bounces: stat.bounces,
                       lastGapMs: detector.bounces.last { $0.keyCode == code }?.gapMs)
            }
            .sorted { $0.bounces != $1.bounces ? $0.bounces > $1.bounces : $0.presses > $1.presses }
    }

    /// 友好键名:可打印字符直接用字符,常见控制键给符号。
    static func name(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "⏎"
        case 48: return "⇥"
        case 49: return "␣"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let s = event.charactersIgnoringModifiers,
               let scalar = s.unicodeScalars.first, scalar.value >= 0x20,
               !CharacterSet.controlCharacters.contains(scalar) {
                return s
            }
            return "键\(event.keyCode)"
        }
    }
}
