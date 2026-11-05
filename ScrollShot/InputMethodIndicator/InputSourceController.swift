import Foundation
import Carbon

/// A small wrapper around macOS Text Input Services (Carbon.framework) for
/// enumerating, reading, and selecting keyboard input sources.
@MainActor
enum InputSourceController {

    /// A lightweight representation of an input source for UI and rules.
    struct InputSource: Identifiable, Equatable {
        var id: String { sourceID }
        let sourceID: String
        let localizedName: String
        let source: TISInputSource

        static func == (lhs: InputSource, rhs: InputSource) -> Bool {
            lhs.sourceID == rhs.sourceID
        }
    }

    /// All enabled keyboard input sources visible to the current user.
    static var enabledInputSources: [InputSource] {
        // Passing an empty dictionary returns all enabled input sources.
        guard let list = TISCreateInputSourceList([:] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }

        return list.compactMap { source in
            guard let sourceID = stringProperty(of: source, key: kTISPropertyInputSourceID),
                  let name = stringProperty(of: source, key: kTISPropertyLocalizedName)
            else { return nil }
            return InputSource(sourceID: sourceID, localizedName: name, source: source)
        }
    }

    /// The currently selected keyboard input source ID.
    static var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(of: source, key: kTISPropertyInputSourceID)
    }

    /// Whether the current keyboard input source is an IME "input mode"
    /// (Pinyin, Wubi, Japanese…), as opposed to a plain keyboard layout (ABC).
    static var currentIsInputMode: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String)
    }

    /// The currently selected keyboard input source display name.
    static var currentInputSourceName: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(of: source, key: kTISPropertyLocalizedName)
    }

    /// Select a keyboard input source by its stable reverse-DNS ID.
    /// - Returns: `true` if the call succeeded; the system may still ignore it
    ///   if an IME composition window is active.
    @discardableResult
    static func selectInputSource(id: String) -> Bool {
        let properties = [
            kTISPropertyInputSourceID as String: id,
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource
        ] as [String: Any]

        guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let target = list.first
        else {
            Diag.inputSource.warning("Could not find input source with id \(id, privacy: .public)")
            return false
        }

        let status = TISSelectInputSource(target)
        if status == noErr {
            Diag.inputSource.info("Switched to input source \(id, privacy: .public)")
        } else {
            Diag.inputSource.warning("TISSelectInputSource failed with status \(status, privacy: .public)")
        }
        return status == noErr
    }

    // MARK: - Helpers

    private static func stringProperty(of source: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

// MARK: - Diagnostics helpers

extension InputSourceController.InputSource {
    var displayTitle: String {
        localizedName.isEmpty ? sourceID : "\(localizedName) (\(sourceID))"
    }
}
