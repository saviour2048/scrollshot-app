import XCTest
@testable import ScrollShot

final class MenuBarLayoutTests: XCTestCase {

    private func sample(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, screen: UInt32? = 1) -> MenuBarItemSample {
        MenuBarItemSample(screenID: screen, frame: CGRect(x: x, y: y, width: w, height: 33))
    }

    /// 三个项并排、都在屏幕上（2026-10-28 实测：宽 76、间距 84、y = 1048）。
    func testSeparateItemsNotCrowded() {
        let samples = [sample(872, 1048, 76), sample(948, 1048, 76), sample(1024, 1048, 76)]
        XCTAssertFalse(MenuBarLayoutClassifier.isCrowded(samples))
    }

    /// 某一项只剩停在 (0,−33) 的影子窗口 → 被折叠。
    func testParkedItemIsCrowded() {
        let samples = [sample(948, 1048, 76), sample(0, -33, 76, screen: nil)]
        XCTAssertTrue(MenuBarLayoutClassifier.isCrowded(samples))
    }

    /// 窗口存在但停在菜单栏外（y ≤ 1）也算没显示。
    func testItemBelowMenuBarIsCrowded() {
        XCTAssertTrue(MenuBarLayoutClassifier.isCrowded([sample(948, 0, 76)]))
    }

    /// macOS 27 的叠罗汉：两个项的窗口右边界重合（实测 7 个窗口都在 x=636）。
    func testPiledItemsAreCrowded() {
        let samples = [sample(636, 1048, 76), sample(636, 1048, 76)]
        XCTAssertTrue(MenuBarLayoutClassifier.isCrowded(samples))
    }

    /// 重叠不到一半不算（项窗口自带 ~16pt 横向留白）。
    func testSmallOverlapIsNotCrowded() {
        let samples = [sample(900, 1048, 76), sample(950, 1048, 76)]   // 重叠 26pt < 38pt
        XCTAssertFalse(MenuBarLayoutClassifier.isCrowded(samples))
    }

    /// 不同显示器上的窗口坐标可以相同，不能当成叠罗汉。
    func testSameCoordinatesOnDifferentScreensNotCrowded() {
        let samples = [sample(0, 1048, 76, screen: 1), sample(0, 1048, 76, screen: 2)]
        XCTAssertFalse(MenuBarLayoutClassifier.isCrowded(samples))
    }

    /// 刚创建时窗口停在 (0,0) 的占位帧不能当成"被折叠"（2026-10-28 实测，
    /// 启动瞬间会有一轮这样的采样）。
    func testPlaceholderFramesAreIgnored() {
        let placeholder = MenuBarItemSample(screenID: 1, frame: CGRect(x: 0, y: 0, width: 55, height: 33))
        XCTAssertFalse(MenuBarLayoutClassifier.isCrowded([placeholder]))
        // 占位帧＋真正被折叠的项 → 仍然算拥挤
        XCTAssertTrue(MenuBarLayoutClassifier.isCrowded([placeholder, sample(0, -33, 76, screen: nil)]))
    }

    func testDeciderNeedsTwoConsecutiveStrikes() {
        var d = MenuBarMergeDecider()
        XCTAssertFalse(d.observe(crowded: true))
        XCTAssertTrue(d.observe(crowded: true))
        // 合并后计数清零
        XCTAssertFalse(d.observe(crowded: true))
    }

    func testDeciderResetsAfterClearSample() {
        var d = MenuBarMergeDecider()
        XCTAssertFalse(d.observe(crowded: true))
        XCTAssertFalse(d.observe(crowded: false))
        XCTAssertFalse(d.observe(crowded: true))
        XCTAssertTrue(d.observe(crowded: true))
    }
}

/// 「模拟刘海」几何测试：用假数据模拟 MacBook Air 的辅助区
/// （1470pt 屏、刘海左右各 645pt），断言数值条永远落在刘海左边、
/// 不与其相交。0.8.74~0.8.83 的真 bug（锚点用了刘海右沿）在这组断言下会红。
final class MenuBarNotchGeometryTests: XCTestCase {
    /// 13" Air：可用左区 [0,645]，右区 [825,1470]，刘海 [645,825]。
    private let air = MenuBarNotchGeometry(
        leftArea: CGRect(x: 0, y: 0, width: 645, height: 32),
        rightArea: CGRect(x: 825, y: 0, width: 645, height: 32))

    func testNotchComesFromBothAuxiliaryAreas() throws {
        let notch = try XCTUnwrap(air.notch)
        XCTAssertEqual(notch.minX, 645)   // 左沿 = 左区 maxX
        XCTAssertEqual(notch.maxX, 825)   // 右沿 = 右区 minX
        XCTAssertEqual(notch.width, 180)
    }

    func testStripNeverIntersectsNotch() throws {
        let notch = try XCTUnwrap(air.notch)
        for width in [40.0, 120.0, 240.0, 400.0] {
            let strip = try XCTUnwrap(air.stripFrame(width: width, height: 20))
            XCTAssertTrue(strip.intersection(notch).isNull,
                          "宽 \(width) 的小条与刘海相交: \(strip) vs \(notch)")
            XCTAssertEqual(strip.maxX, notch.minX - 10, "右边缘应离刘海左沿 10pt")
        }
    }

    func testNoNotchMeansNoStrip() {
        let plain = MenuBarNotchGeometry(leftArea: nil, rightArea: nil)
        XCTAssertNil(plain.notch)
        XCTAssertNil(plain.stripFrame(width: 100, height: 20))
    }

    func testDegenerateAreasDoNotCrash() {
        // 右区从刘海左沿开始（宽度 0 的刘海）→ 视为无效，宁可不画
        let broken = MenuBarNotchGeometry(
            leftArea: CGRect(x: 0, y: 0, width: 645, height: 32),
            rightArea: CGRect(x: 645, y: 0, width: 645, height: 32))
        XCTAssertNil(broken.notch)
        XCTAssertNil(broken.stripFrame(width: 100, height: 20))
    }
}
