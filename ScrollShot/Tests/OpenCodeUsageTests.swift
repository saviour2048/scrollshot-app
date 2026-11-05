import XCTest
@testable import ScrollShot

final class OpenCodeUsageTests: XCTestCase {
    /// 2026-11-04 用真实 key 实测的响应原文(删到单窗口粒度的最小完整样本)。
    private let realBody = """
    {"usage":{
      "rolling":{"status":"ok","percent":71,"resetsAt":"2026-11-04T12:31:30.000Z"},
      "weekly":{"status":"ok","percent":52,"resetsAt":"2026-11-09T00:00:00.000Z"},
      "monthly":{"status":"ok","percent":26,"resetsAt":"2026-12-04T01:15:54.000Z"}}
    }
    """

    func testParseRealResponse() throws {
        let snap = try OpenCodeUsageFetcher.parse(data: Data(realBody.utf8))
        XCTAssertEqual(snap.rolling?.usedPercent, 71)
        XCTAssertEqual(snap.rolling?.remainingPercent, 29)
        XCTAssertFalse(snap.rolling?.rateLimited ?? true)
        XCTAssertEqual(snap.weekly?.usedPercent, 52)
        XCTAssertEqual(snap.monthly?.usedPercent, 26)
        // ISO8601 带毫秒能解析出正确的绝对时间
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: snap.weekly?.resetAt ?? Date())
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 11)
        XCTAssertEqual(comps.day, 9)
    }

    func testRateLimitedForcesFullUsage() throws {
        let json = """
        {"usage":{"rolling":{"status":"rate-limited","percent":37,"resetsAt":"2026-11-04T12:31:30.000Z"},
        "weekly":{"status":"ok","percent":52,"resetsAt":"2026-11-09T00:00:00.000Z"}}}
        """
        let snap = try OpenCodeUsageFetcher.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.rolling?.usedPercent, 100)   // 不信 37,限流即用满
        XCTAssertEqual(snap.rolling?.remainingPercent, 0)
        XCTAssertTrue(snap.rolling?.rateLimited ?? false)
        XCTAssertNil(snap.monthly)                        // 缺失窗口宽容为 nil
    }

    func testNoFractionSecondsStillParses() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"2026-11-04T12:31:30Z"}}}
        """
        let snap = try OpenCodeUsageFetcher.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.rolling?.usedPercent, 10)
        XCTAssertNotNil(snap.rolling?.resetAt)
    }

    func testErrorBodyAndGarbageThrowParse() {
        // 401 的错误体(不会到 parse,但解析层也不该把它当成功)
        let errBody = "{\"type\":\"error\",\"error\":{\"type\":\"AuthError\",\"message\":\"Unauthorized\"}}"
        XCTAssertThrowsError(try OpenCodeUsageFetcher.parse(data: Data(errBody.utf8))) { e in
            XCTAssertEqual(e as? OpenCodeUsageFetcher.OpenCodeError, .parse)
        }
        XCTAssertThrowsError(try OpenCodeUsageFetcher.parse(data: Data("not json".utf8))) { e in
            XCTAssertEqual(e as? OpenCodeUsageFetcher.OpenCodeError, .parse)
        }
        // 三个窗口全没有 = 接口格式变更
        XCTAssertThrowsError(try OpenCodeUsageFetcher.parse(data: Data("{\"usage\":{}}".utf8))) { e in
            XCTAssertEqual(e as? OpenCodeUsageFetcher.OpenCodeError, .parse)
        }
    }

    func testSettingsLoadAuthFromTempFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("auth.json")

        // 1) 合法 opencode-go 条目 → 读出 key
        let good = """
        {"opencode-go":{"type":"api","key":"oc_sk_abcdefghij"},"deepseek":{"type":"api","key":"sk-other"}}
        """
        try good.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(OpenCodeSettings.loadAuth(from: url), "oc_sk_abcdefghij")

        // 2) 只有别的 provider / key 为空 → nil
        let noGo = "{\"deepseek\":{\"type\":\"api\",\"key\":\"sk-other\"}}"
        try noGo.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(OpenCodeSettings.loadAuth(from: url))

        let emptyKey = "{\"opencode-go\":{\"type\":\"api\",\"key\":\"\"}}"
        try emptyKey.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(OpenCodeSettings.loadAuth(from: url))

        // 3) 文件不存在 → nil(不炸)
        let missing = dir.appendingPathComponent("nope.json")
        XCTAssertNil(OpenCodeSettings.loadAuth(from: missing))
    }
}
