import Foundation

// The bundle used for all localized strings in WhatCableCore.
// Defaults to the module bundle (system language). Call setCoreLocale(_:)
// to switch to a specific lproj bundle for live language switching.
//
// Access goes through an NSLock so the live language switch (written on the
// main actor from AppSettings) can't race a concurrent read from a background
// context (the CLI and the snapshot formatters read these strings off-main).
// NSLock is plain Foundation, keeping WhatCableCore import-clean (no Apple-only
// `os` lock). Reads stay synchronous, so every
// `String(localized:bundle: _coreLocalizedBundle)` call site is unchanged.
private let _coreBundleLock = NSLock()
// SCROLLSHOT PATCH: vendored into the ScrollShot app target (no SPM module
// bundle), so all lookups go to the app main bundle. The WhatCable strings
// were merged into the app's own *.lproj/Localizable.strings.
private nonisolated(unsafe) var _coreBundleStorage: Bundle = .main

public var _coreLocalizedBundle: Bundle {
    _coreBundleLock.lock()
    defer { _coreBundleLock.unlock() }
    return _coreBundleStorage
}

// SCROLLSHOT PATCH: no-op. ScrollShot has no per-module live language
// switching; the signature is kept so upstream call sites stay source-compatible.
public func setCoreLocale(_ identifier: String) {
    _ = identifier
}
