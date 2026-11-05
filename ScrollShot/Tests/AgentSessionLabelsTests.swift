import XCTest
@testable import ScrollShot

final class AgentSessionLabelsTests: XCTestCase {
    private func model(_ json: String) -> AgentBridgeProtocols.CardModel {
        let event = JSONValue.parse(Data(json.utf8))!
        return AgentBridgeProtocols.cardModel(for: event)
    }

    func testCardModelCarriesSessionFields() {
        let m = model("""
        {"source":"codex","hook_event_name":"PermissionRequest","session_id":"s-123",
         "cwd":"/Users/me/project","transcript_path":"/tmp/rollout.jsonl",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """)
        XCTAssertEqual(m.sessionID, "s-123")
        XCTAssertEqual(m.cwd, "/Users/me/project")
        XCTAssertEqual(m.transcriptPath, "/tmp/rollout.jsonl")
    }

    /// Codex/Happier 的转录里有 change_title 调用；取最后一个标题。
    func testTitleReadsLatestChangeTitle() {
        let text = """
        {"type":"response_item","payload":{"description":"Change the title","parameters":{"properties":{"title":{"type":"string"}}}}}
        {"type":"response_item","payload":{"name":"change_title","arguments":{"title":"第一个标题"}}}
        {"type":"response_item","payload":{"name":"change_title","arguments":"{\\"title\\": \\"第二个标题\\"}"}}
        """
        XCTAssertEqual(SessionTitleReader.title(inTranscript: text), "第二个标题")
    }

    /// 只有工具定义、没有真正的标题参数时不应误读。
    func testTitleIgnoresToolSchema() {
        let text = #"{"name":"change_title","parameters":{"properties":{"title":{"type":"string"}}}}"#
        XCTAssertNil(SessionTitleReader.title(inTranscript: text))
    }

    func testTitleReturnsNilWhenNoTranscript() {
        XCTAssertNil(SessionTitleReader.title(fromTranscriptAt: "/nonexistent/rollout.jsonl"))
    }

    /// 卡片上的标签 = 文件夹名 · 会话名（复用同一个 singleton，用唯一 session id 隔离）。
    @MainActor
    func testLabelCombinesFolderAndTranscriptTitle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try #"{"name":"change_title","arguments":{"title":"测试会话标题"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let event = JSONValue.parse(Data("""
        {"source":"codex","hook_event_name":"PermissionRequest","session_id":"label-\(UUID().uuidString)",
         "cwd":"/Users/me/MyProject","transcript_path":"\(url.path)",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """.utf8))!
        AgentSessionLabels.shared.note(event: event)
        let model = AgentBridgeProtocols.cardModel(for: event)
        XCTAssertEqual(AgentSessionLabels.shared.label(for: model), "MyProject · 测试会话标题")
    }
}
