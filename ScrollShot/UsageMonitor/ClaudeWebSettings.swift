import Foundation

/// Persistent configuration for the claude.ai web cookie source.
///
/// The session key is stored in the keychain, never in UserDefaults, and never synced.
enum ClaudeWebSettings {
    static var sessionKey: String {
        get { KeychainStore.load(account: "claude.web.sessionKey") ?? "" }
        set { KeychainStore.save(newValue, account: "claude.web.sessionKey") }
    }

    static var isConfigured: Bool { !sessionKey.isEmpty }
}
