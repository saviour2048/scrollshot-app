import Foundation
import AppKit
import Combine

/// Settings for the input-stats feature.
enum InputStatsSettings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "inputStats.enabled") as? Bool ?? false }
        set {
            d.set(newValue, forKey: "inputStats.enabled")
            Task { @MainActor in InputStatsStatusItemController.shared.reload() }
        }
    }

    static var showInMenuBar: Bool {
        get { d.object(forKey: "inputStats.showInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "inputStats.showInMenuBar") }
    }
}

/// Owns daily input statistics: keystrokes, clicks, mouse distance, scroll distance.
/// Inspired by KeyStats (https://github.com/debugtheworldbot/keyStats, MIT).
///
/// The store keeps two views of the data:
///   • `localToday` / `localHistory`: raw counts recorded on *this* Mac. These are
///     persisted locally and pushed to iCloud for other Macs to read.
///   • `today` / `history`: merged, cross-device view. `InputStatsSync` updates these
///     by aggregating this Mac's live local counts with the files written by other
///     Macs. The dashboard and menu-bar meter render this merged view.
@MainActor
final class InputStatsStore: ObservableObject {
    static let shared = InputStatsStore()

    /// Raw counts for this device. Pushed to iCloud; not directly rendered.
    private(set) var localToday = DailyInputStats()
    private(set) var localHistory: [String: DailyInputStats] = [:]

    /// Cross-device merged counts. Updated by `InputStatsSync` after every pull.
    @Published private(set) var today = DailyInputStats()
    @Published private(set) var history: [String: DailyInputStats] = [:]

    var onUpdate: (() -> Void)?

    private let userDefaults = UserDefaults.standard
    private let todayKey = "inputStats.today"
    private let historyKey = "inputStats.history"
    private let dateFormatter: DateFormatter
    private let lock = NSLock()
    private var saveTimer: Timer?
    private var midnightTimer: Timer?
    private var lastMousePoint: NSPoint?

    /// History is trimmed to the most recent N days; yyyy-MM-dd keys sort
    /// lexicographically, so a plain suffix on the sorted keys is enough.
    private static let maxHistoryDays = 120

    private init() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = df

        self.localHistory = loadHistory()
        self.localToday = loadToday() ?? DailyInputStats()
        self.history = localHistory
        self.today = localToday
        ensureCurrentDay()
        setupMidnightReset()
    }

    // MARK: - Public mutation

    func recordKeyPress(keyName: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        localToday.keyPresses += 1
        today.keyPresses += 1
        if let name = keyName, !name.isEmpty {
            localToday.keyPressCounts[name, default: 0] += 1
            today.keyPressCounts[name, default: 0] += 1
        }
        scheduleSave()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
    }

    func recordLeftClick() {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        localToday.leftClicks += 1
        today.leftClicks += 1
        scheduleSave()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
    }

    func recordRightClick() {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        localToday.rightClicks += 1
        today.rightClicks += 1
        scheduleSave()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
    }

    func recordMouseMove(to point: NSPoint) {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        if let last = lastMousePoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            let distance = hypot(dx, dy)
            localToday.mouseDistance += distance
            today.mouseDistance += distance
            scheduleSave()
        }
        lastMousePoint = point
    }

    /// Batch-friendly variant: the caller has already accumulated distance and
    /// only needs us to update state. This avoids one @MainActor hop per event.
    func recordMouseMove(distance: CGFloat, endPoint: NSPoint) {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        localToday.mouseDistance += distance
        today.mouseDistance += distance
        scheduleSave()
        lastMousePoint = endPoint
    }

    func recordScroll(delta: Double) {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
        localToday.scrollDistance += abs(delta)
        today.scrollDistance += abs(delta)
        scheduleSave()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
    }

    func resetToday() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        localToday = DailyInputStats(date: now)
        // Reset the rendered today to local-only; the next sync will re-add
        // any other active Macs' contributions for today.
        today = localToday
        scheduleSave()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
    }

    // MARK: - Cross-device merge (called by InputStatsSync)

    /// Replace the rendered view with the merged cross-device totals.
    func applyMerged(today: DailyInputStats, history: [String: DailyInputStats]) {
        lock.lock()
        self.today = today
        self.history = history
        lock.unlock()
        objectWillChange.send()
        onUpdate?()
    }

    // MARK: - History lookup

    func stats(for date: Date) -> DailyInputStats {
        lock.lock(); defer { lock.unlock() }
        let key = dateFormatter.string(from: date)
        return history[key] ?? DailyInputStats(date: date)
    }

    func historyKeys(days: Int = 30) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = history.keys.sorted()
        return Array(all.suffix(days))
    }

    // MARK: - Day rollover

    private func ensureCurrentDay() {
        lock.lock(); defer { lock.unlock() }
        ensureCurrentDayLocked()
    }

    private func ensureCurrentDayLocked() {
        let now = Date()
        if !Calendar.current.isDate(localToday.date, inSameDayAs: now) {
            archiveTodayLocked()
            localToday = DailyInputStats(date: now)
            today = localToday
        }
    }

    private func archiveTodayLocked() {
        let key = dateFormatter.string(from: localToday.date)
        localHistory[key] = localToday
        // Keep the rendered history in sync until the next cross-device pull.
        history[key] = (history[key] ?? DailyInputStats(date: localToday.date)) + localToday
        trimHistoryLocked(&localHistory)
        trimHistoryLocked(&history)
    }

    /// Drop all but the most recent `maxHistoryDays` days (date keys sort).
    private func trimHistoryLocked(_ dict: inout [String: DailyInputStats]) {
        let keys = dict.keys.sorted()
        guard keys.count > Self.maxHistoryDays else { return }
        for key in keys.prefix(keys.count - Self.maxHistoryDays) { dict[key] = nil }
    }

    private func setupMidnightReset() {
        scheduleNextMidnightReset()
    }

    private func scheduleNextMidnightReset() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        let now = Date()
        guard let next = calendar.nextDate(after: now,
                                            matching: DateComponents(hour: 0, minute: 0, second: 0),
                                            matchingPolicy: .nextTime) else { return }
        midnightTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performMidnightReset() }
        }
        if let timer = midnightTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func performMidnightReset() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if !Calendar.current.isDate(localToday.date, inSameDayAs: now) {
            archiveTodayLocked()
            localToday = DailyInputStats(date: now)
            today = localToday
            scheduleSave()
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
        scheduleNextMidnightReset()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            // Timer closures are not inferred as MainActor; hop explicitly.
            Task { @MainActor [weak self] in self?.save() }
        }
    }

    private func save() {
        lock.lock()
        let snapshot = localToday
        let key = dateFormatter.string(from: localToday.date)
        var hist = localHistory
        hist[key] = snapshot
        let histSnapshot = hist
        lock.unlock()

        if let data = try? JSONEncoder().encode(snapshot) {
            userDefaults.set(data, forKey: todayKey)
        }
        if let data = try? JSONEncoder().encode(histSnapshot) {
            userDefaults.set(data, forKey: historyKey)
        }
    }

    private func loadToday() -> DailyInputStats? {
        guard let data = userDefaults.data(forKey: todayKey),
              let stats = try? JSONDecoder().decode(DailyInputStats.self, from: data) else { return nil }
        return stats
    }

    private func loadHistory() -> [String: DailyInputStats] {
        guard let data = userDefaults.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([String: DailyInputStats].self, from: data) else { return [:] }
        return stored
    }
}
