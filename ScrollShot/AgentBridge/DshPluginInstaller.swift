import Foundation

/// Installs the dsh (deepseek-harness) Cordis plugin that forwards the web
/// UI's approval / user-question waterfalls to the ScrollShot notch card.
///
/// Layout (dsh profile = `$DSH_HOME/profiles/web`):
/// - `plugins/scrollshot-notch/{package.json,index.js}` — the plugin source
/// - `node_modules/scrollshot-notch` — symlink into plugins/, so the profile
///   loader can resolve the row's `name` without running pnpm
/// - `cordis.patch.yml` — appended `- insert: [{id,name}]` row, wrapped in
///   `# scrollshot-agent-notch` marker comments for clean removal
///
/// The plugin JS talks the same newline-JSON unix socket protocol as the
/// bridge binary, with `source: "dsh"`. Its replies use the `result` field
/// (see AgentBridgeProtocols.BridgeResponse.result), not the CLI `stdout`
/// protocol.
struct DshPluginInstaller {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var dshDir: URL { home.appendingPathComponent(".dsh") }
    private var profileDir: URL { dshDir.appendingPathComponent("profiles/web") }
    private var pluginDir: URL { profileDir.appendingPathComponent("plugins/scrollshot-notch") }
    private var patchFile: URL { profileDir.appendingPathComponent("cordis.patch.yml") }
    private var nodeModulesLink: URL { profileDir.appendingPathComponent("node_modules/scrollshot-notch") }

    var dshDetected: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dshDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    func status() -> HookInstaller.Status {
        guard dshDetected else { return .agentMissing }
        // fileExists(atPath:) follows the link; require the symlink to both
        // exist and resolve, so a broken link doesn't report as installed.
        let linkOK = (try? FileManager.default.destinationOfSymbolicLink(atPath: nodeModulesLink.path)) != nil
            && FileManager.default.fileExists(atPath: nodeModulesLink.path)
        let pluginInstalled = FileManager.default.fileExists(
            atPath: pluginDir.appendingPathComponent("index.js").path) && linkOK
        let patchInstalled = (try? String(contentsOf: patchFile, encoding: .utf8))?
            .contains(HookInstaller.tomlMarker) == true
        switch (pluginInstalled, patchInstalled) {
        case (true, true):   return .installed
        case (false, false): return .notInstalled
        default:             return .modified
        }
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try Self.packageJSON.write(to: pluginDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try Self.pluginJS.write(to: pluginDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        // Loader resolution: profile node_modules → plugins/ symlink.
        let nodeModules = nodeModulesLink.deletingLastPathComponent()
        try fm.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        // fileExists(atPath:) follows links and misses a broken one, so remove
        // any stale entry first — this also lets re-install repair a bad link.
        try? fm.removeItem(at: nodeModulesLink)
        // The destination must stay the literal relative path: going through
        // URL(fileURLWithPath:) resolves it against the process cwd ("/" when
        // launched from Finder) and writes a broken "/../plugins/..." link.
        try fm.createSymbolicLink(atPath: nodeModulesLink.path, withDestinationPath: "../plugins/scrollshot-notch")

        // Patch row, appended once (re-install replaces the marked block).
        let existing = (try? String(contentsOf: patchFile, encoding: .utf8)) ?? ""
        if fm.fileExists(atPath: patchFile.path),
           !fm.fileExists(atPath: patchFile.appendingPathExtension("scrollshot-bak").path) {
            try fm.copyItem(at: patchFile, to: patchFile.appendingPathExtension("scrollshot-bak"))
        }
        var content = HookInstaller.stripMarkedBlock(existing)
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        content += Self.patchBlock + "\n"
        try content.write(to: patchFile, atomically: true, encoding: .utf8)
    }

    func uninstall() throws {
        let fm = FileManager.default
        // Not fileExists: a broken symlink must still be removable.
        if (try? fm.destinationOfSymbolicLink(atPath: nodeModulesLink.path)) != nil { try fm.removeItem(at: nodeModulesLink) }
        if fm.fileExists(atPath: pluginDir.path) { try fm.removeItem(at: pluginDir) }
        guard let existing = try? String(contentsOf: patchFile, encoding: .utf8) else { return }
        let stripped = HookInstaller.stripMarkedBlock(existing)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try fm.removeItem(at: patchFile)
        } else {
            try stripped.write(to: patchFile, atomically: true, encoding: .utf8)
        }
    }

    private static let patchBlock = """
    # scrollshot-agent-notch
    - insert:
        - id: scrollshot-notch
          name: scrollshot-notch
    # scrollshot-agent-notch end
    """

    private static let packageJSON = """
    {
      "name": "scrollshot-notch",
      "version": "0.1.0",
      "private": true,
      "type": "module",
      "main": "index.js",
      "exports": { ".": "./index.js" },
      "peerDependencies": { "@deepseek-ai/cordis": "*" }
    }
    """

    /// The Cordis plugin. Approval answers map to dsh's ApprovalOutcome
    /// ('allowed-once' / 'rejected'); question answers map to
    /// {answers: [{id, selected, custom?}]} — `custom` carries free-text
    /// answers for questions that offered no options. `next()` on any failure
    /// hands the prompt back to the browser UI.
    private static let pluginJS = #"""
    // scrollshot-notch — forwards dsh approval/question prompts to the
    // ScrollShot macOS notch card over a unix socket. Any failure (no socket,
    // timeout, bad reply) falls through to the browser UI via next().

    import net from 'node:net'

    const SOCKET_PATH = `/tmp/scrollshot-agent-${process.getuid()}.sock`
    const TIMEOUT_MS = 120_000

    function askScrollShot(event) {
      return new Promise((resolve) => {
        let settled = false
        const finish = (value) => {
          if (settled) return
          settled = true
          try { socket?.destroy() } catch {}
          resolve(value)
        }
        let socket
        try {
          socket = net.createConnection(SOCKET_PATH)
        } catch {
          finish(null)
          return
        }
        let buffer = ''
        socket.setTimeout(TIMEOUT_MS)
        socket.on('timeout', () => finish(null))
        socket.on('error', () => finish(null))
        socket.on('connect', () => {
          socket.write(JSON.stringify({ ...event, source: 'dsh' }) + '\n')
        })
        socket.on('data', (chunk) => {
          buffer += chunk.toString('utf8')
          const newline = buffer.indexOf('\n')
          if (newline < 0) return
          try {
            finish(JSON.parse(buffer.slice(0, newline)))
          } catch {
            finish(null)
          }
        })
        socket.on('close', () => finish(null))
      })
    }

    async function onApproval(request, next) {
      const response = await askScrollShot({
        hook_event_name: 'PermissionRequest',
        tool_name: request.toolName,
        reason: request.reason,
        tool_input: { reason: request.reason },
      })
      const decision = response?.result?.decision
      if (decision === 'allow') return 'allowed-once'
      if (decision === 'deny') return 'rejected'
      return next()
    }

    async function onUserQuestions(request, next) {
      const questions = (request.questions ?? []).map((q) => ({
        question: q.question,
        header: q.header ?? '',
        options: q.options ?? [],
        multiSelect: q.multiSelect === true,
      }))
      const response = await askScrollShot({
        hook_event_name: 'AskUserQuestion',
        tool_name: 'AskUserQuestion',
        tool_input: { questions },
      })
      const answers = response?.result?.answers
      const customs = response?.result?.customs ?? {}
      if ((!answers || typeof answers !== 'object') && Object.keys(customs).length === 0) return next()
      const items = (request.questions ?? []).map((q) => ({
        id: q.id,
        selected: Array.isArray(answers?.[q.question]) ? answers[q.question] : [],
        ...(typeof customs[q.question] === 'string' && customs[q.question]
          ? { custom: customs[q.question] }
          : {}),
      }))
      if (items.every((item) => item.selected.length === 0 && !item.custom)) return next()
      return { answers: items }
    }

    export function apply(ctx) {
      ctx.on('approval/request', onApproval, { prepend: true })
      ctx.on('user-questions/request', onUserQuestions, { prepend: true })
    }
    """#
}
