import AppKit

/// The menu-bar running cat.
///
/// Frames are the official open-source RunCat sprites from
/// Kyome22/menubar_runcat (Apache License 2.0 — the license text ships in the
/// app bundle as LICENSE-menubar_runcat.txt). We tint them coral at load so the
/// meter reads as "the Claude tool" and stays distinguishable from a real
/// (monochrome) RunCat running next to it.
enum RunningCat {
    static let frameCount = 5

    /// Load the five stride frames, tinted.
    static func loadFrames(tint: NSColor) -> [NSImage] {
        (0..<frameCount).compactMap { i in
            guard let url = Bundle.main.url(forResource: "cat_\(i)", withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            return tinted(img, tint)
        }
    }

    /// Recolor every opaque pixel (on a transparent canvas, so only the cat).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Whole-machine CPU usage (0–100), from `host_processor_info` tick deltas —
/// the same source RunCat uses to pace its cat.
final class CPUSampler {
    private var prev: [(busy: Double, total: Double)] = []

    func usagePercent() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        // Per-CPU tick counters: [user, system, idle, nice] (CPU_STATE_MAX = 4).
        var ticks: [(busy: Double, total: Double)] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * 4
            let user = Double(UInt32(bitPattern: info[base + 0]))
            let sys  = Double(UInt32(bitPattern: info[base + 1]))
            let idle = Double(UInt32(bitPattern: info[base + 2]))
            let nice = Double(UInt32(bitPattern: info[base + 3]))
            ticks.append((busy: user + sys + nice, total: user + sys + nice + idle))
        }

        defer { prev = ticks }
        guard prev.count == ticks.count else { return 0 }
        var busy = 0.0, total = 0.0
        for (i, t) in ticks.enumerated() {
            busy += t.busy - prev[i].busy
            total += t.total - prev[i].total
        }
        return total > 0 ? min(100, max(0, busy / total * 100)) : 0
    }
}
