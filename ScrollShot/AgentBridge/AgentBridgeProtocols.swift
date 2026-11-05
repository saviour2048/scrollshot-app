import Foundation

/// Minimal dynamic JSON value used by the agent-bridge protocol layer.
///
/// Hook events are pass-through blobs: the app must preserve fields it does
/// not understand (e.g. `tool_input` is echoed back inside `updatedInput`),
/// so we don't model them as Codable structs. JSONValue round-trips through
/// JSONSerialization losslessly enough for that purpose.
enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(any: Any) {
        switch any {
        case let d as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in d {
                guard let value = JSONValue(any: v) else { return nil }
                obj[k] = value
            }
            self = .object(obj)
        case let a as [Any]:
            var arr: [JSONValue] = []
            for v in a {
                guard let value = JSONValue(any: v) else { return nil }
                arr.append(value)
            }
            self = .array(arr)
        case let s as String:
            self = .string(s)
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            self = .bool(n.boolValue)
        case let n as NSNumber:
            self = .number(n.doubleValue)
        case is NSNull:
            self = .null
        default:
            return nil
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(any: any)
    }

    var anyValue: Any {
        switch self {
        case .object(let d): return d.mapValues { $0.anyValue }
        case .array(let a):  return a.map { $0.anyValue }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b):   return b
        case .null:          return NSNull()
        }
    }

    /// Single-line JSON, as required by the socket protocol.
    var serialized: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let d) = self { return d[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// First present string value among the given keys.
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let s = self[key]?.stringValue { return s }
        }
        return nil
    }
}

/// Pure protocol translation for the agent bridge: hook event JSON + user
/// decision → the socket reply the bridge binary relays to the CLI, and
/// hook event JSON → the notch card view model. All static and side-effect
/// free so they can be unit-tested without the server or UI.
enum AgentBridgeProtocols {

    // MARK: - Wire constants

    static var socketPath: String {
        "/tmp/scrollshot-agent-\(getuid()).sock"
    }

    /// What the bridge/plugin gets back after sending one event line.
    /// - `.reply`: the bridge prints `stdout` verbatim and exits with
    ///   `exitCode` (the CLI hook protocol; the bridge ignores `result`).
    /// - `.result`: structured answer for the dsh plugin
    ///   (`{"action":"respond","result":{...},"exitCode":0}`); the bridge
    ///   tolerates and ignores the extra `result` field.
    /// - `.none`: "print nothing, exit 0" — the caller falls back to its
    ///   native prompt.
    enum BridgeResponse: Equatable {
        case none
        case reply(stdout: String, exitCode: Int)
        case result(JSONValue)

        var socketLine: String {
            switch self {
            case .none:
                return #"{"action":"none"}"#
            case .reply(let stdout, let exitCode):
                let obj: [String: Any] = ["action": "respond", "stdout": stdout, "exitCode": exitCode]
                guard let line = Self.serialize(obj) else { return #"{"action":"none"}"# }
                return line
            case .result(let value):
                let obj: [String: Any] = ["action": "respond", "result": value.anyValue, "exitCode": 0]
                guard let line = Self.serialize(obj) else { return #"{"action":"none"}"# }
                return line
            }
        }

        private static func serialize(_ obj: [String: Any]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Card view model

    enum Source: String, Equatable {
        case claude, codex, kimi, dsh, unknown

        init(raw: String) {
            switch raw.lowercased() {
            case "claude", "claude-code": self = .claude
            case "codex", "openai.codex": self = .codex
            case "kimi":                  self = .kimi
            case "dsh":                   self = .dsh
            default:                      self = .unknown
            }
        }

        var displayName: String {
            switch self {
            case .claude:  return "Claude Code"
            case .codex:   return "Codex"
            case .kimi:    return "Kimi Code"
            case .dsh:     return "dsh"
            case .unknown: return "Agent"
            }
        }
    }

    enum Interaction: Equatable {
        /// Not surfaced at all (SessionStart/Stop/Notification/...).
        case ignore
        /// Informational card only (Kimi — never answered by us).
        case notify
        /// Allow / always allow / deny.
        case permission
        /// AskUserQuestion option picker.
        case question
    }

    struct Question: Equatable, Identifiable {
        var id: String { text }
        let text: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
    }

    struct Option: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let description: String
    }

    struct CardModel: Equatable {
        let source: Source
        let interaction: Interaction
        let eventName: String
        let toolName: String
        /// Bash command / reason / first question text — the card's main line.
        let detail: String
        let questions: [Question]
        let hasPermissionSuggestions: Bool
        /// Bundle id of the terminal that spawned the CLI, if forwarded.
        let terminalBundleID: String?
        /// Hook 事件里的会话身份,用于在卡片上标明"这是哪个 session"。
        let sessionID: String?
        let cwd: String?
        let transcriptPath: String?
        /// The untouched hook event, kept for protocol translation.
        let event: JSONValue
    }

    /// Tolerant event → card model parsing. Missing fields degrade to empty
    /// strings / .ignore instead of failing.
    static func cardModel(for event: JSONValue) -> CardModel {
        let source = Source(raw: event["source"]?.stringValue ?? "")
        let eventName = event.string("hook_event_name", "event", "hookType") ?? ""
        let toolName = event.string("tool_name", "toolName", "tool", "name") ?? ""
        let toolInput = event["tool_input"] ?? event["toolInput"] ?? .null
        let questions = parseQuestions(from: toolInput)
        let suggestions = event["permission_suggestions"]?.arrayValue ?? []

        let detail =
            toolInput.string("command")
            ?? toolInput.string("description", "prompt", "message", "reason")
            ?? questions.first?.text
            ?? event.string("message", "reason")
            ?? ""

        let interaction: Interaction
        if source == .kimi {
            // Kimi 的 hook 回传不了答案（PermissionRequest 只读、PreToolUse
            // 没有 updatedInput），所以权限请求和 AskUserQuestion 提问都只弹
            // 「去终端处理」的通知卡，decisions 一律不回。
            interaction = (eventName == "PermissionRequest"
                || (toolName == "AskUserQuestion" && !questions.isEmpty)) ? .notify : .ignore
        } else if toolName == "AskUserQuestion", !questions.isEmpty, source != .codex {
            interaction = .question
        } else if eventName == "PermissionRequest" {
            interaction = .permission
        } else {
            interaction = .ignore
        }

        return CardModel(
            source: source,
            interaction: interaction,
            eventName: eventName,
            toolName: toolName,
            detail: detail,
            questions: questions,
            hasPermissionSuggestions: !suggestions.isEmpty,
            terminalBundleID: event["_term_bundle_id"]?.stringValue,
            sessionID: event.string("session_id", "sessionId", "thread_id"),
            cwd: event.string("cwd", "working_directory"),
            transcriptPath: event.string("transcript_path", "transcriptPath"),
            event: event
        )
    }

    private static func parseQuestions(from toolInput: JSONValue) -> [Question] {
        guard let arr = toolInput["questions"]?.arrayValue else { return [] }
        return arr.map { q in
            let options = (q["options"]?.arrayValue ?? []).map { opt -> Option in
                if let s = opt.stringValue { return Option(label: s, description: "") }
                return Option(
                    label: opt["label"]?.stringValue ?? "",
                    description: opt["description"]?.stringValue ?? ""
                )
            }
            let multi = q["multiSelect"]?.boolValue ?? q["multi_select"]?.boolValue ?? false
            return Question(
                text: q["question"]?.stringValue ?? "",
                header: q["header"]?.stringValue ?? "",
                options: options,
                multiSelect: multi
            )
        }
    }

    // MARK: - Decision → CLI protocol JSON

    enum Decision: Equatable {
        case allow
        case allowAlways
        case deny(message: String?)
        /// Question text → selected option labels; `customs` carries free-text
        /// answers for questions that offered no options (dsh `custom` field).
        case answer(selections: [String: [String]], customs: [String: String])
        /// User dismissed / timed out: CLI falls back to its native prompt.
        case cancel
    }

    static func response(decision: Decision, for model: CardModel) -> BridgeResponse {
        guard decision != .cancel, model.source != .kimi else { return .none }

        if model.source == .dsh { return dshResponse(decision: decision, model: model) }

        switch (model.interaction, decision) {
        case (.permission, .allow), (.permission, .allowAlways), (.permission, .deny):
            return permissionResponse(decision: decision, model: model)
        case (.question, .answer(let answers, let customs)):
            return askUserQuestionResponse(answers: answers, customs: customs, model: model)
        default:
            return .none
        }
    }

    /// Claude Code / Codex PermissionRequest hook output:
    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}`
    /// "Always allow" echoes the event's `permission_suggestions` back as
    /// `updatedPermissions` — except for Codex, whose hook schema rejects the
    /// reserved permission fields (agentbro bridge/main.rs:240-300).
    static func permissionResponse(decision: Decision, model: CardModel) -> BridgeResponse {
        var decisionObj: [String: JSONValue]
        switch decision {
        case .allow, .allowAlways:
            decisionObj = ["behavior": .string("allow")]
            if decision == .allowAlways, model.source != .codex,
               let suggestions = model.event["permission_suggestions"],
               let arr = suggestions.arrayValue, !arr.isEmpty {
                decisionObj["updatedPermissions"] = suggestions
            }
        case .deny(let message):
            let msg = (message?.isEmpty == false) ? message! : "Denied by user via ScrollShot"
            decisionObj = ["behavior": .string("deny"), "message": .string(msg)]
        default:
            return .none
        }
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decisionObj),
            ]),
        ])
        guard let stdout = output.serialized else { return .none }
        return .reply(stdout: stdout, exitCode: 0)
    }

    /// dsh answers ride the `result` field, which the Cordis plugin maps back
    /// to its own vocabulary: approval → 'allowed-once'/'rejected', questions
    /// → {answers: [{id, selected, custom?}]} — option labels go in `answers`,
    /// free-text answers (questions that offered no options) in `customs`.
    /// "Always allow" has no dsh equivalent through this path and degrades to
    /// a one-shot allow.
    static func dshResponse(decision: Decision, model: CardModel) -> BridgeResponse {
        switch (model.interaction, decision) {
        case (.permission, .allow), (.permission, .allowAlways):
            return .result(.object(["decision": .string("allow")]))
        case (.permission, .deny):
            return .result(.object(["decision": .string("deny")]))
        case (.question, .answer(let answers, let customs)):
            var result: [String: JSONValue] = [
                "answers": .object(answers.mapValues { .array($0.map { .string($0) }) }),
            ]
            let customsObj = customs.filter { !$0.value.isEmpty }.mapValues { JSONValue.string($0) }
            if !customsObj.isEmpty { result["customs"] = .object(customsObj) }
            return .result(.object(result))
        default:
            return .none
        }
    }
    /// Claude Code AskUserQuestion (PreToolUse hook): answers ride back inside
    /// `updatedInput`. Mirrors agentbro bridge/main.rs:80-105 + 398-447:
    /// every answer is keyed by BOTH the question text and its header, and a
    /// multi-select answer is the labels joined by ", ". Free-text customs fill
    /// questions the user typed an answer for instead of picking an option.
    static func askUserQuestionResponse(answers: [String: [String]], customs: [String: String], model: CardModel) -> BridgeResponse {
        guard case .object(var toolInput) = model.event["tool_input"] ?? model.event["toolInput"] ?? .null
        else { return .none }

        var answersObj: [String: JSONValue] = [:]
        for (question, labels) in answers where !labels.isEmpty {
            answersObj[question] = .string(labels.joined(separator: ", "))
        }
        for (question, text) in customs where !text.isEmpty && answersObj[question] == nil {
            answersObj[question] = .string(text)
        }
        // Dual-key alias: a CLI may look answers up by header or by question
        // text, so write both for every answered question.
        for q in model.questions where !q.header.isEmpty {
            if let byText = answersObj[q.text], answersObj[q.header] == nil {
                answersObj[q.header] = byText
            } else if let byHeader = answersObj[q.header], answersObj[q.text] == nil {
                answersObj[q.text] = byHeader
            }
        }
        toolInput["answers"] = .object(answersObj)
        let updatedInput = JSONValue.object(toolInput)

        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("allow"),
                "decision": .object([
                    "behavior": .string("allow"),
                    "updatedInput": updatedInput,
                ]),
                "updatedInput": updatedInput,
            ]),
        ])
        guard let stdout = output.serialized else { return .none }
        return .reply(stdout: stdout, exitCode: 0)
    }
}
