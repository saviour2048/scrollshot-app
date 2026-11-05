import XCTest
@testable import ScrollShot

final class LauncherCalculatorTests: XCTestCase {
    func testBasicArithmetic() {
        XCTAssertEqual(LauncherCalculator.evaluate("1+2"), "3")
        XCTAssertEqual(LauncherCalculator.evaluate("2*3+4"), "10")
        XCTAssertEqual(LauncherCalculator.evaluate("10/4"), "2.5")
        XCTAssertEqual(LauncherCalculator.evaluate("2**10"), "1024")
    }

    func testFunctionsAndConstants() {
        XCTAssertEqual(LauncherCalculator.evaluate("sqrt(16)"), "4")
        XCTAssertEqual(LauncherCalculator.evaluate("pi"), "3.141593")
    }

    func testInvalidExpressionsReturnNil() {
        XCTAssertNil(LauncherCalculator.evaluate("safari"))
        XCTAssertNil(LauncherCalculator.evaluate("hello+world"))
        XCTAssertNil(LauncherCalculator.evaluate(""))
    }

    func testPlainWordsReturnNil() {
        XCTAssertNil(LauncherCalculator.evaluate("prefs"))
        XCTAssertNil(LauncherCalculator.evaluate("1password"))
    }

    func testUnicodeOperators() {
        XCTAssertEqual(LauncherCalculator.evaluate("3×4"), "12")
        XCTAssertEqual(LauncherCalculator.evaluate("10÷2"), "5")
    }

    func testFormatting() {
        XCTAssertEqual(LauncherCalculator.evaluate("1/3"), "0.333333")
        XCTAssertEqual(LauncherCalculator.evaluate("2.5"), "2.5")
        XCTAssertEqual(LauncherCalculator.evaluate("42"), "42")
    }
}
