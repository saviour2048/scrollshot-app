import XCTest
@testable import ScrollShot

/// HookInstaller against a temp "home" directory: idempotent install, clean
/// uninstall, preservation of the user's pre-existing hooks, Codex's
/// config.toml feature flag + trust table.
final class HookInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: HookInstaller!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrollshot-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Stub bridge binary so installBridgeBinary has something to copy.
        let stub = home.appendingPathComponent("bridge-stub")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        installer = HookInstaller(home: home, bridgeSource: stub)
        // Pretend every agent exists.
        for dir in [".claude", ".codex", ".kimi-code"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func readSettings(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(relative))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hookCommands(_ settings: [String: Any], _ event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    // MARK: Claude

    func testClaudeInstallShapeAndIdempotency() throws {
        // Pre-existing user hook must survive.
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: home.appendingPathComponent(".claude/settings.json"))

        try installer.install(.claude)
        try installer.install(.claude)   // 幂等:装两次不重复

        let settings = try readSettings(".claude/settings.json")
        XCTAssertEqual(settings["model"] as? String, "opus")

        // User hook preserved.
        XCTAssertTrue(hookCommands(settings, "PreToolUse").contains("/usr/local/bin/my-hook"))

        // Our entries: exactly one per event, correct timeout/matcher.
        let bridge = home.appendingPathComponent(".scrollshot/bin/scrollshot-bridge").path + " --source claude"
        for event in ["PermissionRequest", "SessionStart", "Stop", "Notification"] {
            XCTAssertEqual(hookCommands(settings, event).filter { $0 == bridge }.count, 1, event)
        }
        XCTAssertEqual(hookCommands(settings, "PreToolUse").filter { $0 == bridge }.count, 1)

        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let permissionGroups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        let ourGroup = permissionGroups.first { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("scrollshot-bridge") == true } == true
        }
        XCTAssertEqual(ourGroup?["matcher"] as? String, "*")
        let hook = (ourGroup?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["timeout"] as? Int, 21600)
        XCTAssertEqual(hook?["type"] as? String, "command")

        let preToolGroups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let ourPreTool = preToolGroups.first { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("scrollshot-bridge") == true } == true
        }
        XCTAssertEqual(ourPreTool?["matcher"] as? String, "AskUserQuestion")

        // Bridge binary copied.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".scrollshot/bin/scrollshot-bridge").path))
        // First mutation made a backup of the user's original.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/settings.json.scrollshot-bak").path))

        XCTAssertEqual(installer.status(.claude), .installed)
    }

    func testClaudeUninstallKeepsUserHooks() throws {
        let existing: [String: Any] = [
            "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "/bin/echo hi"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: home.appendingPathComponent(".claude/settings.json"))

        try installer.install(.claude)
        try installer.uninstall(.claude)

        let settings = try readSettings(".claude/settings.json")
        XCTAssertEqual(hookCommands(settings, "SessionStart"), ["/bin/echo hi"])
        XCTAssertEqual(hookCommands(settings, "PermissionRequest"), [])
        XCTAssertEqual(installer.status(.claude), .notInstalled)
    }

    // MARK: Codex

    func testCodexInstallAddsFeatureFlagAndTrustEntries() throws {
        // User's existing config.toml keys must survive.
        try """
        model = "gpt-5"

        [features]
        goals = true

        [projects."/tmp/example"]
        trust_level = "trusted"
        """.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        try installer.install(.codex)
        try installer.install(.codex)   // 幂等

        let hooks = try readSettings(".codex/hooks.json")
        let bridge = home.appendingPathComponent(".scrollshot/bin/scrollshot-bridge").path + " --source codex"
        XCTAssertEqual(hookCommands(hooks, "PermissionRequest").filter { $0 == bridge }.count, 1)
        XCTAssertEqual(hookCommands(hooks, "SessionEnd").filter { $0 == bridge }.count, 1)

        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("[features]"))
        XCTAssertTrue(toml.contains("hooks = true"))
        // 现有键未被破坏
        XCTAssertTrue(toml.contains("model = \"gpt-5\""))
        XCTAssertTrue(toml.contains("goals = true"))
        XCTAssertTrue(toml.contains("[projects.\"/tmp/example\"]"))
        // 每个事件一条信任记录,且重装不重复
        let trustCount = toml.components(separatedBy: "[hooks.state.").count - 1
        XCTAssertEqual(trustCount, 10)
        XCTAssertTrue(toml.contains(":permission_request:0:0"))
        XCTAssertTrue(toml.contains("trusted_hash = \"sha256:"))
        XCTAssertEqual(installer.status(.codex), .installed)
    }

    func testCodexUninstallRemovesTrustEntries() throws {
        try installer.install(.codex)
        try installer.uninstall(.codex)

        let hooks = try readSettings(".codex/hooks.json")
        XCTAssertEqual(hookCommands(hooks, "PermissionRequest"), [])
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(toml.contains("[hooks.state."))
        XCTAssertTrue(toml.contains("hooks = true"))   // feature 开关保留(无害)
    }

    // MARK: Kimi

    func testKimiInstallPreservesConfigAndUninstallsCleanly() throws {
        try """
        model = "kimi-k2"
        model_reasoning_effort = "high"

        [tui]
        theme = "dark"
        """.write(to: home.appendingPathComponent(".kimi-code/config.toml"), atomically: true, encoding: .utf8)

        try installer.install(.kimi)
        try installer.install(.kimi)

        let toml = try String(contentsOf: home.appendingPathComponent(".kimi-code/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"kimi-k2\""))
        XCTAssertTrue(toml.contains("[tui]"))
        // 标记块只出现一次
        XCTAssertEqual(toml.components(separatedBy: HookInstaller.tomlMarker).count - 1, 2) // begin + end
        XCTAssertTrue(toml.contains("event = \"PermissionRequest\""))
        XCTAssertTrue(toml.contains("timeout = 600"))
        XCTAssertTrue(toml.contains("event = \"PreToolUse\""))
        XCTAssertTrue(toml.contains("matcher = \"AskUserQuestion\""))
        XCTAssertEqual(installer.status(.kimi), .installed)

        try installer.uninstall(.kimi)
        let stripped = try String(contentsOf: home.appendingPathComponent(".kimi-code/config.toml"), encoding: .utf8)
        XCTAssertFalse(stripped.contains("scrollshot"))
        XCTAssertTrue(stripped.contains("model = \"kimi-k2\""))
        XCTAssertTrue(stripped.contains("[tui]"))
        XCTAssertEqual(installer.status(.kimi), .notInstalled)
    }

    // MARK: Status

    func testAgentMissingWhenConfigDirAbsent() throws {
        let empty = home.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let bare = HookInstaller(home: empty, bridgeSource: installer.bridgeSource)
        XCTAssertEqual(bare.status(.claude), .agentMissing)
        XCTAssertEqual(bare.status(.kimi), .agentMissing)
    }

    func testStatusModifiedWhenCommandChanged() throws {
        try installer.install(.claude)
        // 用户/别的版本改了我们的 hook 命令
        var settings = try readSettings(".claude/settings.json")
        settings["hooks"] = [
            "PermissionRequest": [["matcher": "*", "hooks": [["type": "command", "command": "/old/path/scrollshot-bridge --source claude"]]]],
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(installer.status(.claude), .modified)
    }

    // MARK: Codex TOML helpers

    func testCanonicalJSONSortsKeys() {
        let value: [String: Any] = ["b": 1, "a": [true, "x"], "c": NSNull()]
        XCTAssertEqual(HookInstaller.canonicalJSON(value), #"{"a":[true,"x"],"b":1,"c":null}"#)
    }

    func testEnsureCodexHooksFeatureKeepsExistingKeys() {
        let content = "model = \"gpt-5\"\n\n[features]\ngoals = true\n\n[projects.\"/tmp/x\"]\ntrust_level = \"trusted\"\n"
        let updated = HookInstaller.ensureCodexHooksFeature(content)
        XCTAssertTrue(updated.contains("goals = true"))
        XCTAssertTrue(updated.contains("hooks = true"))
        XCTAssertTrue(updated.contains("[projects.\"/tmp/x\"]"))
        // 已有 hooks = true 时不重复插入
        let again = HookInstaller.ensureCodexHooksFeature(updated)
        XCTAssertEqual(again.components(separatedBy: "hooks = true").count - 1, 1)
    }
}
