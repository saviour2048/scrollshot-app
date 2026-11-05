import Foundation
import AppKit
import os
import Combine

/// A display that can be controlled via the embedded `m1ddc` binary.
struct M1DDCDisplay: Identifiable, Hashable {
    let index: Int
    let name: String
    let uuid: String
    let displayID: CGDirectDisplayID?
    var id: String { uuid }
}

/// Controller for external-monitor brightness via the embedded `m1ddc` tool.
///
/// Process calls run on a background queue so the UI stays responsive; published
/// properties are updated on the main actor.
final class M1DDCBrightnessController: ObservableObject {
    static let shared = M1DDCBrightnessController()

    @Published var displays: [M1DDCDisplay] = []
    @Published var errorMessage: String?
    @Published var brightnessValues: [String: Int] = [:]

    /// Whether brightness keys should control external displays.
    @Published var interceptBrightnessKeys: Bool {
        didSet {
            UserDefaults.standard.set(interceptBrightnessKeys, forKey: Self.interceptKeysKey)
            BrightnessKeyInterceptor.shared.isEnabled = interceptBrightnessKeys
        }
    }

    /// Whether the brightness status-item icon appears in the menu bar.
    @Published var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
        }
    }

    private static let interceptKeysKey = "brightness.interceptBrightnessKeys"
    private static let showMenuBarIconKey = "brightness.showMenuBarIcon"
    private static let stepSize = 5

    /// Master switch for the whole brightness feature (`brightness.enabled`,
    /// default ON). Read directly from defaults — this class is not MainActor.
    static var featureEnabled: Bool {
        UserDefaults.standard.object(forKey: "brightness.enabled") as? Bool ?? true
    }

    private let queue = DispatchQueue(label: "com.scrollshot.m1ddc", qos: .userInitiated)

    private init() {
        let storedIntercept = UserDefaults.standard.object(forKey: Self.interceptKeysKey) as? Bool
        _interceptBrightnessKeys = Published(initialValue: storedIntercept ?? false)
        BrightnessKeyInterceptor.shared.isEnabled = (storedIntercept ?? false) && Self.featureEnabled

        let storedShowIcon = UserDefaults.standard.object(forKey: Self.showMenuBarIconKey) as? Bool
        _showMenuBarIcon = Published(initialValue: storedShowIcon ?? true)
    }

    var executableURL: URL? {
        Bundle.main.url(forResource: "m1ddc", withExtension: nil)
    }

    // MARK: - Discovery

    func refreshDisplays(completion: (() -> Void)? = nil) {
        // Feature off: never spawn the m1ddc subprocess.
        guard Self.featureEnabled else { completion?(); return }
        queue.async { [weak self] in
            self?.run(args: ["display", "list", "detailed"]) { output in
                Diag.brightness.debug("m1ddc list output: \(output, privacy: .public)")
                let parsed = Self.parseDisplayListDetailed(output)
                DispatchQueue.main.async {
                    Diag.brightness.debug("parsed displays: \(parsed.map { "\($0.name) id=\($0.displayID ?? 0)" }, privacy: .public)")
                    self?.displays = parsed
                    self?.errorMessage = nil
                    self?.refreshAllBrightnessValues()
                    completion?()
                }
            } onError: { err in
                DispatchQueue.main.async {
                    self?.errorMessage = err
                    completion?()
                }
            }
        }
    }

    // MARK: - Read

    func readBrightness(display: M1DDCDisplay, completion: @escaping (Int, Int) -> Void) {
        queue.async { [weak self] in
            self?.run(args: ["display", "\(display.index)", "get", "luminance"]) { currentOutput in
                let current = Self.parseNumericValue(currentOutput) ?? 0
                self?.run(args: ["display", "\(display.index)", "max", "luminance"]) { maxOutput in
                    let maxValue = Self.parseNumericValue(maxOutput) ?? 100
                    DispatchQueue.main.async { completion(current, maxValue) }
                } onError: { _ in
                    DispatchQueue.main.async { completion(current, 100) }
                }
            } onError: { _ in
                DispatchQueue.main.async { completion(0, 100) }
            }
        }
    }

    func refreshAllBrightnessValues() {
        for display in displays {
            readBrightness(display: display) { [weak self] current, maxValue in
                guard let self, maxValue > 0 else { return }
                self.brightnessValues[display.uuid] = min(100, Swift.max(0, Int(Double(current) / Double(maxValue) * 100.0)))
            }
        }
    }

    // MARK: - Write

    func writeBrightness(display: M1DDCDisplay, value: Int) {
        let clamped = max(0, min(100, value))
        queue.async { [weak self] in
            self?.run(args: ["display", "\(display.index)", "set", "luminance", "\(clamped)"]) { _ in
                DispatchQueue.main.async {
                    self?.brightnessValues[display.uuid] = clamped
                    self?.errorMessage = nil
                    // DDC succeeded; make sure any prior gamma dimming is cleared.
                    if let displayID = display.displayID {
                        GammaDimmer.shared.reset(displayID: displayID)
                    }
                }
            } onError: { err in
                DispatchQueue.main.async {
                    self?.errorMessage = err
                    // Fallback: software dim the display via gamma.
                    if let displayID = display.displayID {
                        GammaDimmer.shared.setDim(displayID: displayID, level: CGFloat(clamped) / 100.0)
                    }
                }
            }
        }
    }

    /// Adjust all discovered external displays by `delta` percent points.
    func adjustBrightness(delta: Int) {
        queue.async { [weak self] in
            guard let self, !self.displays.isEmpty else { return }
            for display in self.displays {
                self.run(args: ["display", "\(display.index)", "chg", "luminance", "\(delta)"]) { output in
                    if let current = Self.parseNumericValue(output) {
                        DispatchQueue.main.async {
                            self.brightnessValues[display.uuid] = current
                            self.errorMessage = nil
                        }
                    }
                } onError: { err in
                    DispatchQueue.main.async { self.errorMessage = err }
                }
            }
        }
    }

    func brightnessUp() { adjustBrightness(delta: Self.stepSize) }
    func brightnessDown() { adjustBrightness(delta: -Self.stepSize) }

    // MARK: - Process wrapper

    private func run(args: [String], onSuccess: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard let executableURL else {
            onError("m1ddc not found in app bundle")
            return
        }
        let task = Process()
        task.executableURL = executableURL
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            if task.terminationStatus == 0 {
                onSuccess(output)
            } else {
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
                onError(errText)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    private static func parseDisplayListDetailed(_ output: String) -> [M1DDCDisplay] {
        var displays: [M1DDCDisplay] = []
        let lines = output.components(separatedBy: .newlines)
        var currentIndex: Int?
        var currentName: String?
        var currentUUID: String?
        var currentDisplayID: CGDirectDisplayID?

        for line in lines {
            if let match = line.range(of: #"\[(\d+)\]\s+(.+?)\s+\(([A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12})\)"#, options: .regularExpression) {
                // Flush previous display.
                if let index = currentIndex, let name = currentName, let uuid = currentUUID {
                    displays.append(M1DDCDisplay(index: index, name: name, uuid: uuid, displayID: currentDisplayID))
                }
                let matched = String(line[match])
                let innerPattern = #"\[(\d+)\]\s+(.+?)\s+\(([A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12})\)"#
                guard let innerRegex = try? NSRegularExpression(pattern: innerPattern, options: []),
                      let innerMatch = innerRegex.firstMatch(in: matched, options: [], range: NSRange(location: 0, length: matched.utf16.count)),
                      let indexRange = Range(innerMatch.range(at: 1), in: matched),
                      let nameRange = Range(innerMatch.range(at: 2), in: matched),
                      let uuidRange = Range(innerMatch.range(at: 3), in: matched),
                      let index = Int(matched[indexRange]) else {
                    currentIndex = nil; currentName = nil; currentUUID = nil; currentDisplayID = nil
                    continue
                }
                currentIndex = index
                currentName = String(matched[nameRange]).trimmingCharacters(in: .whitespaces)
                currentUUID = String(matched[uuidRange])
                currentDisplayID = nil
            } else if let idRange = line.range(of: #"Display ID:\s*(\d+)"#, options: .regularExpression) {
                let matched = String(line[idRange])
                let idPattern = #"Display ID:\s*(\d+)"#
                guard let idRegex = try? NSRegularExpression(pattern: idPattern, options: []),
                      let idMatch = idRegex.firstMatch(in: matched, options: [], range: NSRange(location: 0, length: matched.utf16.count)),
                      let numRange = Range(idMatch.range(at: 1), in: matched),
                      let id = UInt32(matched[numRange]) else { continue }
                currentDisplayID = CGDirectDisplayID(id)
            }
        }

        // Flush the last display.
        if let index = currentIndex, let name = currentName, let uuid = currentUUID {
            displays.append(M1DDCDisplay(index: index, name: name, uuid: uuid, displayID: currentDisplayID))
        }

        return displays
    }

    private static func parseNumericValue(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
