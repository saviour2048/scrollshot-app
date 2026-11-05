import Foundation

/// Cross-device aggregation for Input Stats via iCloud Drive.
///
/// Each Mac writes its own raw daily stats into `ScrollShot/InputStats/<deviceID>.json`
/// inside the user's iCloud Drive. Every 30 seconds every Mac reads the other
/// devices' files and merges them with its live local counts, so the dashboard
/// and menu-bar meter show the combined totals across all of the user's Macs.
///
/// When iCloud Drive is unavailable the same file layer falls back to Application
/// Support, so local-only operation still works (it just won't see other Macs).
@MainActor
final class InputStatsSync {
    static let shared = InputStatsSync()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let syncInterval: TimeInterval = 30
    private let staleThreshold: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    /// Merged history is trimmed to the most recent N days (yyyy-MM-dd keys sort).
    private let maxHistoryDays = 120

    private var pollTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func startSyncing() {
        // Cross-device sync only makes sense while the feature itself is on;
        // otherwise this leaves a 30s polling timer resident for nothing.
        guard InputStatsSettings.enabled else { return }
        // Make sure the store exists (it loads persisted local data lazily).
        _ = InputStatsStore.shared
        syncTick()
        pollTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncTick() }
        }
    }

    func stopSyncing() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - File location

    private static var cloudDocsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    private var syncDirURL: URL {
        let fm = FileManager.default
        let base = fm.fileExists(atPath: Self.cloudDocsDir.path)
            ? Self.cloudDocsDir.appendingPathComponent("ScrollShot/InputStats")
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScrollShot/InputStats")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var localFileURL: URL {
        syncDirURL.appendingPathComponent("\(deviceID).json")
    }

    /// Stable identifier for this Mac. Generated once and stored in UserDefaults.
    private var deviceID: String {
        if let id = defaults.string(forKey: "inputStats.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "inputStats.deviceID")
        return id
    }

    // MARK: - Sync tick

    private func syncTick() {
        pushSnapshot()
        pullAndMerge()
    }

    /// Write this Mac's raw local stats to its own iCloud file.
    private func pushSnapshot() {
        let store = InputStatsStore.shared
        let snapshot = InputStatsSnapshot(
            deviceID: deviceID,
            updatedAt: Date(),
            today: store.localToday,
            history: store.localHistory
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: localFileURL, options: .atomic)
        } catch {
            NSLog("InputStatsSync push failed: \(error.localizedDescription)")
        }
    }

    /// Read the other Macs' files and recompute the merged cross-device view.
    private func pullAndMerge() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: syncDirURL, includingPropertiesForKeys: nil) else { return }

        // Ignore our own file, iCloud conflict files (contain spaces), and non-json.
        let remoteFiles = files.filter {
            $0.pathExtension == "json" &&
            $0.lastPathComponent != "\(deviceID).json" &&
            !$0.lastPathComponent.contains(" ")
        }

        let calendar = Calendar.current
        let now = Date()
        let todayKey = dateKey(for: now)

        var mergedHistory: [String: DailyInputStats] = [:]
        var mergedToday = InputStatsStore.shared.localToday

        for url in remoteFiles {
            // Materialize the file if iCloud has it as a placeholder.
            try? fm.startDownloadingUbiquitousItem(at: url)
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(InputStatsSnapshot.self, from: data) else { continue }

            // Ignore devices that haven't reported in 30 days.
            guard now.timeIntervalSince(snapshot.updatedAt) < staleThreshold else { continue }

            // Merge historical days. Skip the remote "today" entry because the
            // live `today` field below is authoritative for the current day.
            for (day, stats) in snapshot.history where day != todayKey {
                mergedHistory[day] = (mergedHistory[day] ?? DailyInputStats(date: stats.date)) + stats
            }

            // Only add the remote "today" if it refers to the same calendar day.
            if calendar.isDate(snapshot.today.date, inSameDayAs: now) {
                mergedToday = mergedToday + snapshot.today
            }
        }

        // Add this Mac's own historical days (skip today's saved snapshot; the
        // live localToday is already the starting point for mergedToday).
        for (day, stats) in InputStatsStore.shared.localHistory where day != todayKey {
            mergedHistory[day] = (mergedHistory[day] ?? DailyInputStats(date: stats.date)) + stats
        }

        // Ensure the current day appears in history too.
        mergedHistory[todayKey] = mergedToday

        // Drop all but the most recent maxHistoryDays (keys sort lexicographically).
        let sortedDays = mergedHistory.keys.sorted()
        if sortedDays.count > maxHistoryDays {
            for day in sortedDays.prefix(sortedDays.count - maxHistoryDays) { mergedHistory[day] = nil }
        }

        InputStatsStore.shared.applyMerged(today: mergedToday, history: mergedHistory)
    }

    private func dateKey(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

// MARK: - Snapshot format

private struct InputStatsSnapshot: Codable {
    let deviceID: String
    let updatedAt: Date
    let today: DailyInputStats
    let history: [String: DailyInputStats]
}
