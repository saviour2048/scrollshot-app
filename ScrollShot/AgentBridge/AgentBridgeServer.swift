import Foundation
import Network
import os

/// Unix-socket server the `scrollshot-bridge` binary talks to.
///
/// One connection per hook event, newline-delimited JSON both ways:
///   bridge → app:  one line, the hook event JSON plus a `source` field
///   app → bridge:  one line, `{"action":"none"}` or
///                  `{"action":"respond","stdout":..., "exitCode":0}`
///
/// Interactive events (permission / question) hold the connection open until
/// AgentBridgeStore produces a decision; everything else gets an immediate
/// `{"action":"none"}`.
final class AgentBridgeServer: @unchecked Sendable { // state confined to `queue`
    static let shared = AgentBridgeServer()

    private let log = Logger(subsystem: "com.scrollshot.app", category: "agentBridge")
    private let queue = DispatchQueue(label: "com.scrollshot.agent-bridge")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init() {}

    /// Path of the bridge binary inside the app bundle (used by the hook
    /// installer, which is built in a later step).
    static var bridgeBinaryURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/scrollshot-bridge")
    }

    static var socketPath: String { AgentBridgeProtocols.socketPath }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for (_, connection) in self.connections { connection.cancel() }
            self.connections.removeAll()
            try? FileManager.default.removeItem(atPath: Self.socketPath)
        }
    }

    // MARK: - Private (all on `queue`)

    private func startLocked() {
        guard listener == nil else { return }
        let path = Self.socketPath
        // A stale socket file from a crashed app blocks bind().
        try? FileManager.default.removeItem(atPath: path)

        // Stream semantics over a unix socket: must be NWParameters.tcp —
        // the bare NWParameters() init fails the bind with EINVAL.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters)
        } catch {
            log.error("agent bridge listener failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Hooks run as the same user, but keep the socket private anyway.
        chmod(path, 0o600)

        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("agent bridge listener state: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.start(queue: queue)
        log.info("agent bridge listening on \(path, privacy: .public)")
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLine(connection, buffer: Data())
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Accumulates until a newline, then handles the complete event line.
    private func receiveLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let content { buffer.append(content) }

            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                self.handleLine(Data(line), connection: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 8 << 20 {
                // Peer went away mid-line (or sent garbage): drop silently.
                self.finish(connection)
                return
            }
            self.receiveLine(connection, buffer: buffer)
        }
    }

    private func handleLine(_ line: Data, connection: NWConnection) {
        guard let event = JSONValue.parse(line) else {
            respond(connection, line: #"{"action":"none"}"#)
            return
        }
        Task { @MainActor [weak self] in
            let response = await AgentBridgeStore.shared.handle(event: event)
            guard let self else { return }
            self.queue.async { self.respond(connection, line: response.socketLine) }
        }
    }

    private func respond(_ connection: NWConnection, line: String) {
        var data = Data(line.utf8)
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        connections[ObjectIdentifier(connection)] = nil
    }
}
