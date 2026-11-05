import XCTest
@testable import ScrollShot

final class UsageMeterMappingTests: XCTestCase {
    /// 各来源都有数据的快照:
    /// Claude session 剩 75% / 周剩 50%;Kimi 短周期剩 60% / 周剩 90%;
    /// Codex 5小时剩 80% / 周剩 95%;OpenCode 滚动剩 29% / 周剩 48%;今日花费 $1.50。
    private func fullSnapshot() -> UsageSnapshot {
        var snap = UsageSnapshot.empty
        snap.limits = UsageLimits(session: UsageWindow(utilization: 25, resetsAt: nil),
                                  weekly: UsageWindow(utilization: 50, resetsAt: nil))
        snap.kimi = KimiSnapshot(weekly: KimiWindowUsage(limit: 100, used: 10, resetAt: nil),
                                 rate: KimiWindowUsage(limit: 10, used: 4, resetAt: nil),
                                 rateLabel: "5 小时")
        snap.codex = CodexSnapshot(planType: "plus",
                                   primary: CodexWindowUsage(usedPercent: 20, resetAt: nil, windowSeconds: 18000),
                                   secondary: CodexWindowUsage(usedPercent: 5, resetAt: nil, windowSeconds: 604800))
        snap.opencode = OpenCodeUsageSnapshot(
            rolling: OpenCodeWindowUsage(usedPercent: 71, resetAt: nil),
            weekly: OpenCodeWindowUsage(usedPercent: 52, resetAt: nil),
            monthly: OpenCodeWindowUsage(usedPercent: 26, resetAt: nil))
        snap.cost = CostSummary(todayCost: 1.5)
        return snap
    }

    private func assertColumn(_ slot: MenuBarSlot, _ metric: MenuBarMetric,
                              _ expectedTop: String, _ expectedBottom: String,
                              snap: UsageSnapshot, placeholder: String = "—",
                              file: StaticString = #filePath, line: UInt = #line) {
        let col = UsageMeterMapping.column(slot, metric: metric, snap: snap, placeholder: placeholder)
        XCTAssertEqual(col.top, expectedTop, file: file, line: line)
        XCTAssertEqual(col.bottom, expectedBottom, file: file, line: line)
    }

    func testSessionWeeklyPerSlot() {
        let snap = fullSnapshot()
        assertColumn(.claude, .sessionWeekly, "75%", "50%", snap: snap)
        assertColumn(.kimi, .sessionWeekly, "60%", "90%", snap: snap)
        assertColumn(.codex, .sessionWeekly, "80%", "95%", snap: snap)
        assertColumn(.opencode, .sessionWeekly, "29%", "48%", snap: snap)
    }

    func testSessionAndWeeklyPickShortAndLongWindow() {
        let snap = fullSnapshot()
        assertColumn(.codex, .session, "80%", "", snap: snap)
        assertColumn(.codex, .weekly, "95%", "", snap: snap)
        assertColumn(.kimi, .session, "60%", "", snap: snap)
        assertColumn(.kimi, .weekly, "90%", "", snap: snap)
        assertColumn(.opencode, .session, "29%", "", snap: snap)
        assertColumn(.opencode, .weekly, "48%", "", snap: snap)
    }

    func testTodayCostOnlyClaudeHasData() {
        let snap = fullSnapshot()
        // 货币符号随测试机 locale 变($/US$),只校验数字部分
        let claude = UsageMeterMapping.column(.claude, metric: .todayCost, snap: snap)
        XCTAssertTrue(claude.top.hasSuffix("1.50"))
        XCTAssertEqual(claude.bottom, "")
        // Kimi/Codex 没有花费估算,固定 "—"
        assertColumn(.kimi, .todayCost, "—", "", snap: snap)
        assertColumn(.codex, .todayCost, "—", "", snap: snap)
    }

    func testNoneAndIconOnlyAreEmpty() {
        let snap = fullSnapshot()
        for metric in MenuBarMetric.allCases {
            assertColumn(.none, metric, "", "", snap: snap)
            assertColumn(.claude, .iconOnly, "", "", snap: snap)
        }
    }

    func testMissingDataUsesPlaceholder() {
        let snap = UsageSnapshot.empty
        // sessionWeekly 始终 "—" 占位
        assertColumn(.codex, .sessionWeekly, "—", "—", snap: snap, placeholder: "")
        // 单列(placeholder "")session/weekly 缺失时留空;双列("—")占位
        assertColumn(.claude, .session, "", "", snap: snap, placeholder: "")
        assertColumn(.claude, .session, "—", "", snap: snap, placeholder: "—")
        assertColumn(.claude, .todayCost, "—", "", snap: snap, placeholder: "—")
    }

    // MARK: DeepSeek slot

    private func deepseekSnapshot() -> UsageSnapshot {
        var snap = UsageSnapshot.empty
        snap.deepseek = DeepSeekBalanceSnapshot(isAvailable: true, balances: [
            .init(currency: "CNY", total: "12.30", granted: "0", toppedUp: "12.30"),
        ])
        snap.deepseekUsage = DeepSeekUsageSnapshot(todayCost: 0.45, cost30d: 9.9,
                                                   todayTokens: 1000, tokens30d: 20000,
                                                   topModel: nil, currency: "CNY")
        return snap
    }

    func testDeepSeekSessionWeeklyIsBalanceOverTodaySpend() {
        let snap = deepseekSnapshot()
        assertColumn(.deepseek, .sessionWeekly, "¥12.30", "-¥0.45", snap: snap)
    }

    func testDeepSeekSingleLineMetrics() {
        let snap = deepseekSnapshot()
        assertColumn(.deepseek, .session, "¥12.30", "", snap: snap)
        assertColumn(.deepseek, .todayCost, "-¥0.45", "", snap: snap)
        assertColumn(.deepseek, .iconOnly, "", "", snap: snap)
    }

    func testDeepSeekMissingDataPlaceholders() {
        // 余额与今日消耗是两个独立 pipeline,各自缺数据各自占位
        var snap = UsageSnapshot.empty
        snap.deepseek = DeepSeekBalanceSnapshot(isAvailable: true, balances: [
            .init(currency: "USD", total: "3.00", granted: "0", toppedUp: "3.00"),
        ])
        assertColumn(.deepseek, .sessionWeekly, "$3.00", "—", snap: snap)
        snap = UsageSnapshot.empty
        assertColumn(.deepseek, .sessionWeekly, "—", "—", snap: snap)
    }

    func testTemplatesAreFixedPerSlotAndMetric() {
        // 固定宽度契约:模板不随数值变化,只随 slot × metric 变化
        XCTAssertEqual(UsageMeterMapping.template(for: .deepseek, metric: .sessionWeekly), "¥000.00\n-¥00.00")
        XCTAssertEqual(UsageMeterMapping.template(for: .kimi, metric: .sessionWeekly), "100%\n100%")
        XCTAssertEqual(UsageMeterMapping.template(for: .claude, metric: .todayCost), "$000.00")
        XCTAssertNil(UsageMeterMapping.template(for: .none, metric: .sessionWeekly))
        XCTAssertNil(UsageMeterMapping.template(for: .claude, metric: .iconOnly))
    }

    // MARK: compactMoney 定宽契约

    func testCompactMoneyFitsBudget() {
        for v in [0.0, 0.01, 1.23, 12.34, 123.45, 999.99, 1234.5, 12345.6, 999999.0] {
            let s = UsageFormat.compactMoney(v, symbol: "¥", maxChars: 7)
            XCTAssertLessThanOrEqual(s.count, 7, "\(v) → \(s) 超宽")
        }
        XCTAssertEqual(UsageFormat.compactMoney(12.3, symbol: "¥", maxChars: 7), "¥12.30")
        XCTAssertEqual(UsageFormat.compactMoney(12345.6, symbol: "¥", maxChars: 7), "¥12346")
    }
}
