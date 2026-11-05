import AppKit

/// One process's contribution to a resource (top-process lists in the popovers).
/// `primary` is CPU % / memory bytes / download bytes-per-sec; `secondary` is
/// upload bytes-per-sec for the network case (nil otherwise).
struct ProcInfo: Identifiable, Equatable {
    let pid: Int
    let name: String
    let primary: Double
    let secondary: Double?
    var id: Int { pid }
}

/// Runs a CLI tool and returns its stdout. Blocking — call off the main thread.
private func runCommand(_ path: String, _ args: [String], env: [String: String]? = nil) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    if let env { task.environment = env }
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

private func processName(pid: Int, fallback: String) -> String {
    if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName, !n.isEmpty {
        return n
    }
    return fallback
}

/// Top processes by CPU via `ps -Aceo pid,pcpu,comm -r` (sorted desc by CPU).
enum CPUProcessReader {
    static func read(limit: Int = 6) -> [ProcInfo] {
        let out = runCommand("/bin/ps", ["-Aceo", "pid,pcpu,comm", "-r"])
        var result: [ProcInfo] = []
        out.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]) else { return }
            let cpuStr = String(parts[1]).replacingOccurrences(of: ",", with: ".")
            guard let cpu = Double(cpuStr) else { return }
            let name = processName(pid: pid, fallback: String(parts[2]))
            result.append(ProcInfo(pid: pid, name: name, primary: cpu, secondary: nil))
            if result.count >= limit { stop = true }
        }
        return result
    }
}

/// Top processes by memory via `top -l 1 -o mem -n N -stats pid,command,mem`.
enum MemoryProcessReader {
    static func read(limit: Int = 6) -> [ProcInfo] {
        let out = runCommand("/usr/bin/top",
                             ["-l", "1", "-o", "mem", "-n", "\(limit)", "-stats", "pid,command,mem"])
        var result: [ProcInfo] = []
        out.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first.isNumber else { return }
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3, let pid = Int(tokens[0]) else { return }
            let memStr = tokens[tokens.count - 1]
            let command = tokens[1..<(tokens.count - 1)].joined(separator: " ")
            let bytes = parseMem(memStr)
            guard bytes > 0 else { return }
            result.append(ProcInfo(pid: pid, name: processName(pid: pid, fallback: command),
                                   primary: bytes, secondary: nil))
        }
        return Array(result.prefix(limit))
    }

    /// "512M" / "1.2G" / "800K" → bytes.
    private static func parseMem(_ s: String) -> Double {
        let num = Double(s.filter { "0123456789.".contains($0) }) ?? 0
        switch s.last {
        case "G": return num * 1_073_741_824
        case "M": return num * 1_048_576
        case "K": return num * 1_024
        default:  return num
        }
    }
}

/// Top processes by network via `nettop` (cumulative counters, diffed per read).
enum NetworkProcessReader {
    private static var prev: [Int: (down: Int, up: Int)] = [:]

    static func read(limit: Int = 6) -> [ProcInfo] {
        let args = ["-P", "-L", "1", "-n", "-k",
                    "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
        let out = runCommand("/usr/bin/nettop", args,
                             env: ["NSUnbufferedIO": "YES", "LC_ALL": "en_US.UTF-8"])

        var current: [Int: (name: String, down: Int, up: Int)] = [:]
        out.enumerateLines { line, _ in
            let cols = line.split(separator: ",").map(String.init)
            guard cols.count >= 3 else { return }
            let nameParts = cols[0].split(separator: ".")
            guard let pidStr = nameParts.last, let pid = Int(pidStr) else { return }
            let down = Int(cols[1]) ?? 0
            let up = Int(cols[2]) ?? 0
            let fallback = nameParts.dropLast().joined(separator: ".")
            current[pid] = (processName(pid: pid, fallback: fallback), down, up)
        }

        var result: [ProcInfo] = []
        for (pid, cur) in current {
            let p = prev[pid] ?? (down: cur.down, up: cur.up)
            let dDown = max(0, cur.down - p.down)
            let dUp = max(0, cur.up - p.up)
            if dDown > 0 || dUp > 0 {
                result.append(ProcInfo(pid: pid, name: cur.name,
                                       primary: Double(dDown), secondary: Double(dUp)))
            }
        }
        prev = current.mapValues { (down: $0.down, up: $0.up) }
        result.sort { max($0.primary, $0.secondary ?? 0) > max($1.primary, $1.secondary ?? 0) }
        return Array(result.prefix(limit))
    }
}

/// iOS 模拟器状态：有没有在跑、相关进程的总内存/CPU、占用最高的进程。
///
/// 检测口径：可执行路径含 `/CoreSimulator/Volumes/`（运行时卷）或
/// `/CoreSimulator/Devices/`（设备目录）的进程 = 已启动(booted)设备的运行时。
/// CoreSimulatorService / SimLaunchHost / SimulatorTrampoline / simdiskimaged
/// 是常驻守护进程（各占几 MB、没有 booted 设备时也活着），一律不计。
/// Simulator.app（图形界面）开着时计入总量——它是用户在操作的实体。
enum SimulatorReader {
    struct Status: Equatable {
        var running = false
        var memory: Double = 0    // bytes，RSS 合计
        var cpu: Double = 0       // %，合计
        var top: [ProcInfo] = []  // 按内存降序
    }

    static func read() -> Status {
        parse(psOutput: runCommand("/bin/ps", ["-Aeo", "pid,rss,pcpu,args"]))
    }

    /// 纯解析，便于测试。ps 行格式：`pid rss(KB) pcpu args…`。
    static func parse(psOutput: String, limit: Int = 6) -> Status {
        var status = Status()
        var procs: [ProcInfo] = []
        psOutput.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int(parts[0]),
                  let rssKB = Double(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: "."))
            else { return }
            let args = String(parts[3])
            let isRuntime = args.contains("/CoreSimulator/Volumes/")
                || args.contains("/CoreSimulator/Devices/")
            let isSimAppUI = args.contains("/Simulator.app/Contents/MacOS/")
            guard isRuntime || isSimAppUI else { return }
            status.running = true
            status.memory += rssKB * 1024
            status.cpu += cpu
            procs.append(ProcInfo(pid: pid, name: displayName(args: args, pid: pid),
                                  primary: rssKB * 1024, secondary: cpu))
        }
        procs.sort { $0.primary > $1.primary }
        status.top = Array(procs.prefix(limit))
        return status
    }

    /// 从完整命令行提取显示名。模拟器运行时路径可能带空格
    /// （如 "iOS 26.5.simruntime"），所以先截到 .app/.xpc 边界再取末段。
    private static func displayName(args: String, pid: Int) -> String {
        var path = args
        // 注意取最后一个边界：Xcode 里的 Simulator.app 路径前面还有 "Xcode.app/"。
        var cutAtBundle = false
        for marker in [".app/", ".xpc/", ".app", ".xpc"] {
            if let r = path.range(of: marker, options: .backwards) {
                path = String(path[path.startIndex..<r.upperBound])
                    .trimmingCharacters(in: .init(charactersIn: "/"))
                cutAtBundle = true
                break
            }
        }
        // 只有没截到 bundle 边界时才按空格去参数——bundle 内路径本身可能带空格
        // ("iOS 26.5.simruntime")，截完边界后再按空格切会把名字砍残。
        if !cutAtBundle, let space = path.firstIndex(of: " ") {
            path = String(path[path.startIndex..<space])
        }
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") || name.hasSuffix(".xpc") {
            name = (name as NSString).deletingPathExtension
        }
        return processName(pid: pid, fallback: name)
    }
}

/// `xcrun simctl list devices booted` 的已启动设备名（只在 popover 打开时调用，
/// xcrun 启动开销大，不进 2 秒轮询）。
enum SimulatorDeviceReader {
    static func bootedNames() -> [String] {
        parse(simctlOutput: runCommand("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"]))
    }

    /// 纯解析：含 "(Booted)" 的行。行格式 `名称 (UUID) (Booted)`，名称本身可能
    /// 带括号（"Apple Watch Series 11 (46mm)"），所以先去状态后缀、再按最后一个
    /// " (" 切掉 UUID。
    static func parse(simctlOutput: String) -> [String] {
        var names: [String] = []
        simctlOutput.enumerateLines { line, _ in
            guard line.contains("(Booted)"),
                  let stateRange = line.range(of: " (", options: .backwards),
                  line[stateRange.lowerBound...].contains("Booted") else { return }
            var rest = line[line.startIndex..<stateRange.lowerBound]
            if let uuidRange = rest.range(of: " (", options: .backwards) {
                rest = rest[rest.startIndex..<uuidRange.lowerBound]
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }
}
