import Foundation
import Darwin

/// scrollshot-bridge — hook bridge binary invoked by AI CLI hooks
/// (Claude Code / Codex / Kimi Code / dsh).
///
/// Usage: `scrollshot-bridge --source claude|codex|kimi`
///
/// Behavior:
///   1. Reads the complete hook event JSON from stdin.
///   2. Connects to the ScrollShot app's unix socket at
///      `/tmp/scrollshot-agent-<uid>.sock`.
///   3. Sends one line: the original event JSON plus a `source` field.
///   4. Waits for one response line (read timeout 300s — shorter than the
///      CLI's own hook timeout, so the bridge times out first).
///   5. Prints the response's `stdout` field verbatim to stdout and exits
///      with the response's `exitCode` (default 0).
///
/// Fail-open: ANY error (no socket, timeout, malformed JSON) exits 0 with no
/// output, so the CLI falls back to its native prompt.
///
/// The bridge is a dumb courier on purpose: all protocol translation
/// (event + user decision → each CLI's stdout protocol JSON) lives in the
/// app's AgentBridgeProtocols, which is unit-testable.

private let readTimeoutSeconds: Int32 = 300

private func failOpen() -> Never {
    // Silent success — the CLI treats this as "hook did nothing".
    exit(0)
}

private func parseArgs() -> String {
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        if arg == "--source", let value = args.popFirst(), !value.isEmpty {
            return value
        }
    }
    return "claude"
}

private var socketPath: String {
    "/tmp/scrollshot-agent-\(getuid()).sock"
}

/// Connects to the unix socket and returns the fd, or nil on any failure.
private func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    let copied = path.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dest in
                strncpy(dest, cstr, pathCapacity - 1)
            }
        }
        return strlen(cstr) + 1
    }
    guard copied < pathCapacity else { close(fd); return nil }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { close(fd); return nil }

    var tv = timeval(tv_sec: Int(readTimeoutSeconds), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    let bytes = [UInt8](data)
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { buf in
            write(fd, buf.baseAddress! + sent, bytes.count - sent)
        }
        guard n > 0 else { return false }
        sent += n
    }
    return true
}

/// Reads one newline-terminated line. Returns nil on timeout/error/EOF
/// before any byte.
private func readLine(_ fd: Int32) -> Data? {
    var out = Data()
    var byte = [UInt8](repeating: 0, count: 1)
    while true {
        let n = read(fd, &byte, 1)
        guard n == 1 else { return out.isEmpty ? nil : out }
        if byte[0] == UInt8(ascii: "\n") { return out }
        out.append(byte[0])
        // Guard against a peer that never sends a newline.
        if out.count > 8 * 1024 * 1024 { return nil }
    }
}

let source = parseArgs()

// 1. Read the whole hook event from stdin.
let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty,
      let event = try? JSONSerialization.jsonObject(with: inputData),
      var dict = event as? [String: Any]
else { failOpen() }

// 2. Tag the event with the agent source and forward it, one line.
dict["source"] = source
// The terminal that launched the CLI leaks through `__CFBundleIdentifier`;
// forward it so the app can offer "open terminal" on cards. (Empty on Linux-
// style launches; the app falls back to Terminal.app.)
if let bundleID = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !bundleID.isEmpty {
    dict["_term_bundle_id"] = bundleID
}
guard let line = try? JSONSerialization.data(withJSONObject: dict) else { failOpen() }
var payload = line
payload.append(UInt8(ascii: "\n"))

guard let fd = connectSocket() else { failOpen() }
defer { close(fd) }
guard writeAll(fd, payload) else { failOpen() }

// 3. Every event waits for a one-line response (uniform protocol; the app
//    answers non-interactive events immediately with {"action":"none"}).
guard let responseData = readLine(fd),
      let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
else { failOpen() }

// 4. Print `stdout` verbatim (it already is the CLI's protocol JSON, built
//    by the app) and exit with `exitCode`.
if let out = response["stdout"] as? String, !out.isEmpty {
    FileHandle.standardOutput.write(Data(out.utf8))
}
let code = (response["exitCode"] as? NSNumber)?.int32Value ?? 0
exit(code)
