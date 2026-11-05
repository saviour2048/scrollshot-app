import AppKit
import SwiftUI

/// 「键盘连击检测」诊断窗口。打开即开始监听,关闭即停止——不是常驻功能,
/// 不进 FeatureSwitches。
@MainActor
final class KeyChatterWindowController: NSObject, NSWindowDelegate {
    static let shared = KeyChatterWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = L("chatter.title")
            w.contentViewController = NSHostingController(rootView: KeyChatterView())
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        KeyChatterMonitor.shared.start()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in KeyChatterMonitor.shared.stop() }
    }
}

private struct KeyChatterView: View {
    @ObservedObject private var monitor = KeyChatterMonitor.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            verdict
            Text(L("chatter.howto"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statsTable
            bounceLog
        }
        .padding(16)
        .frame(minWidth: 508, minHeight: 420)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(monitor.running ? L("chatter.stop") : L("chatter.start")) {
                monitor.running ? monitor.stop() : monitor.start()
            }
            Button(L("chatter.reset")) { monitor.reset() }
                .disabled(monitor.totalPresses == 0)
            Spacer()
            Text(String(format: L("chatter.threshold"), Int(monitor.thresholdMs)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Slider(value: $monitor.thresholdMs, in: 10...100, step: 5)
                .frame(width: 120)
        }
    }

    private var verdict: some View {
        let suspected = monitor.suspectedKeyNames
        return Group {
            if !suspected.isEmpty {
                Label(String(format: L("chatter.verdictBad"), suspected.joined(separator: "、")),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            } else if monitor.totalPresses >= 300 {
                Label(L("chatter.verdictGood"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Label(String(format: L("chatter.verdictCollecting"), monitor.totalPresses),
                      systemImage: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var statsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("chatter.col.key")).frame(width: 80, alignment: .leading)
                Text(L("chatter.col.presses")).frame(width: 70, alignment: .trailing)
                Text(L("chatter.col.bounces")).frame(width: 70, alignment: .trailing)
                Text(L("chatter.col.lastGap")).frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            List(monitor.rows) { row in
                HStack {
                    Text(row.name).frame(width: 80, alignment: .leading)
                    Text("\(row.presses)").frame(width: 70, alignment: .trailing)
                    Text("\(row.bounces)")
                        .foregroundColor(row.bounces > 0 ? .red : .primary)
                        .frame(width: 70, alignment: .trailing)
                    Text(row.lastGapMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        .frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
            }
            .frame(minHeight: 120)
        }
    }

    private var bounceLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("chatter.recentBounces"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            List(monitor.recentBounces.reversed()) { entry in
                Text("\(Self.timeFormatter.string(from: entry.at))  \(entry.key)  +\(String(format: "%.1f", entry.gapMs))ms")
                    .font(.system(size: 11, design: .monospaced))
            }
            .frame(minHeight: 80)
        }
    }
}
