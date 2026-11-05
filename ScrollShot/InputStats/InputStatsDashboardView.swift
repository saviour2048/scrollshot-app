import SwiftUI

/// Dashboard popover for input statistics.
///
/// The body reads the store once and hands plain values to the section views
/// below, so the per-keystroke `objectWillChange` re-renders don't route
/// store access through every section.
struct InputStatsDashboardView: View {
    @ObservedObject private var store = InputStatsStore.shared

    @State private var historyDays: HistoryRange = .last7
    @State private var metric: HistoryMetric = .keys

    enum HistoryRange: String, CaseIterable, Identifiable {
        case last7 = "Last 7 Days"
        case last30 = "Last 30 Days"
        var id: String { rawValue }
    }

    enum HistoryMetric: String, CaseIterable, Identifiable {
        case keys = "Keys"
        case clicks = "Clicks"
        case movement = "Movement"
        case scroll = "Scroll"
        var id: String { rawValue }
    }

    var body: some View {
        let today = store.today
        return VStack(spacing: 0) {
            Text(L("inputStats.title"))
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    TodayGrid(stats: today)
                    Divider()
                    KeyBreakdown(items: today.topKeys(limit: 15))
                    Divider()
                    HistorySection(historyDays: $historyDays, metric: $metric, days: historySeries())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            HStack {
                Toggle(L("inputStats.openAtLogin"), isOn: .constant(false)) // placeholder
                    .disabled(true)
                    .opacity(0)
                Spacer()
                Button(L("inputStats.resetToday")) { store.resetToday() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                Button(L("button.done")) { closePopover() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
        }
        .frame(width: 340, height: 460)
    }

    /// Last-N-days series (oldest → newest) matching the current picker range.
    /// Read from the store here so the section views never touch it.
    private func historySeries() -> [DailyInputStats] {
        let days = historyDays == .last7 ? 7 : 30
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: -(days - 1 - offset), to: today)!
            return store.stats(for: date)
        }
    }

    private func closePopover() {
        // The popover is transient and closes automatically on outside clicks;
        // this button is mainly for keyboard accessibility.
        NSApp.keyWindow?.performClose(nil)
    }
}

// MARK: - Sections (value-typed; they never touch InputStatsStore)

private struct TodayGrid: View {
    let stats: DailyInputStats

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                statCard(title: L("inputStats.keyPresses"), value: InputStatsFormat.number(stats.keyPresses), icon: "keyboard")
                statCard(title: L("inputStats.leftClicks"), value: InputStatsFormat.number(stats.leftClicks), icon: "hand.tap")
            }
            HStack(spacing: 12) {
                statCard(title: L("inputStats.rightClicks"), value: InputStatsFormat.number(stats.rightClicks), icon: "hand.tap.fill")
                statCard(title: L("inputStats.mouseDistance"), value: InputStatsFormat.mouseDistance(stats.mouseDistance), icon: "arrow.left.and.right")
            }
            HStack(spacing: 12) {
                statCard(title: L("inputStats.scrollDistance"), value: InputStatsFormat.scrollDistance(stats.scrollDistance), icon: "arrow.up.and.down")
                statCard(title: L("inputStats.totalClicks"), value: InputStatsFormat.number(stats.totalClicks), icon: "computermouse")
            }
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct KeyBreakdown: View {
    let items: [(key: String, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("inputStats.keyBreakdown"))
                .font(.system(size: 13, weight: .semibold))

            if items.isEmpty {
                Text(L("inputStats.noKeys"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(items, id: \.key) { item in
                        HStack {
                            Text(item.key)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(item.count)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

private struct HistorySection: View {
    @Binding var historyDays: InputStatsDashboardView.HistoryRange
    @Binding var metric: InputStatsDashboardView.HistoryMetric
    /// Last N days, oldest → newest, clipped to the current picker range.
    let days: [DailyInputStats]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("inputStats.history"))
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $historyDays) {
                Text(L("inputStats.last7Days")).tag(InputStatsDashboardView.HistoryRange.last7)
                Text(L("inputStats.last30Days")).tag(InputStatsDashboardView.HistoryRange.last30)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Picker("", selection: $metric) {
                Text(L("inputStats.keys")).tag(InputStatsDashboardView.HistoryMetric.keys)
                Text(L("inputStats.clicks")).tag(InputStatsDashboardView.HistoryMetric.clicks)
                Text(L("inputStats.movement")).tag(InputStatsDashboardView.HistoryMetric.movement)
                Text(L("inputStats.scroll")).tag(InputStatsDashboardView.HistoryMetric.scroll)
            }
            .pickerStyle(.segmented)
            // Fixed width: a flexible segmented picker makes the outer stack
            // re-run full size negotiation on every re-render.
            .frame(width: 280)

            barChart
        }
    }

    private var barChart: some View {
        let values = days.map { stats -> Double in
            switch metric {
            case .keys:     return Double(stats.keyPresses)
            case .clicks:   return Double(stats.totalClicks)
            case .movement: return stats.mouseDistance
            case .scroll:   return stats.scrollDistance
            }
        }
        let maxValue = values.max() ?? 0

        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, stats in
                    let height: CGFloat = maxValue > 0 ? CGFloat(values[index] / maxValue) * 80 : 0
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(4, 280 / CGFloat(days.count) - 4), height: max(height, 2))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        Text(Self.dayLabel(for: stats.date))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 100)

            Text(String(format: L("inputStats.total"), formatTotal(values.reduce(0, +))))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    /// Cached: rebuilding a DateFormatter re-opens its ICU format on every
    /// call, which showed up in the profiler on this hot path.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    private static func dayLabel(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func formatTotal(_ value: Double) -> String {
        switch metric {
        case .keys, .clicks:
            return InputStatsFormat.number(Int(value))
        case .movement:
            return InputStatsFormat.mouseDistance(value)
        case .scroll:
            return InputStatsFormat.scrollDistance(value)
        }
    }
}
