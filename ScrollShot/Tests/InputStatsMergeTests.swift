import XCTest
@testable import ScrollShot

final class InputStatsMergeTests: XCTestCase {
    func testMergeSumsCounters() {
        let base = DailyInputStats(date: Calendar.current.startOfDay(for: Date()))
        var a = base
        a.keyPresses = 10
        a.leftClicks = 2
        a.rightClicks = 1
        a.mouseDistance = 100
        a.scrollDistance = 50
        a.keyPressCounts = ["A": 5, "B": 5]

        var b = base
        b.keyPresses = 20
        b.leftClicks = 3
        b.rightClicks = 2
        b.mouseDistance = 200
        b.scrollDistance = 80
        b.keyPressCounts = ["B": 3, "C": 7]

        let merged = a + b
        XCTAssertEqual(merged.keyPresses, 30)
        XCTAssertEqual(merged.leftClicks, 5)
        XCTAssertEqual(merged.rightClicks, 3)
        XCTAssertEqual(merged.mouseDistance, 300)
        XCTAssertEqual(merged.scrollDistance, 130)
        XCTAssertEqual(merged.keyPressCounts["A"], 5)
        XCTAssertEqual(merged.keyPressCounts["B"], 8)
        XCTAssertEqual(merged.keyPressCounts["C"], 7)
    }

    func testMergeEmptyDoesNotChangeStats() {
        let date = Calendar.current.startOfDay(for: Date())
        var a = DailyInputStats(date: date)
        a.keyPresses = 5
        let b = DailyInputStats(date: date)
        let merged = a + b
        XCTAssertEqual(merged.keyPresses, 5)
    }
}
