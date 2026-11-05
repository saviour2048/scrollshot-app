import XCTest
@testable import ScrollShot

final class DeepSeekBalanceTests: XCTestCase {
    // 官方文档示例响应
    func testParsesDocExample() throws {
        let json = """
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "10.00", "granted_balance": "1.00", "topped_up_balance": "9.00"}]}
        """
        let snap = try DeepSeekBalanceFetcher.parse(data: Data(json.utf8))

        XCTAssertTrue(snap.isAvailable)
        XCTAssertEqual(snap.balances.count, 1)
        let b = snap.balances[0]
        XCTAssertEqual(b.currency, "CNY")
        XCTAssertEqual(b.total, "10.00")
        XCTAssertEqual(b.granted, "1.00")
        XCTAssertEqual(b.toppedUp, "9.00")
    }

    func testMultiCurrencyAndUnavailable() throws {
        let json = """
        {"is_available": false, "balance_infos": [
          {"currency": "CNY", "total_balance": "0.10", "granted_balance": "0.10", "topped_up_balance": "0.00"},
          {"currency": "USD", "total_balance": "5.00", "granted_balance": "0.00", "topped_up_balance": "5.00"}
        ]}
        """
        let snap = try DeepSeekBalanceFetcher.parse(data: Data(json.utf8))

        XCTAssertFalse(snap.isAvailable)
        XCTAssertEqual(snap.balances.map(\.currency), ["CNY", "USD"])
        XCTAssertEqual(snap.balances[1].total, "5.00")
    }

    func testToleratesNumberAmountsAndMissingFields() throws {
        let json = """
        {"balance_infos": [{"currency": "CNY", "total_balance": 10.5}]}
        """
        let snap = try DeepSeekBalanceFetcher.parse(data: Data(json.utf8))

        // is_available 缺失默认 true;granted/topped_up 缺失补 "0"
        XCTAssertTrue(snap.isAvailable)
        XCTAssertEqual(snap.balances[0].total, "10.5")
        XCTAssertEqual(snap.balances[0].granted, "0")
        XCTAssertEqual(snap.balances[0].toppedUp, "0")
    }

    func testGarbageThrowsParseError() {
        XCTAssertThrowsError(try DeepSeekBalanceFetcher.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? DeepSeekBalanceFetcher.DeepSeekError, .parse)
        }
        // 合法 JSON 但没有 balance_infos → 视为格式变更
        XCTAssertThrowsError(try DeepSeekBalanceFetcher.parse(data: Data("{\"foo\":1}".utf8))) { error in
            XCTAssertEqual(error as? DeepSeekBalanceFetcher.DeepSeekError, .parse)
        }
        // balance_infos 是空数组同样视为格式变更
        XCTAssertThrowsError(try DeepSeekBalanceFetcher.parse(data: Data("{\"is_available\":true,\"balance_infos\":[]}".utf8))) { error in
            XCTAssertEqual(error as? DeepSeekBalanceFetcher.DeepSeekError, .parse)
        }
    }
}
