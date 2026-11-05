import Foundation

/// One chat bubble.
struct ChatBubble: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String        // "user" / "assistant"
    var content: String
}

/// One conversation (a "session"). The whole history is resent with every
/// request — that's the context memory.
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var bubbles: [ChatBubble]
    var updatedAt: Date

    var title: String {
        let t = bubbles.first(where: { $0.role == "user" })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "新对话" : String(t.prefix(24))
    }
}

/// All conversations, Claude-style: opening the window starts a fresh session,
/// old sessions stay in the sidebar and can be resumed. Persisted to disk.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var isStreaming = false

    private var streamTask: Task<Void, Never>?
    /// Newest N turns resent per request, bounding provider token usage.
    private let contextWindow = 30
    private let maxConversations = 50
    /// Per-session cap: old bubbles are dropped from the head so one long
    /// conversation can't grow the persisted file without limit.
    private let maxBubblesPerConversation = 200

    var current: Conversation? { conversations.first { $0.id == currentID } }
    /// Sidebar order: most recently touched first. Empty sessions are noise —
    /// only the CURRENT one may appear while still empty.
    var recents: [Conversation] {
        conversations
            .filter { !$0.bubbles.isEmpty || $0.id == currentID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ScrollShot/Chat")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var fileURL: URL { dir.appendingPathComponent("conversations.json") }

    private init() { load() }

    // MARK: Sessions

    /// Fresh session (reuses the current one if it's still empty).
    func beginFreshSession() {
        stop()
        if let cur = current, cur.bubbles.isEmpty { return }
        conversations.removeAll { $0.bubbles.isEmpty }   // abandoned empties are noise
        let c = Conversation(id: UUID(), bubbles: [], updatedAt: Date())
        conversations.append(c)
        currentID = c.id
        prune()
        save()
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        stop()
        currentID = id
        conversations.removeAll { $0.bubbles.isEmpty && $0.id != id }
    }

    func deleteConversation(_ id: UUID) {
        if id == currentID { stop() }
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = recents.first?.id }
        save()
    }

    // MARK: Chat

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        if current == nil { beginFreshSession() }
        guard let idx = index(of: currentID) else { return }

        conversations[idx].bubbles.append(ChatBubble(id: UUID(), role: "user", content: trimmed))
        conversations[idx].bubbles.append(ChatBubble(id: UUID(), role: "assistant", content: ""))
        conversations[idx].updatedAt = Date()
        isStreaming = true

        let convID = conversations[idx].id
        let history = conversations[idx].bubbles.dropLast().suffix(contextWindow)
            .map { LLMMessage(role: $0.role, content: $0.content) }

        streamTask = Task { [weak self] in
            do {
                let stream = try await LLMClient.stream(messages: Array(history))
                for try await delta in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.appendToLast(of: convID, delta)
                }
            } catch is CancellationError {
                // user stop — keep partial text
            } catch {
                self?.appendToLast(of: convID, "\n\n⚠️ \(error.localizedDescription)")
            }
            self?.isStreaming = false
            self?.save()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        save()
    }

    private func appendToLast(of convID: UUID, _ text: String) {
        guard let idx = index(of: convID), !conversations[idx].bubbles.isEmpty else { return }
        conversations[idx].bubbles[conversations[idx].bubbles.count - 1].content += text
    }

    private func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return conversations.firstIndex { $0.id == id }
    }

    private func prune() {
        for i in conversations.indices where conversations[i].bubbles.count > maxBubblesPerConversation {
            conversations[i].bubbles = Array(conversations[i].bubbles.suffix(maxBubblesPerConversation))
        }
        guard conversations.count > maxConversations else { return }
        let keep = Set(recents.prefix(maxConversations).map(\.id))
        conversations.removeAll { !keep.contains($0.id) && $0.id != currentID }
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = decoded
        } else if let data = try? Data(contentsOf: dir.appendingPathComponent("conversation.json")),
                  let old = try? JSONDecoder().decode([ChatBubble].self, from: data), !old.isEmpty {
            // Migrate the single-conversation format from the first build.
            conversations = [Conversation(id: UUID(), bubbles: old, updatedAt: Date())]
        }
        currentID = recents.first?.id
    }

    private func save() {
        // Empty sessions are never persisted.
        guard let data = try? JSONEncoder().encode(conversations.filter { !$0.bubbles.isEmpty }) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
