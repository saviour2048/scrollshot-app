import XCTest
@testable import ScrollShot

/// Snapshot tests for the hook-protocol translation: event JSON + user
/// decision → the exact JSON the bridge relays to each CLI's stdout.
final class AgentBridgeProtocolsTests: XCTestCase {

    private func event(_ json: String) -> JSONValue {
        guard let value = JSONValue.parse(Data(json.utf8)) else {
            XCTFail("test event is not valid JSON: \(json)")
            return .null
        }
        return value
    }

    private func replyStdout(_ response: AgentBridgeProtocols.BridgeResponse) -> String? {
        guard case .reply(let stdout, let exitCode) = response else { return nil }
        XCTAssertEqual(exitCode, 0)
        return stdout
    }

    private func replyJSON(_ response: AgentBridgeProtocols.BridgeResponse) -> [String: Any]? {
        guard let stdout = replyStdout(response) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
    }

    private let claudeBashPermission = """
    {"source":"claude","hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf build/"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build/"}],"behavior":"allow","destination":"session"}]}
    """

    // MARK: Claude permission

    func testClaudeAllow() {
        let model = AgentBridgeProtocols.cardModel(for: event(claudeBashPermission))
        XCTAssertEqual(model.interaction, .permission)
        XCTAssertEqual(model.detail, "rm -rf build/")
        let json = replyJSON(AgentBridgeProtocols.response(decision: .allow, for: model))
        let hook = json?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hook?["hookEventName"] as? String, "PermissionRequest")
        let decision = hook?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertNil(decision?["updatedPermissions"])
    }

    func testClaudeAllowAlwaysEchoesPermissionSuggestions() {
        let model = AgentBridgeProtocols.cardModel(for: event(claudeBashPermission))
        let json = replyJSON(AgentBridgeProtocols.response(decision: .allowAlways, for: model))
        let decision = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        let updated = decision?["updatedPermissions"] as? [[String: Any]]
        XCTAssertEqual(updated?.count, 1)
        XCTAssertEqual(updated?.first?["type"] as? String, "addRules")
        XCTAssertEqual(updated?.first?["destination"] as? String, "session")
    }

    func testClaudeDeny() {
        let model = AgentBridgeProtocols.cardModel(for: event(claudeBashPermission))
        let json = replyJSON(AgentBridgeProtocols.response(decision: .deny(message: "太危险"), for: model))
        let decision = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertEqual(decision?["message"] as? String, "太危险")
    }

    // MARK: Codex permission

    func testCodexNeverEmitsReservedPermissionFields() {
        let codexEvent = claudeBashPermission.replacingOccurrences(of: "\"claude\"", with: "\"codex\"")
        let model = AgentBridgeProtocols.cardModel(for: event(codexEvent))
        let json = replyJSON(AgentBridgeProtocols.response(decision: .allowAlways, for: model))
        let decision = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertNil(decision?["updatedPermissions"])
        XCTAssertNil(decision?["updatedInput"])
    }

    // MARK: AskUserQuestion

    private let askEvent = """
    {"source":"claude","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Deploy","question":"Which targets?","options":[{"label":"Preview","description":"测试环境"},{"label":"Production"}],"multiSelect":true}]}}
    """

    func testAskUserQuestionMultiSelectAnswer() {
        let model = AgentBridgeProtocols.cardModel(for: event(askEvent))
        XCTAssertEqual(model.interaction, .question)
        XCTAssertEqual(model.questions.count, 1)
        XCTAssertEqual(model.questions.first?.multiSelect, true)
        XCTAssertEqual(model.questions.first?.options.map(\.label), ["Preview", "Production"])

        let json = replyJSON(AgentBridgeProtocols.response(
            decision: .answer(selections: ["Which targets?": ["Preview", "Production"]], customs: [:]), for: model))
        let hook = json?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hook?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hook?["permissionDecision"] as? String, "allow")
        let updated = hook?["updatedInput"] as? [String: Any]
        let answers = updated?["answers"] as? [String: Any]
        // 多选拼成 ", " 字符串;question 文本与 header 双键 alias。
        XCTAssertEqual(answers?["Which targets?"] as? String, "Preview, Production")
        XCTAssertEqual(answers?["Deploy"] as? String, "Preview, Production")
        // 原 questions 保留在 updatedInput 里
        XCTAssertNotNil(updated?["questions"])
        // decision.updatedInput 同步携带
        let decision = hook?["decision"] as? [String: Any]
        XCTAssertNotNil(decision?["updatedInput"])
    }

    func testAskUserQuestionSingleSelect() {
        let single = """
        {"source":"claude","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Continue?","options":[{"label":"Yes"},{"label":"No"}]}]}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(single))
        let json = replyJSON(AgentBridgeProtocols.response(decision: .answer(selections: ["Continue?": ["Yes"]], customs: [:]), for: model))
        let answers = ((json?["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Continue?"] as? String, "Yes")
    }

    // MARK: dsh

    func testDshPermissionResult() {
        let dshEvent = """
        {"source":"dsh","hook_event_name":"PermissionRequest","tool_name":"bash","reason":"wants to run ls","tool_input":{"reason":"wants to run ls"}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(dshEvent))
        XCTAssertEqual(model.source, .dsh)
        XCTAssertEqual(model.interaction, .permission)
        XCTAssertEqual(model.detail, "wants to run ls")

        guard case .result(let allow) = AgentBridgeProtocols.response(decision: .allow, for: model) else {
            return XCTFail("dsh allow must use the result field, not stdout")
        }
        XCTAssertEqual(allow, .object(["decision": .string("allow")]))

        guard case .result(let deny) = AgentBridgeProtocols.response(decision: .deny(message: nil), for: model) else {
            return XCTFail("dsh deny must use the result field")
        }
        XCTAssertEqual(deny, .object(["decision": .string("deny")]))
    }

    func testDshQuestionResult() {
        let dshEvent = """
        {"source":"dsh","hook_event_name":"AskUserQuestion","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one","header":"","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(dshEvent))
        XCTAssertEqual(model.interaction, .question)
        guard case .result(let value) = AgentBridgeProtocols.response(
            decision: .answer(selections: ["Pick one": ["A"]], customs: [:]), for: model) else {
            return XCTFail("dsh question must use the result field")
        }
        XCTAssertEqual(value, .object(["answers": .object(["Pick one": .array([.string("A")])])]))
    }

    /// dsh 的题目允许不带 options（自由输入题）：卡片给文本框，答案走
    /// result.customs。这类题曾经是死局——没有选项可点，确认键永远点不亮。
    func testDshQuestionCustomAnswer() {
        let dshEvent = """
        {"source":"dsh","hook_event_name":"AskUserQuestion","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"叫什么名字?","header":"","options":[],"multiSelect":false}]}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(dshEvent))
        XCTAssertEqual(model.interaction, .question)
        XCTAssertEqual(model.questions.first?.options.isEmpty, true)
        guard case .result(let value) = AgentBridgeProtocols.response(
            decision: .answer(selections: [:], customs: ["叫什么名字?": "小明"]), for: model) else {
            return XCTFail("dsh custom answer must use the result field")
        }
        XCTAssertEqual(value, .object([
            "answers": .object([:]),
            "customs": .object(["叫什么名字?": .string("小明")]),
        ]))
    }

    /// Claude 路径下自由文本答案并进 updatedInput.answers，不覆盖已选选项。
    func testClaudeCustomAnswerMergedIntoUpdatedInput() {
        let model = AgentBridgeProtocols.cardModel(for: event(askEvent))
        let json = replyJSON(AgentBridgeProtocols.response(
            decision: .answer(selections: [:], customs: ["Which targets?": "随便"]),
            for: model))
        let answers = ((json?["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Which targets?"] as? String, "随便")
        XCTAssertEqual(answers?["Deploy"] as? String, "随便")
    }

    // MARK: Kimi & misc

    func testKimiAlwaysNone() {
        let kimiEvent = """
        {"source":"kimi","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(kimiEvent))
        XCTAssertEqual(model.interaction, .notify)
        XCTAssertEqual(AgentBridgeProtocols.response(decision: .allow, for: model), .none)
        XCTAssertEqual(AgentBridgeProtocols.response(decision: .deny(message: nil), for: model), .none)
    }

    /// Kimi 的 AskUserQuestion（PreToolUse 钩子）也只弹通知卡，答案回传不了。
    func testKimiAskUserQuestionNotifyOnly() {
        let ask = """
        {"source":"kimi","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one","header":"h","options":[{"label":"A","description":""}],"multi_select":false}]}}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(ask))
        XCTAssertEqual(model.interaction, .notify)
        XCTAssertEqual(model.detail, "Pick one")
        XCTAssertEqual(AgentBridgeProtocols.response(decision: .answer(selections: ["Pick one": ["A"]], customs: [:]), for: model), .none)
    }

    func testNonInteractiveEventsIgnored() {
        let sessionStart = """
        {"source":"claude","hook_event_name":"SessionStart","session_id":"s1"}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(sessionStart))
        XCTAssertEqual(model.interaction, .ignore)
        XCTAssertEqual(AgentBridgeProtocols.response(decision: .cancel, for: model), .none)
    }

    func testTolerantOfMissingFields() {
        // 字段大量缺失:不崩,detail 为空,permission 仍成立。
        let sparse = """
        {"source":"claude","hook_event_name":"PermissionRequest"}
        """
        let model = AgentBridgeProtocols.cardModel(for: event(sparse))
        XCTAssertEqual(model.interaction, .permission)
        XCTAssertEqual(model.toolName, "")
        XCTAssertEqual(model.detail, "")
        XCTAssertFalse(model.hasPermissionSuggestions)
        let json = replyJSON(AgentBridgeProtocols.response(decision: .allow, for: model))
        XCTAssertNotNil(json?["hookSpecificOutput"])
    }

    func testSocketLineFormat() {
        XCTAssertEqual(AgentBridgeProtocols.BridgeResponse.none.socketLine, #"{"action":"none"}"#)
        let line = AgentBridgeProtocols.BridgeResponse.reply(stdout: "{}", exitCode: 0).socketLine
        let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["action"] as? String, "respond")
        XCTAssertEqual(parsed?["stdout"] as? String, "{}")
        XCTAssertEqual(parsed?["exitCode"] as? Int, 0)
        let resultLine = AgentBridgeProtocols.BridgeResponse.result(.object(["decision": .string("allow")])).socketLine
        let parsedResult = try? JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [String: Any]
        XCTAssertEqual((parsedResult?["result"] as? [String: Any])?["decision"] as? String, "allow")
    }
}
