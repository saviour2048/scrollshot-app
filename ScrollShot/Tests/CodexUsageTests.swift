import XCTest
@testable import ScrollShot

final class CodexUsageTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // 2026-10-21 实测的真实响应结构(primary = 5 小时窗口,secondary = 7 天窗口)
    func testParsesRealResponse() throws {
        let json = """
        {
          "email": "user@example.com", "plan_type": "plus",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window":   { "used_percent": 17, "limit_window_seconds": 18000, "reset_after_seconds": 17524, "reset_at": 1792577343 },
            "secondary_window": { "used_percent": 3,  "limit_window_seconds": 604800, "reset_after_seconds": 604324, "reset_at": 1793164143 }
          },
          "credits": { "has_credits": false, "unlimited": false, "balance": "0" }
        }
        """
        let snap = try CodexUsageFetcher.parse(data: Data(json.utf8))

        XCTAssertEqual(snap.planType, "plus")
        XCTAssertEqual(snap.email, "user@example.com")

        let primary = try XCTUnwrap(snap.primary)
        XCTAssertEqual(primary.usedPercent, 17)
        XCTAssertEqual(primary.remainingPercent, 83)
        XCTAssertEqual(primary.resetAt, Date(timeIntervalSince1970: 1792577343))
        XCTAssertEqual(primary.windowSeconds, 18000)

        let secondary = try XCTUnwrap(snap.secondary)
        XCTAssertEqual(secondary.usedPercent, 3)
        XCTAssertEqual(secondary.remainingPercent, 97)
        XCTAssertEqual(secondary.resetAt, Date(timeIntervalSince1970: 1793164143))
        XCTAssertEqual(secondary.windowSeconds, 604800)

        XCTAssertFalse(snap.hasCredits)
        XCTAssertFalse(snap.creditsUnlimited)
        XCTAssertEqual(snap.creditsBalance, "0")
    }

    func testToleratesMissingFieldsAndStringNumbers() throws {
        let json = """
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":"42"}}}
        """
        let snap = try CodexUsageFetcher.parse(data: Data(json.utf8))

        XCTAssertEqual(snap.planType, "pro")
        XCTAssertNil(snap.email)
        let primary = try XCTUnwrap(snap.primary)
        XCTAssertEqual(primary.usedPercent, 42)
        XCTAssertEqual(primary.remainingPercent, 58)
        XCTAssertNil(primary.resetAt)
        XCTAssertNil(primary.windowSeconds)
        XCTAssertNil(snap.secondary)
        XCTAssertFalse(snap.hasCredits)
        XCTAssertNil(snap.creditsBalance)
    }

    func testGarbageThrowsParseError() {
        XCTAssertThrowsError(try CodexUsageFetcher.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? CodexUsageFetcher.CodexError, .parse)
        }
        // 合法 JSON 但没有任何可解析窗口 → 视为接口格式变更
        XCTAssertThrowsError(try CodexUsageFetcher.parse(data: Data("{\"foo\":1}".utf8))) { error in
            XCTAssertEqual(error as? CodexUsageFetcher.CodexError, .parse)
        }
    }

    func testLoadAuthRequiresChatGPTModeAndTokens() throws {
        let valid = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"at","account_id":"acc","refresh_token":"rt"},"last_refresh":"2026-10-21T00:00:00Z"}
        """
        let validURL = tmp.appendingPathComponent("auth.json")
        try valid.write(to: validURL, atomically: true, encoding: .utf8)
        let auth = try XCTUnwrap(CodexSettings.loadAuth(from: validURL))
        XCTAssertEqual(auth, CodexAuth(accessToken: "at", accountID: "acc", refreshToken: "rt"))

        // API key 模式不适用
        let apiKeyMode = """
        {"auth_mode":"apikey","tokens":{"access_token":"at","account_id":"acc"}}
        """
        let apiKeyURL = tmp.appendingPathComponent("auth-apikey.json")
        try apiKeyMode.write(to: apiKeyURL, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexSettings.loadAuth(from: apiKeyURL))

        // tokens 缺失 / 为空
        let noTokens = """
        {"auth_mode":"chatgpt"}
        """
        let noTokensURL = tmp.appendingPathComponent("auth-notokens.json")
        try noTokens.write(to: noTokensURL, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexSettings.loadAuth(from: noTokensURL))

        // 文件不存在
        XCTAssertNil(CodexSettings.loadAuth(from: tmp.appendingPathComponent("missing.json")))
    }
}
