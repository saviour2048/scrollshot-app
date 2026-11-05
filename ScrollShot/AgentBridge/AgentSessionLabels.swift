import Foundation

/// 会话标签：让刘海审批卡能标明“这条请求来自哪个 session”。
///
/// 数据都来自 hook 事件本身，不需要额外权限：
/// - 所有事件都带 `session_id` / `cwd` / `transcript_path`；
/// - `UserPromptSubmit` 带 `prompt`，作为没有更好标题时的兜底；
/// - Codex（经 Happier）会在会话开始调用一次 `change_title`，标题写在转录
///   文件里——那就是用户在 Happier 里看到的会话名，优先用它。
@MainActor
final class AgentSessionLabels {
    static let shared = AgentSessionLabels()

    private struct Entry {
        var cwd: String? = nil
        var transcript: String? = nil
        var prompt: String? = nil
        var title: String? = nil
        var titleReadAt: Date? = nil
    }

    private var entries: [String: Entry] = [:]
    /// 没读到标题时，隔这么久再看一眼转录（标题通常在会话最开始就写好了）。
    private let retryInterval: TimeInterval = 30

    private init() {}

    /// 每个 hook 事件进来都记一下，非交互事件（UserPromptSubmit 等）也要记。
    func note(event: JSONValue) {
        guard let sid = event.string("session_id", "sessionId", "thread_id") else { return }
        let key = Self.cacheKey(source: event["source"]?.stringValue, sessionID: sid)
        var entry = entries[key] ?? Entry()
        if let cwd = event.string("cwd", "working_directory") { entry.cwd = cwd }
        if let path = event.string("transcript_path", "transcriptPath") { entry.transcript = path }
        if Self.isPromptSubmit(event), entry.prompt == nil,
           let prompt = event.string("prompt") {
            entry.prompt = prompt
        }
        entries[key] = entry
    }

    /// 卡片上的会话行：`文件夹 · 会话名`。
    /// 没有会话名时退回首条 prompt；连 prompt 都没有就露出 session id 末 6 位。
    func label(for model: AgentBridgeProtocols.CardModel) -> String? {
        let sid = model.sessionID
        var entry: Entry
        var key: String?
        if let sid {
            key = Self.cacheKey(source: model.source.rawValue, sessionID: sid)
            entry = entries[key!] ?? Entry()
            entry.cwd = entry.cwd ?? model.cwd
            entry.transcript = entry.transcript ?? model.transcriptPath
        } else {
            entry = Entry(cwd: model.cwd, transcript: model.transcriptPath)
        }

        if entry.title == nil, let path = entry.transcript,
           shouldRead(entry.titleReadAt) {
            entry.titleReadAt = Date()
            entry.title = SessionTitleReader.title(fromTranscriptAt: path)
        }
        if let key { entries[key] = entry }

        var parts: [String] = []
        if let cwd = entry.cwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        }
        if let title = entry.title, !title.isEmpty {
            parts.append(Self.shortened(title))
        } else if let prompt = entry.prompt, !prompt.isEmpty {
            parts.append(Self.shortened(prompt))
        }
        if parts.isEmpty, let sid, !sid.isEmpty {
            parts.append("…" + sid.suffix(6))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func shouldRead(_ at: Date?) -> Bool {
        guard let at else { return true }
        return Date().timeIntervalSince(at) > retryInterval
    }

    private static func cacheKey(source: String?, sessionID: String) -> String {
        "\(source ?? "?")|\(sessionID)"
    }

    private static func isPromptSubmit(_ event: JSONValue) -> Bool {
        let name = event.string("hook_event_name", "event", "hookType") ?? ""
        return name.lowercased().replacingOccurrences(of: "_", with: "") == "userpromptsubmit"
    }

    private static func shortened(_ text: String, limit: Int = 32) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }
}

/// 从 CLI 的转录文件里读会话标题。
///
/// Codex（Happier）会调用 `change_title` 设置标题，转录里能看到的形态有两种：
/// `"arguments":{"title":"..."}` 和字符串化的 `"arguments":"{\"title\": \"...\"}"`。
/// 只扫文件开头 2MB——标题在会话开始就写入了，没必要读完整份转录。
enum SessionTitleReader {
    static func title(fromTranscriptAt path: String, maxBytes: Int = 2 * 1024 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return title(inTranscript: text)
    }

    static func title(inTranscript text: String) -> String? {
        let pattern = ##"\\?"title\\?"\s*:\s*\\?"((?:[^"\\]|\\.)*?)\\?""##
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var last: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("change_title") {
            let string = String(line)
            let range = NSRange(location: 0, length: (string as NSString).length)
            for match in regex.matches(in: string, range: range) where match.numberOfRanges > 1 {
                var value = (string as NSString).substring(with: match.range(at: 1))
                value = value.replacingOccurrences(of: #"\""#, with: #"""#)
                value = value.replacingOccurrences(of: #"\\"#, with: #"\"#)
                if !value.isEmpty { last = value }
            }
        }
        return last
    }
}
