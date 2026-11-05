import XCTest
@testable import ScrollShot

final class KeyChatterDetectorTests: XCTestCase {
    private var detector: KeyChatterDetector!
    private let keyA: UInt16 = 0    // "a"
    private let keyL: UInt16 = 37   // "l"

    override func setUp() {
        super.setUp()
        detector = KeyChatterDetector(thresholdMs: 40)
    }

    /// 正常打字:每次按下间隔 > 阈值,不应有任何连击。
    func testNormalTypingProducesNoBounces() {
        var t = Date()
        for _ in 0..<50 {
            detector.keyDown(keyA, isRepeat: false, at: t)
            t += 0.05   // 按住 50ms
            detector.keyUp(keyA, at: t)
            t += 0.1    // 间隔 100ms 再按
        }
        XCTAssertEqual(detector.totalPresses, 50)
        XCTAssertTrue(detector.bounces.isEmpty)
        XCTAssertTrue(detector.suspectedKeys().isEmpty)
    }

    /// 抖动特征:up→down 间隔 8ms,应判定连击。
    func testShortGapIsBounce() {
        let t0 = Date()
        detector.keyDown(keyA, isRepeat: false, at: t0)
        detector.keyUp(keyA, at: t0 + 0.06)
        let bounce = detector.keyDown(keyA, isRepeat: false, at: t0 + 0.068)
        XCTAssertNotNil(bounce)
        XCTAssertEqual(bounce?.gapMs ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(detector.perKey[keyA]?.bounces, 1)
    }

    /// 按住不放的系统重复(isRepeat,无 keyUp)不算连击。
    func testKeyRepeatIsNotBounce() {
        let t0 = Date()
        detector.keyDown(keyA, isRepeat: false, at: t0)
        for i in 1...20 {
            detector.keyDown(keyA, isRepeat: true, at: t0 + Double(i) * 0.03)
        }
        detector.keyUp(keyA, at: t0 + 0.7)
        XCTAssertTrue(detector.bounces.isEmpty)
        XCTAssertEqual(detector.totalPresses, 1)
    }

    /// 有意快速双击(间隔 80ms,超阈值)不算连击。
    func testIntentionalDoubleTapAboveThreshold() {
        let t0 = Date()
        detector.keyDown(keyL, isRepeat: false, at: t0)
        detector.keyUp(keyL, at: t0 + 0.05)
        detector.keyDown(keyL, isRepeat: false, at: t0 + 0.13)  // 80ms 间隔
        detector.keyUp(keyL, at: t0 + 0.18)
        XCTAssertTrue(detector.bounces.isEmpty)
    }

    /// 同一键 ≥3 次连击进入疑似列表;偶发一两次不进。
    func testSuspectedKeysNeedThreeBounces() {
        var t = Date()
        func bouncePress(_ key: UInt16) {
            detector.keyDown(key, isRepeat: false, at: t)
            detector.keyUp(key, at: t + 0.05)
            detector.keyDown(key, isRepeat: false, at: t + 0.055)  // 5ms 间隔
            detector.keyUp(key, at: t + 0.09)
            t += 1
        }
        bouncePress(keyA)
        bouncePress(keyA)
        XCTAssertTrue(detector.suspectedKeys().isEmpty)
        bouncePress(keyA)
        bouncePress(keyL)
        XCTAssertEqual(detector.suspectedKeys(), [keyA])
    }

    /// 阈值可调:放宽到 100ms 后,80ms 间隔也应判为连击。
    func testThresholdIsConfigurable() {
        detector.thresholdMs = 100
        let t0 = Date()
        detector.keyDown(keyL, isRepeat: false, at: t0)
        detector.keyUp(keyL, at: t0 + 0.05)
        XCTAssertNotNil(detector.keyDown(keyL, isRepeat: false, at: t0 + 0.13))
    }
}
