import XCTest
@testable import ScrollShot

final class SmartPasteTerminalEntryTests: XCTestCase {

    func testPlainBundleIDHasNoGate() {
        let parsed = SmartPasteController.parseTerminalEntry("com.example.MyTerminal")
        XCTAssertEqual(parsed.bundleID, "com.example.MyTerminal")
        XCTAssertNil(parsed.requiredClass)
    }

    func testGatedEntrySplitsOnPipe() {
        let parsed = SmartPasteController.parseTerminalEntry("md.obsidian|xterm")
        XCTAssertEqual(parsed.bundleID, "md.obsidian")
        XCTAssertEqual(parsed.requiredClass, "xterm")
    }

    func testTrailingPipeYieldsNoGate() {
        let parsed = SmartPasteController.parseTerminalEntry("md.obsidian|")
        XCTAssertEqual(parsed.bundleID, "md.obsidian")
        XCTAssertNil(parsed.requiredClass)
    }
}
