import KeyboardShortcuts

/// Global keyboard-shortcut identifiers. The user can re-record these in
/// Preferences; the chosen key is persisted by the KeyboardShortcuts library.
extension KeyboardShortcuts.Name {
    /// Trigger the Flameshot-style frozen capture overlay.
    static let captureRegion = Self(
        "captureRegion",
        default: .init(.a, modifiers: [.control, .option])
    )

    /// Open the clipboard-history search window (Raycast-style, ⌥⌘C).
    static let clipboardHistory = Self(
        "clipboardHistory",
        default: .init(.c, modifiers: [.command, .option])
    )

    /// Open the launcher / root search (Raycast-style, ⌥Space).
    static let launcher = Self(
        "launcher",
        default: .init(.space, modifiers: [.option])
    )

    /// Open the AI chat window directly (skip the launcher).
    static let aiChat = Self(
        "aiChat",
        default: .init(.l, modifiers: [.command, .option])
    )

    /// Toggle the drag-and-drop shelf (Yoink-style, ⌥⌘Y).
    static let shelf = Self(
        "shelf",
        default: .init(.y, modifiers: [.command, .option])
    )
}
