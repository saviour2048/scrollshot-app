import XCTest
@testable import ScrollShot

final class UsageLogScannerTests: XCTestCase {
    private var tmp: URL!
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 12))!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testEmptyRootHasNoData() {
        let summary = UsageLogScanner.scan(roots: [tmp], now: now)
        XCTAssertFalse(summary.hasData)
        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.entriesParsed, 0)
    }

    func testParsesAssistantUsageAndCost() throws {
        let ts = ISO8601DateFormatter().string(from: now)
        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg-1","model":"claude-sonnet-4-5-20261001","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":100}}}
        """
        let file = tmp.appendingPathComponent("session.jsonl")
        try line.write(to: file, atomically: true, encoding: .utf8)

        let summary = UsageLogScanner.scan(roots: [tmp], now: now)

        XCTAssertTrue(summary.hasData)
        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.entriesParsed, 1)
        XCTAssertEqual(summary.tokens30d, 1800)
        XCTAssertEqual(summary.latestDayTokens, 1800)
        XCTAssertEqual(summary.topModel, "Sonnet")

        let expectedCost = 1000 * 3e-6 + 500 * 15e-6 + 200 * 3.75e-6 + 100 * 0.3e-6
        XCTAssertEqual(summary.cost30d, expectedCost, accuracy: 1e-9)
        XCTAssertEqual(summary.todayCost, expectedCost, accuracy: 1e-9)
    }

    func testDuplicateMessageIdKeepsLastWrite() throws {
        let ts = ISO8601DateFormatter().string(from: now)
        let lines = [
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500}}}",
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":2000,\"output_tokens\":1000}}}"
        ]
        let file = tmp.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let summary = UsageLogScanner.scan(roots: [tmp], now: now)

        XCTAssertEqual(summary.entriesParsed, 1)
        XCTAssertEqual(summary.tokens30d, 3000)
        XCTAssertEqual(summary.latestDayTokens, 3000)
    }
}
