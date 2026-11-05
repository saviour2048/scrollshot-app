import Foundation

/// Scans Claude Code's local session logs to compute cost + token usage.
///
/// Walks `~/.claude/projects/**/*.jsonl` (and `~/.config/claude/projects`),
/// keeps `type == "assistant"` lines, de-duplicates streaming chunks by
/// `messageId:requestId` (cumulative usage → last write wins), and multiplies
/// token counts by `UsagePricing`.
///
/// Pure / off-main; call from a background queue. No network, no cost beyond CPU.
enum UsageLogScanner {
    /// One de-duplicated assistant message's billable usage.
    private struct Entry {
        var model: String
        var day: Date          // start-of-day, local
        var timestamp: Date
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite5m: Int
        var cacheWrite1h: Int
        var dedupKey: String? = nil  // "messageId:requestId", nil when neither id present
        var tokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
        var cost: Double {
            UsagePricing.cost(model: model, input: input, output: output,
                              cacheRead: cacheRead, cacheWrite5m: cacheWrite5m,
                              cacheWrite1h: cacheWrite1h)
        }
    }

    private static let windowDays = 30

    /// Per-file parse cache, keyed by URL. A file's parsed entries only change when
    /// the file does, so we re-parse just the file(s) whose modification date moved
    /// (the active session log) and reuse everything else. This is what keeps the
    /// 120s auto-refresh from re-chewing hundreds of MB every time (the CPU hang).
    /// Only ever touched from the serial scan queue → no locking needed.
    ///
    /// 缓存记录已解析到的字节 offset：mtime 没变 → 直接复用 entries；
    /// mtime 变了但文件只是追加（新 size >= offset）→ 只从 offset 增量解析新行；
    /// size < offset（文件被截断/轮转）→ 从头重扫。
    private struct CachedFile {
        var mtime: Date
        var offset: Int            // 已解析的字节数（只含以换行符结尾的完整行）
        var entries: [Entry]       // 完整行的解析结果
        /// 末尾半行（无换行符）的解析结果。真正的写入中半行不是合法 JSON → 为空；
        /// 但已写完、只是缺末尾换行的文件，最后一行也要求计入（与原全量解析语义一致）。
        /// 半行不进 entries、offset 回退到行首：下次文件追加后从行首重读，
        /// tailEntries 整体被替换而非累加，因此不会重复计数。
        var tailEntries: [Entry]
    }
    private static var fileCache: [URL: CachedFile] = [:]

    /// 缓存文件数硬上限，超出按 mtime 最旧淘汰（30 天窗口清理之外的再保险）。
    private static let maxCachedFiles = 500

    static func scan(roots: [URL]? = nil, now: Date = Date()) -> CostSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let cutoff = cal.date(byAdding: .day, value: -(windowDays - 1), to: today) else {
            return CostSummary()
        }

        // Process logs as raw BYTES, not Swift Strings. Loading hundreds of MB of
        // logs as `String` (Unicode-correct, slow) + per-line String ops is what
        // pinned the CPU. Memory-map each file, split on newline bytes, and
        // byte-filter for `"usage"` — only the few assistant lines that match are
        // ever turned into a String + JSON-parsed.
        let usageNeedle = Data("\"usage\"".utf8)
        let newline: UInt8 = 0x0A
        let scanRoots = roots ?? defaultRoots()
        let files = logFiles(roots: scanRoots,
                             modifiedAfter: cal.date(byAdding: .day, value: -2, to: cutoff) ?? cutoff)

        var allEntries: [Entry] = []
        var filesScanned = 0
        for fileURL in files {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate
            let size = values?.fileSize ?? 0
            if let cached = fileCache[fileURL], let m = mtime, cached.mtime == m {
                allEntries.append(contentsOf: cached.entries)   // unchanged → reuse
                allEntries.append(contentsOf: cached.tailEntries)
                continue
            }
            filesScanned += 1

            if let cached = fileCache[fileURL], let m = mtime, size >= cached.offset {
                // 增量：文件只是变长，从上次解析到的 offset 起只读追加的字节
                //（offset 含半行行首，半行会被重读并整体替换 tailEntries，不会重复）。
                var entries = cached.entries
                var tailEntries = cached.tailEntries
                var offset = cached.offset
                if size > cached.offset {
                    guard let chunk = readBytes(fileURL, from: cached.offset) else {
                        // 读失败：保留旧缓存（不更新 mtime），下次 scan 重试，避免丢掉追加的数据
                        allEntries.append(contentsOf: entries)
                        allEntries.append(contentsOf: tailEntries)
                        continue
                    }
                    let parsed = parseCompleteLines(chunk, needle: usageNeedle, newline: newline, calendar: cal)
                    entries.append(contentsOf: parsed.entries)   // cache ALL (cutoff moves daily; filter at use)
                    tailEntries = parsed.tailEntries
                    offset += parsed.consumed
                }
                fileCache[fileURL] = CachedFile(mtime: m, offset: offset, entries: entries, tailEntries: tailEntries)
                allEntries.append(contentsOf: entries)
                allEntries.append(contentsOf: tailEntries)
            } else {
                // 全量：首次见到该文件，或 size < offset（文件被截断/轮转）→ 从头重扫。
                var fileEntries: [Entry] = []
                var tailEntries: [Entry] = []
                var offset = 0
                if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                    let parsed = parseCompleteLines(data, needle: usageNeedle, newline: newline, calendar: cal)
                    fileEntries = parsed.entries   // cache ALL (cutoff moves daily; filter at use)
                    tailEntries = parsed.tailEntries
                    offset = parsed.consumed
                }
                if let m = mtime {
                    fileCache[fileURL] = CachedFile(mtime: m, offset: offset, entries: fileEntries, tailEntries: tailEntries)
                }
                allEntries.append(contentsOf: fileEntries)
                allEntries.append(contentsOf: tailEntries)
            }
        }
        // 淘汰缓存：先清掉 30 天窗口外的文件条目，再按 mtime 最旧淘汰到硬上限以内。
        let live = Set(files)
        fileCache = fileCache.filter { live.contains($0.key) }
        if fileCache.count > maxCachedFiles {
            fileCache = Dictionary(fileCache.sorted { $0.value.mtime > $1.value.mtime }
                                               .prefix(maxCachedFiles)
                                               .map { ($0.key, $0.value) },
                                   uniquingKeysWith: { first, _ in first })
        }

        // Dedup streaming chunks (last cumulative usage wins) within the window.
        var deduped: [String: Entry] = [:]
        var anonymous: [Entry] = []
        for e in allEntries where e.day >= cutoff {
            if let key = e.dedupKey { deduped[key] = e } else { anonymous.append(e) }
        }
        let entries = Array(deduped.values) + anonymous
        return summarize(entries, today: today, cutoff: cutoff, calendar: cal,
                         filesScanned: filesScanned)
    }

    // MARK: File discovery

    private static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects")
        ]
    }

    private static func logFiles(roots: [URL], modifiedAfter date: Date) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let mod = values?.contentModificationDate, mod < date { continue }
                result.append(url)
            }
        }
        return result
    }

    // MARK: Parsing

    /// 只读文件从 offset 开始追加的字节（增量扫描用），避免每轮全量 memory-map。
    private static func readBytes(_ url: URL, from offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    /// 把一段字节切成完整行并解析。最后一行若没有换行符（半行）：
    /// consumed 只算到最后一个换行符为止 —— 调用方据此把 offset 回退到半行行首，
    /// 等文件追加后重读；但半行本身也尝试解析一次，结果单独放进 tailEntries
    ///（已写完、只是缺末尾换行的文件，最后一行必须计入；真正写到一半的半行
    ///  不是合法 JSON，parseLine 会失败，tailEntries 自然为空）。
    private static func parseCompleteLines(_ data: Data, needle: Data, newline: UInt8,
                                           calendar: Calendar) -> (entries: [Entry], tailEntries: [Entry], consumed: Int) {
        var entries: [Entry] = []
        var consumed = 0
        var idx = data.startIndex
        let end = data.endIndex
        while idx < end {
            guard let nl = data[idx..<end].firstIndex(of: newline) else { break }   // 半行，offset 回退到行首
            let lineData = data[idx..<nl]
            idx = data.index(after: nl)
            consumed = idx - data.startIndex
            guard !lineData.isEmpty, lineData.range(of: needle) != nil,
                  let line = String(data: lineData, encoding: .utf8),
                  let entry = parseLine(line, calendar: calendar) else { continue }
            entries.append(entry)
        }
        var tailEntries: [Entry] = []
        if idx < end {
            let lineData = data[idx..<end]
            if !lineData.isEmpty, lineData.range(of: needle) != nil,
               let line = String(data: lineData, encoding: .utf8),
               let entry = parseLine(line, calendar: calendar) {
                tailEntries.append(entry)
            }
        }
        return (entries, tailEntries, consumed)
    }

    private static func parseLine(_ line: String, calendar: Calendar) -> Entry? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        guard let ts = (obj["timestamp"] as? String).flatMap(parseTimestamp) else { return nil }
        let model = (message["model"] as? String) ?? "unknown"

        var entry = Entry(
            model: model,
            day: calendar.startOfDay(for: ts),
            timestamp: ts,
            input: intVal(usage["input_tokens"]),
            output: intVal(usage["output_tokens"]),
            cacheRead: intVal(usage["cache_read_input_tokens"]),
            cacheWrite5m: intVal(usage["cache_creation_input_tokens"]),
            cacheWrite1h: 0
        )
        if let cc = usage["cache_creation"] as? [String: Any] {
            entry.cacheWrite1h = intVal(cc["ephemeral_1h_input_tokens"])
            // When the nested breakdown is present, prefer its 5m value.
            let fiveM = intVal(cc["ephemeral_5m_input_tokens"])
            if fiveM > 0 { entry.cacheWrite5m = fiveM }
        }
        // Stash dedup ids on the model string? No — return via a tuple instead.
        entry.dedupKey = dedupKey(message: message, obj: obj)
        return entry
    }

    private static func dedupKey(message: [String: Any], obj: [String: Any]) -> String? {
        let messageId = message["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (message["request_id"] as? String)
        guard messageId != nil || requestId != nil else { return nil }
        return "\(messageId ?? "?"):\(requestId ?? "?")"
    }

    private static func intVal(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    // MARK: Aggregation

    private static func summarize(_ entries: [Entry], today: Date, cutoff: Date, calendar: Calendar, filesScanned: Int) -> CostSummary {
        var summary = CostSummary()
        summary.filesScanned = filesScanned
        summary.entriesParsed = entries.count
        var dayCost: [Date: Double] = [:]
        var dayTokens: [Date: Int] = [:]

        for e in entries {
            summary.cost30d += e.cost
            summary.tokens30d += e.tokens
            if e.day == today { summary.todayCost += e.cost }
            dayCost[e.day, default: 0] += e.cost
            dayTokens[e.day, default: 0] += e.tokens
            summary.perModelTokens[familyName(e.model), default: 0] += e.tokens
        }

        // Build a gap-free 30-day series (oldest → newest).
        var daily: [DailyUsage] = []
        var d = cutoff
        while d <= today {
            daily.append(DailyUsage(day: d, cost: dayCost[d] ?? 0, tokens: dayTokens[d] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        summary.daily = daily
        summary.latestDayTokens = daily.last(where: { $0.tokens > 0 })?.tokens ?? 0
        summary.topModel = summary.perModelTokens.max(by: { $0.value < $1.value })?.key
        return summary
    }

    /// Collapse a dated model id to a readable family (e.g. "claude-opus-4-5" → "Opus").
    private static func familyName(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        return model
    }
}
