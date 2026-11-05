import Foundation
import Combine
import os

/// FIFO queue of agent requests waiting for a user decision on the notch
/// card. @MainActor because SwiftUI renders straight from `pending`.
///
/// `handle(event:)` suspends the caller (the socket connection task) until
/// the user answers or the 60s inactivity timeout fires; the timeout
/// completes with `.cancel` — exit 0, no output — so the CLI shows its own
/// native prompt (second safety net inside the bridge's 300s read timeout).
@MainActor
final class AgentBridgeStore: ObservableObject {
    static let shared = AgentBridgeStore()

    private let log = Logger(subsystem: "com.scrollshot.app", category: "agentBridge")

    struct PendingRequest: Identifiable, Equatable {
        let id: UUID
        let model: AgentBridgeProtocols.CardModel
        /// 卡片上的会话标识行：`文件夹 · 会话名`，用来分辨请求来自哪个 session。
        let sessionLabel: String?
    }

    @Published private(set) var pending: [PendingRequest] = []

    private var continuations: [UUID: CheckedContinuation<AgentBridgeProtocols.BridgeResponse, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// How long a decision card waits before auto-cancelling.
    static let decisionTimeout: TimeInterval = 60
    /// How long a notify-only card (Kimi) stays up.
    static let notifyLifetime: TimeInterval = 8

    // MARK: - Server entry point

    /// Handles one hook event. Returns nil when the event needs no response
    /// work at all; otherwise the socket reply.
    func handle(event: JSONValue) async -> AgentBridgeProtocols.BridgeResponse {
        // 先记录会话上下文（cwd / 转录路径 / 首条 prompt），非交互事件也要记，
        // 否则权限卡弹出来时就查不到这是哪个 session。
        AgentSessionLabels.shared.note(event: event)
        let model = AgentBridgeProtocols.cardModel(for: event)
        let sessionLabel = AgentSessionLabels.shared.label(for: model)
        if model.interaction != .ignore || model.eventName == "PermissionRequest" {
            log.info("event src=\(model.source.rawValue, privacy: .public) name=\(model.eventName, privacy: .public) tool=\(model.toolName, privacy: .public) session=\(model.sessionID ?? "-", privacy: .public) → \(String(describing: model.interaction), privacy: .public)")
        }
        switch model.interaction {
        case .ignore:
            return .none
        case .notify:
            let id = enqueue(model, sessionLabel: sessionLabel, continuation: nil)
            scheduleAutoDismiss(id: id, after: Self.notifyLifetime)
            return .none
        case .permission, .question:
            return await withCheckedContinuation { continuation in
                let id = enqueue(model, sessionLabel: sessionLabel, continuation: continuation)
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.decisionTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.respond(id: id, decision: .cancel)
                }
            }
        }
    }

    // MARK: - UI entry points

    func respond(id: UUID, decision: AgentBridgeProtocols.Decision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: AgentBridgeProtocols.response(decision: decision, for: request.model))
    }

    /// Dismiss a notify-only card (no continuation behind it).
    func dismiss(id: UUID) {
        respond(id: id, decision: .cancel)
    }

    // MARK: - Private

    private func enqueue(
        _ model: AgentBridgeProtocols.CardModel,
        sessionLabel: String?,
        continuation: CheckedContinuation<AgentBridgeProtocols.BridgeResponse, Never>?
    ) -> UUID {
        let id = UUID()
        if let continuation {
            continuations[id] = continuation
        }
        pending.append(PendingRequest(id: id, model: model, sessionLabel: sessionLabel))
        return id
    }

    private func scheduleAutoDismiss(id: UUID, after delay: TimeInterval) {
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }
}
