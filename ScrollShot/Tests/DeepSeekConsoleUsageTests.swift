import XCTest
@testable import ScrollShot

final class DeepSeekConsoleUsageTests: XCTestCase {
    private let todayStart = 1792704000

    // 按实测响应结构造的 cost 信封:两个模型,today 桶 + 昨天桶,
    // cost 字段字符串/number 混合
    private func costJSON() -> String {
        """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
          "start":\(todayStart - 29 * 86400),"end":\(todayStart + 86400),"bucket":86400,
          "models":[],"functions":[],
          "data":[{"currency":"CNY","series":[
            {"api_key":{"name":"default"},"model":"deepseek-v4-pro","buckets":[
              {"time":\(todayStart),"cost":"0.12"},
              {"time":\(todayStart - 86400),"cost":"1.00"}]},
            {"api_key":{"name":"default"},"model":"deepseek-chat","buckets":[
              {"time":\(todayStart),"cost":"0.50"},
              {"time":\(todayStart - 86400),"cost":0.25}]}
          ]}],"function_series":[]}}}
        """
    }

    // amount 的 series 直接挂在 biz_data 下(和 cost 的包法不同)
    private func amountJSON() -> String {
        """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
          "start":\(todayStart - 29 * 86400),"end":\(todayStart + 86400),"bucket":86400,
          "models":[],"series":[
            {"api_key":{"name":"default"},"model":"deepseek-v4-pro","buckets":[
              {"time":\(todayStart),"usage":{"RESPONSE_TOKEN":1000,"REQUEST":0,"PROMPT_CACHE_HIT_TOKEN":2000,"PROMPT_CACHE_MISS_TOKEN":3000}},
              {"time":\(todayStart - 86400),"usage":{"RESPONSE_TOKEN":500,"REQUEST":0,"PROMPT_CACHE_HIT_TOKEN":0,"PROMPT_CACHE_MISS_TOKEN":500}}
            ]}]}}}
        """
    }

    func testMergeCostAndAmount() throws {
        let snap = try DeepSeekConsoleUsageFetcher.merge(
            cost: Data(costJSON().utf8),
            amount: Data(amountJSON().utf8),
            todayStart: todayStart
        )
        XCTAssertEqual(snap.currency, "CNY")
        XCTAssertEqual(snap.todayCost, 0.62, accuracy: 1e-9)   // 0.12 + 0.50
        XCTAssertEqual(snap.cost30d, 1.87, accuracy: 1e-9)     // 0.12+1.00+0.50+0.25
        XCTAssertEqual(snap.todayTokens, 6000)                 // 1000+2000+3000
        XCTAssertEqual(snap.tokens30d, 7000)
        XCTAssertEqual(snap.topModel, "deepseek-v4-pro")       // 1.12 > 0.75
    }

    func testBizErrorEnvelope() {
        let json = """
        {"code":0,"msg":"","data":{"biz_code":1,"biz_msg":"INVALID_PARAM"}}
        """
        XCTAssertThrowsError(try DeepSeekConsoleUsageFetcher.merge(
            cost: Data(json.utf8), amount: Data(amountJSON().utf8), todayStart: todayStart
        )) { error in
            XCTAssertEqual(error as? DeepSeekConsoleUsageFetcher.ConsoleError, .biz("INVALID_PARAM"))
        }
    }

    func testGarbageThrowsParseError() {
        XCTAssertThrowsError(try DeepSeekConsoleUsageFetcher.merge(
            cost: Data("not json".utf8), amount: Data(amountJSON().utf8), todayStart: todayStart
        )) { error in
            XCTAssertEqual(error as? DeepSeekConsoleUsageFetcher.ConsoleError, .parse)
        }
        // 信封正常但两边都没有 series → 格式变更
        let empty = """
        {"code":0,"data":{"biz_code":0,"biz_msg":"","biz_data":{}}}
        """
        XCTAssertThrowsError(try DeepSeekConsoleUsageFetcher.merge(
            cost: Data(empty.utf8), amount: Data(empty.utf8), todayStart: todayStart
        )) { error in
            XCTAssertEqual(error as? DeepSeekConsoleUsageFetcher.ConsoleError, .parse)
        }
    }

    func testWindowParamsAlignsToLocalDay() {
        let tz = TimeZone(secondsFromGMT: 28800)!   // UTC+8
        let now = Date(timeIntervalSince1970: 1792577343)
        let p = DeepSeekConsoleUsageFetcher.windowParams(now: now, tz: tz)
        XCTAssertEqual(p.tzOffset, 28800)
        XCTAssertEqual(p.end - p.start, 30 * 86400)          // 含今天共 30 天
        XCTAssertEqual((p.start + p.tzOffset) % 86400, 0)    // 当地日界对齐
        XCTAssertEqual(p.todayStart, p.start + 29 * 86400)
        XCTAssertGreaterThanOrEqual(now.timeIntervalSince1970, Double(p.todayStart))
        XCTAssertLessThan(now.timeIntervalSince1970, Double(p.todayStart + 86400))

        // 具体值:UTC+8 下 epoch 0 的当地日界是 -28800
        let z = DeepSeekConsoleUsageFetcher.windowParams(now: Date(timeIntervalSince1970: 0), tz: tz)
        XCTAssertEqual(z.todayStart, -28800)
        XCTAssertEqual(z.end, 57600)

        // 负时区同样成立
        let tzWest = TimeZone(secondsFromGMT: -18000)!       // UTC-5
        let w = DeepSeekConsoleUsageFetcher.windowParams(now: now, tz: tzWest)
        XCTAssertEqual((w.start + w.tzOffset) % 86400, 0)
        XCTAssertGreaterThanOrEqual(now.timeIntervalSince1970, Double(w.todayStart))
        XCTAssertLessThan(now.timeIntervalSince1970, Double(w.todayStart + 86400))
    }

    func testErrorDescriptions() {
        XCTAssertTrue(DeepSeekConsoleUsageFetcher.ConsoleError.http(401).errorDescription!.contains("已过期"))
        XCTAssertTrue(DeepSeekConsoleUsageFetcher.ConsoleError.biz("INVALID_PARAM").errorDescription!.contains("INVALID_PARAM"))
    }
}
