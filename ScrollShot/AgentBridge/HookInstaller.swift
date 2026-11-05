import Foundation
import CryptoKit

/// Installs / removes the per-agent hook registrations that point the AI
/// CLIs at the `scrollshot-bridge` binary.
///
/// File formats follow agentbro's installers (src-tauri/src/agents/):
/// - Claude Code: `~/.claude/settings.json`, nested groups
///   `hooks.<Event>[] = {matcher, hooks:[{type:command, command, timeout}]}`
/// - Codex: `~/.codex/hooks.json` (same nested shape, no matcher), plus
///   `~/.codex/config.toml` needs `[features] hooks = true` and a trust
///   table entry per hook (sha256 of a canonical-JSON identity) — without
///   the trust entry Codex refuses to run the hook.
/// - Kimi Code: `~/.kimi-code/config.toml`, a `[[hooks]]` table appended
///   between `# scrollshot-agent-notch` marker comments (Kimi's
///   PermissionRequest hook is observation-only and PreToolUse has no documented updatedInput, so no answers ride back — the app shows "waiting in terminal" cards for permission requests and AskUserQuestion).
///
/// All writes are atomic (write .tmp, rename) and back the original up to
/// `<file>.scrollshot-bak` before the first mutation. `home` is injectable
/// so tests run against a temp directory.
struct HookInstaller {
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, kimi
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex:  return "Codex"
            case .kimi:   return "Kimi Code"
            }
        }
    }

    enum Status: Equatable {
        case installed, notInstalled, modified, agentMissing
    }

    /// Identifies our hook commands inside foreign config files.
    static let bridgeMarker = "scrollshot-bridge"
    /// Comment marker wrapping our `[[hooks]]` block in TOML files.
    static let tomlMarker = "# scrollshot-agent-notch"
    static let tomlMarkerEnd = "# scrollshot-agent-notch end"

    let home: URL
    /// Where the shipping bridge binary lives (app bundle Helpers). Injectable
    /// for tests, which point it at a stub executable.
    var bridgeSource: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         bridgeSource: URL = AgentBridgeServer.bridgeBinaryURL) {
        self.home = home
        self.bridgeSource = bridgeSource
    }

    // MARK: - Paths

    var bridgeURL: URL {
        home.appendingPathComponent(".scrollshot/bin/scrollshot-bridge")
    }

    private func configURL(_ agent: Agent) -> URL {
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex:  return home.appendingPathComponent(".codex/hooks.json")
        case .kimi:   return home.appendingPathComponent(".kimi-code/config.toml")
        }
    }

    private var codexConfigToml: URL { home.appendingPathComponent(".codex/config.toml") }

    private func agentConfigDir(_ agent: Agent) -> URL {
        switch agent {
        case .claude: return home.appendingPathComponent(".claude")
        case .codex:  return home.appendingPathComponent(".codex")
        case .kimi:   return home.appendingPathComponent(".kimi-code")
        }
    }

    private func command(_ agent: Agent) -> String {
        "\(bridgeURL.path) --source \(agent.rawValue)"
    }

    // MARK: - Detection & status

    /// Cheap existence check: the agent has been run on this machine before.
    func agentDetected(_ agent: Agent) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: agentConfigDir(agent).path, isDirectory: &isDir) && isDir.boolValue
    }

    func status(_ agent: Agent) -> Status {
        guard agentDetected(agent) else { return .agentMissing }
        switch agent {
        case .claude, .codex:
            guard let settings = readJSON(configURL(agent)) else { return .notInstalled }
            guard let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
            var foundMarker = false
            for (_, value) in hooks {
                for group in value as? [[String: Any]] ?? [] {
                    for hook in group["hooks"] as? [[String: Any]] ?? [] {
                        guard let cmd = hook["command"] as? String,
                              cmd.contains(Self.bridgeMarker) else { continue }
                        foundMarker = true
                        if cmd == command(agent) { return .installed }
                    }
                }
            }
            return foundMarker ? .modified : .notInstalled
        case .kimi:
            guard let content = try? String(contentsOf: configURL(.kimi), encoding: .utf8),
                  content.contains(Self.tomlMarker) else { return .notInstalled }
            return content.contains(command(.kimi)) ? .installed : .modified
        }
    }

    // MARK: - Install / uninstall

    func install(_ agent: Agent) throws {
        try installBridgeBinary()
        switch agent {
        case .claude: try installClaude()
        case .codex:  try installCodex()
        case .kimi:   try installKimi()
        }
    }

    func uninstall(_ agent: Agent) throws {
        switch agent {
        case .claude: try uninstallJSONHooks(configURL(.claude))
        case .codex:
            try uninstallJSONHooks(configURL(.codex))
            try removeCodexTrustEntries()
        case .kimi: try uninstallKimi()
        }
    }

    /// Copies the bundled bridge binary to ~/.scrollshot/bin/. The install
    /// path must stay space-free: hook commands are split naively by some
    /// CLIs (agentbro hit this).
    private func installBridgeBinary() throws {
        guard FileManager.default.fileExists(atPath: bridgeSource.path) else {
            throw NSError(domain: "ScrollShot.HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bridge binary missing at \(bridgeSource.path)"])
        }
        let dir = bridgeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: bridgeURL.path) {
            try FileManager.default.removeItem(at: bridgeURL)
        }
        try FileManager.default.copyItem(at: bridgeSource, to: bridgeURL)
    }

    // MARK: Claude Code

    /// Event → (matcher, timeout). Only the interactive events get the long
    /// timeout; lifecycle events fire-and-forget.
    private var claudeEvents: [(event: String, matcher: String, timeout: Int?)] {
        [
            ("PermissionRequest", "*", 21600),
            ("PreToolUse", "AskUserQuestion", 21600),
            ("SessionStart", "*", nil),
            ("Stop", "*", nil),
            ("Notification", "*", nil),
        ]
    }

    private func installClaude() throws {
        var settings = readJSON(configURL(.claude)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in claudeEvents {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            groups.removeAll { groupContainsOurCommand($0) }
            var hook: [String: Any] = ["type": "command", "command": command(.claude)]
            if let timeout = spec.timeout { hook["timeout"] = timeout }
            groups.append(["matcher": spec.matcher, "hooks": [hook]])
            hooks[spec.event] = groups
        }
        settings["hooks"] = hooks
        try writeJSON(configURL(.claude), settings)
    }

    // MARK: Codex

    /// (jsonKey, eventKey, timeout) — eventKey is the snake_case name the
    /// trust table hashes. Mirrors agentbro agents/codex.rs HOOK_EVENTS.
    private var codexEvents: [(event: String, key: String, timeout: Int)] {
        [
            ("SessionStart", "session_start", 5),
            ("UserPromptSubmit", "user_prompt_submit", 5),
            ("PreToolUse", "pre_tool_use", 5),
            ("PostToolUse", "post_tool_use", 5),
            ("PostToolUseFailure", "post_tool_use_failure", 5),
            ("PermissionRequest", "permission_request", 21600),
            ("PermissionDenied", "permission_denied", 5),
            ("Notification", "notification", 5),
            ("Stop", "stop", 5),
            ("SessionEnd", "session_end", 5),
        ]
    }

    private func installCodex() throws {
        var settings = readJSON(configURL(.codex)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in codexEvents {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            groups.removeAll { groupContainsOurCommand($0) }
            groups.append(["hooks": [[
                "type": "command",
                "command": command(.codex),
                "timeout": spec.timeout,
            ]]])
            hooks[spec.event] = groups
        }
        settings["hooks"] = hooks
        try writeJSON(configURL(.codex), settings)
        try updateCodexConfigToml(settings: settings)
    }

    /// config.toml: `[features] hooks = true` plus one
    /// `[hooks.state."<path>:<event>:<group>:<handler>"] trusted_hash = …`
    /// entry per installed hook. Ports agentbro's ensure_codex_hooks_feature
    /// and trust_codex_hooks (agents/codex.rs).
    private func updateCodexConfigToml(settings: [String: Any]) throws {
        let hooksPath = configURL(.codex).path
        let canonPath = (hooksPath as NSString).resolvingSymlinksInPath

        var entries: [(key: String, hash: String)] = []
        for spec in codexEvents {
            let groups = (settings["hooks"] as? [String: Any])?[spec.event] as? [[String: Any]] ?? []
            for (groupIndex, group) in groups.enumerated() {
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                for (handlerIndex, handler) in handlers.enumerated() {
                    guard handler["type"] as? String == "command",
                          handler["command"] as? String == command(.codex) else { continue }
                    let timeout = max((handler["timeout"] as? Int) ?? spec.timeout, 1)
                    let identity: [String: Any] = [
                        "event_name": spec.key,
                        "hooks": [[
                            "type": "command",
                            "command": command(.codex),
                            "timeout": timeout,
                            "async": false,
                        ]],
                    ]
                    entries.append((
                        key: "\(canonPath):\(spec.key):\(groupIndex):\(handlerIndex)",
                        hash: "sha256:" + Self.sha256Hex(Self.canonicalJSON(identity))
                    ))
                }
            }
        }
        guard !entries.isEmpty else { return }

        var content = (try? String(contentsOf: codexConfigToml, encoding: .utf8)) ?? ""
        content = Self.ensureCodexHooksFeature(content)
        // Drop our previously-written trust tables, then re-append fresh ones.
        content = Self.removeTomlTablesWithPrefix(content, prefix: "[hooks.state.\"\(Self.tomlBasicString(canonPath)):")
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in entries {
            content += "\n\n[hooks.state.\"\(Self.tomlBasicString(entry.key))\"]\ntrusted_hash = \"\(Self.tomlBasicString(entry.hash))\""
        }
        content += "\n"
        try writeTextAtomic(codexConfigToml, content)
    }

    private func removeCodexTrustEntries() throws {
        guard var content = try? String(contentsOf: codexConfigToml, encoding: .utf8) else { return }
        let canonPath = (configURL(.codex).path as NSString).resolvingSymlinksInPath
        content = Self.removeTomlTablesWithPrefix(content, prefix: "[hooks.state.\"\(Self.tomlBasicString(canonPath)):")
        try writeTextAtomic(codexConfigToml, content)
    }

    // MARK: Kimi Code

    /// Kimi's PermissionRequest hook is observation-only (cannot block), so
    /// the app answers immediately and only shows a "waiting in terminal" card.
    /// AskUserQuestion rides PreToolUse with the same treatment: Kimi has no
    /// documented updatedInput in its hook output, so the card is notify-only
    /// and the bridge replies instantly — the CLI's own panel never stalls.
    private func kimiBlock() -> String {
        """
        \(Self.tomlMarker)
        [[hooks]]
        event = "PermissionRequest"
        command = "\(command(.kimi))"
        timeout = 600

        [[hooks]]
        event = "PreToolUse"
        matcher = "AskUserQuestion"
        command = "\(command(.kimi))"
        timeout = 30
        \(Self.tomlMarkerEnd)
        """
    }

    private func installKimi() throws {
        let url = configURL(.kimi)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var content = Self.stripMarkedBlock(existing)
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        content += kimiBlock() + "\n"
        try writeTextAtomic(url, content)
    }

    private func uninstallKimi() throws {
        let url = configURL(.kimi)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        try writeTextAtomic(url, Self.stripMarkedBlock(existing))
    }

    /// Removes the marker-wrapped block; other config untouched.
    static func stripMarkedBlock(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == tomlMarker }) {
            var end = start
            while end < lines.count,
                  lines[end].trimmingCharacters(in: .whitespaces) != tomlMarkerEnd { end += 1 }
            lines.removeSubrange(start...min(end, lines.count - 1))
        }
        // Collapse the blank runs the removal may leave at EOF.
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Shared JSON hook helpers

    private func groupContainsOurCommand(_ group: [String: Any]) -> Bool {
        for hook in group["hooks"] as? [[String: Any]] ?? [] {
            if (hook["command"] as? String)?.contains(Self.bridgeMarker) == true { return true }
        }
        return false
    }

    private func uninstallJSONHooks(_ url: URL) throws {
        guard var settings = readJSON(url) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            var groups = value as? [[String: Any]] ?? []
            groups.removeAll { groupContainsOurCommand($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks
        try writeJSON(url, settings)
    }

    // MARK: - File IO (atomic, with one-time backup)

    func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    func writeJSON(_ url: URL, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeAtomic(url, data: data)
    }

    func writeTextAtomic(_ url: URL, _ text: String) throws {
        try writeAtomic(url, data: Data(text.utf8))
    }

    private func writeAtomic(_ url: URL, data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the user's pristine original exactly once; later installs must
        // not overwrite the backup with our own modified version.
        let backup = url.appendingPathExtension("scrollshot-bak")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Codex TOML helpers (ports of agents/codex.rs)

    /// ensure_codex_hooks_feature: insert/flip `hooks = true` under `[features]`.
    static func ensureCodexHooksFeature(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let featuresIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) else {
            var prefix = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { prefix += "\n\n" }
            return prefix + "[features]\nhooks = true\n"
        }
        let nextSection = lines[(featuresIndex + 1)...].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }) ?? lines.count
        if let hookLine = lines[featuresIndex + 1..<nextSection].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("hooks")
        }) {
            lines[hookLine] = "hooks = true"
        } else {
            lines.insert("hooks = true", at: nextSection)
        }
        return lines.joined(separator: "\n")
    }

    /// Drops `[hooks.state."<prefix>…"]` tables (header + body until the next
    /// table header), leaving every other key/table alone.
    static func removeTomlTablesWithPrefix(_ content: String, prefix: String) -> String {
        var result: [String] = []
        var skipping = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                skipping = trimmed.hasPrefix(prefix)
            }
            if !skipping { result.append(line) }
        }
        return result.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    static func tomlBasicString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// serde_json's canonical form: compact, object keys sorted. Codex's hook
    /// trust hash is sha256 over this exact byte sequence.
    static func canonicalJSON(_ value: Any) -> String {
        // CFBoolean must be checked before NSNumber — Bool bridges to NSNumber.
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        switch value {
        case let dict as [String: Any]:
            let inner = dict.keys.sorted().map { key in
                "\(canonicalJSONString(key)):\(canonicalJSON(dict[key] ?? NSNull()))"
            }.joined(separator: ",")
            return "{\(inner)}"
        case let array as [Any]:
            return "[\(array.map(canonicalJSON).joined(separator: ","))]"
        case let string as String:
            return canonicalJSONString(string)
        case let number as NSNumber:
            if number.doubleValue == number.doubleValue.rounded(),
               abs(number.doubleValue) < 9.0e15 {
                return String(number.int64Value)
            }
            return String(number.doubleValue)
        default:
            return "null"
        }
    }

    private static func canonicalJSONString(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              var text = String(data: data, encoding: .utf8) else { return "\"\"" }
        text.removeFirst()
        text.removeLast()
        return text
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Setup coordinator

/// Coordinates the master switch with hook installation: enabling installs
/// hooks for every detected agent (plus the dsh plugin when ~/.dsh exists);
/// disabling removes exactly what we installed. The list of agents the user
/// opted in is persisted so launch-time self-heal (`repairIfNeeded`) can
/// reinstall hooks that disappeared (agent reinstall, config reset) without
/// touching agents the user never enabled.
@MainActor
enum AgentBridgeSetup {
    private static let installedAgentsKey = "agentBridge.installedAgents"
    private static let dshMarker = "dsh"

    static var installedAgents: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: installedAgentsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: installedAgentsKey) }
    }

    static func enable() {
        let installer = HookInstaller()
        var installed = installedAgents
        for agent in HookInstaller.Agent.allCases where installer.agentDetected(agent) {
            if (try? installer.install(agent)) != nil { installed.insert(agent.rawValue) }
        }
        let dsh = DshPluginInstaller()
        if dsh.dshDetected, (try? dsh.install()) != nil { installed.insert(dshMarker) }
        installedAgents = installed
        FeatureSwitches.shared.setEnabled(.agentBridge, true)
    }

    static func disable() {
        let installer = HookInstaller()
        for source in installedAgents {
            if let agent = HookInstaller.Agent(rawValue: source) {
                try? installer.uninstall(agent)
            } else if source == dshMarker {
                try? DshPluginInstaller().uninstall()
            }
        }
        installedAgents = []
        FeatureSwitches.shared.setEnabled(.agentBridge, false)
    }

    /// Per-agent toggle from the settings pane.
    static func setAgent(_ source: String, installed: Bool) {
        var agents = installedAgents
        if installed {
            if let agent = HookInstaller.Agent(rawValue: source) {
                guard (try? HookInstaller().install(agent)) != nil else { return }
            } else if source == dshMarker {
                guard (try? DshPluginInstaller().install()) != nil else { return }
            }
            agents.insert(source)
        } else {
            if let agent = HookInstaller.Agent(rawValue: source) {
                try? HookInstaller().uninstall(agent)
            } else if source == dshMarker {
                try? DshPluginInstaller().uninstall()
            }
            agents.remove(source)
        }
        installedAgents = agents
    }

    /// Called at launch when the feature is on: reinstall hooks that vanished
    /// since we installed them. Only touches agents the user opted in.
    static func repairIfNeeded() {
        let installer = HookInstaller()
        for source in installedAgents {
            if let agent = HookInstaller.Agent(rawValue: source) {
                if installer.status(agent) != .installed { try? installer.install(agent) }
            } else if source == dshMarker {
                let dsh = DshPluginInstaller()
                if dsh.status() != .installed { try? dsh.install() }
            }
        }
    }
}
