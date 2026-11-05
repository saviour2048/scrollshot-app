import Foundation

/// 键盘连击(机械轴抖动,chatter)判定器。纯逻辑、时间戳注入,供单测直接驱动。
///
/// 抖动特征:一次物理按下产生 keyDown→keyUp→keyDown→keyUp 两次闭合,第二次
/// keyDown 距第一次 keyUp 通常 < 20ms。需要排除两种正常情况:
/// - 按住不放的系统键重复:isRepeat == true,且中间没有 keyUp;
/// - 人有意快速双击同一字母(如 "ll"):间隔一般 > 60ms。
/// 默认阈值 40ms(可在窗口里调):两次完整击键的"抬→按"间隔 ≤ 阈值记一次连击。
final class KeyChatterDetector {
    struct Bounce: Equatable {
        let keyCode: UInt16
        let gapMs: Double
        let at: Date
    }

    var thresholdMs: Double
    private(set) var totalPresses = 0
    private(set) var bounces: [Bounce] = []
    /// keyCode → (总按下, 连击)
    private(set) var perKey: [UInt16: (presses: Int, bounces: Int)] = [:]

    private var isDown: [UInt16: Bool] = [:]
    private var lastUpAt: [UInt16: Date] = [:]

    init(thresholdMs: Double = 40) { self.thresholdMs = thresholdMs }

    /// 返回判定出的连击(若有)。isRepeat 的系统重复与缺 keyUp 的异常序列不算。
    @discardableResult
    func keyDown(_ keyCode: UInt16, isRepeat: Bool, at: Date = Date()) -> Bounce? {
        guard !isRepeat else { return nil }
        guard isDown[keyCode] != true else { return nil }
        isDown[keyCode] = true
        totalPresses += 1
        var stat = perKey[keyCode] ?? (presses: 0, bounces: 0)
        stat.presses += 1

        var bounce: Bounce?
        if let up = lastUpAt[keyCode] {
            let gapMs = at.timeIntervalSince(up) * 1000
            if gapMs >= 0, gapMs <= thresholdMs {
                let b = Bounce(keyCode: keyCode, gapMs: gapMs, at: at)
                bounces.append(b)
                stat.bounces += 1
                bounce = b
            }
        }
        perKey[keyCode] = stat
        return bounce
    }

    func keyUp(_ keyCode: UInt16, at: Date = Date()) {
        isDown[keyCode] = false
        lastUpAt[keyCode] = at
    }

    /// 连击次数达到 minBounces 的键判定为疑似硬件抖动(单键偶发一次可能是
    /// 人打得快,同一键反复出现才是真信号)。
    func suspectedKeys(minBounces: Int = 3) -> [UInt16] {
        perKey.filter { $0.value.bounces >= minBounces }.map(\.key).sorted()
    }

    func reset(thresholdMs: Double? = nil) {
        if let thresholdMs { self.thresholdMs = thresholdMs }
        totalPresses = 0
        bounces = []
        perKey = [:]
        isDown = [:]
        lastUpAt = [:]
    }
}
