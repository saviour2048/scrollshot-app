import CoreGraphics

/// Software dimming fallback for displays that don't respond to DDC/CI.
///
/// Uses `CGSetDisplayTransferByTable` to scale the gamma ramp. This affects
/// the whole display, so it is only used as a fallback when `m1ddc` fails.
final class GammaDimmer {
    static let shared = GammaDimmer()
    private init() {}

    private let tableSize = 256
    private var originalTables: [CGDirectDisplayID: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])] = [:]

    /// Dim a specific display to `level` (0...1, where 1 is normal brightness).
    func setDim(displayID: CGDirectDisplayID, level: CGFloat) {
        guard level >= 0, level <= 1 else { return }

        let samples = tableSize
        var red = [CGGammaValue](repeating: 0, count: samples)
        var green = [CGGammaValue](repeating: 0, count: samples)
        var blue = [CGGammaValue](repeating: 0, count: samples)
        var sampleCount: UInt32 = 0

        // Capture the original gamma table once, then scale from it every time.
        if originalTables[displayID] == nil {
            let result = CGGetDisplayTransferByTable(displayID, UInt32(samples), &red, &green, &blue, &sampleCount)
            guard result == .success else { return }
            originalTables[displayID] = (red, green, blue)
        }

        guard let original = originalTables[displayID] else { return }
        let factor = CGGammaValue(level)

        var scaledRed = [CGGammaValue](repeating: 0, count: samples)
        var scaledGreen = [CGGammaValue](repeating: 0, count: samples)
        var scaledBlue = [CGGammaValue](repeating: 0, count: samples)

        for i in 0..<samples {
            scaledRed[i] = max(0, min(1, original.red[i] * factor))
            scaledGreen[i] = max(0, min(1, original.green[i] * factor))
            scaledBlue[i] = max(0, min(1, original.blue[i] * factor))
        }

        CGSetDisplayTransferByTable(displayID, UInt32(samples), scaledRed, scaledGreen, scaledBlue)
    }

    /// Restore the original gamma table for a display.
    func reset(displayID: CGDirectDisplayID) {
        guard let original = originalTables.removeValue(forKey: displayID) else { return }
        CGSetDisplayTransferByTable(displayID, UInt32(original.red.count), original.red, original.green, original.blue)
    }

    /// Dim all non-built-in displays by the given level.
    func setDimAllExternal(level: CGFloat) {
        let active = getActiveDisplayIDs()
        for displayID in active where CGDisplayIsBuiltin(displayID) == 0 {
            setDim(displayID: displayID, level: level)
        }
    }

    /// Reset gamma for all displays we have modified.
    func resetAll() {
        for displayID in originalTables.keys {
            reset(displayID: displayID)
        }
    }

    private func getActiveDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else { return [] }
        return ids
    }
}
