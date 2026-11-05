import AppKit

/// A lightweight index of installed apps for the launcher. Enumerates the usual
/// app folders (incl. one level deep, e.g. /Applications/Setapp). Names only;
/// icons are loaded lazily per row by NSWorkspace.
@MainActor
final class AppIndex {
    static let shared = AppIndex()

    struct Entry: Identifiable {
        let id: String       // path
        let name: String     // localized display name ("微信", "Wechat Devtools")
        let searchBlob: String // lowercased display + folder name, for matching
        let url: URL
    }

    private(set) var apps: [Entry] = []
    private var built = false
    /// Modification dates of every folder scanned by the last build. Installing
    /// or deleting an app bumps its folder's mtime, and comparing these stamps
    /// is how a long-running ScrollShot notices. The index used to be built once
    /// at launch and never again, so apps installed later (user-reported: WeCom
    /// installed at 16:12, searched as "wecom" at 16:15) stayed invisible until
    /// ScrollShot was relaunched — and deleted apps stayed listed as ghosts.
    private var stamps: [String: Date] = [:]

    private let roots: [String]

    nonisolated static let defaultRoots = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        // Safari & co. live in the cryptex; the /Applications entry is a
        // synthetic firmlink that directory enumeration does NOT return
        // (why "safa" found nothing).
        "/System/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    init(roots: [String] = AppIndex.defaultRoots) {
        self.roots = roots
    }

    /// Cheap enough to call on every launcher open and every keystroke: a few
    /// stat calls when nothing changed, a full rebuild when something did.
    func buildIfNeeded() {
        guard built else { rebuild(); return }
        if hasFolderChanged() { rebuild() }
    }

    func rebuild() {
        built = true
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [Entry] = []
        var newStamps: [String: Date] = [:]

        func stamp(_ url: URL) {
            if let date = AppIndex.modificationDate(of: url.path) { newStamps[url.path] = date }
        }

        func add(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let folderName = url.deletingPathExtension().lastPathComponent
            // The localized display name is what the user actually sees in
            // Finder/Spotlight — e.g. WeChat.app shows as 微信 and
            // wechatwebdevtools.app as "Wechat Devtools". Folder names alone
            // made those unfindable (user-reported).
            var display = fm.displayName(atPath: url.path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            guard seen.insert(folderName.lowercased()).inserted else { return }
            // `displayName` follows the *process* language. ScrollShot runs in
            // zh-Hans, so 企业微信.app reports 企业微信 and WeChat.app reports
            // 微信 — searching the English brand ("WeCom", "WeChat") found
            // nothing even though the index had the app (user-reported
            // 2026-11-02). Index the other localizations' names too.
            var names = [display, folderName]
            names.append(contentsOf: AppIndex.localizedNames(for: url))
            let blob = Set(names.map { $0.lowercased() }).sorted().joined(separator: " ")
            found.append(Entry(id: url.path, name: display,
                               searchBlob: blob,
                               url: url))
        }

        for root in roots {
            let base = URL(fileURLWithPath: root)
            guard let items = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            stamp(base)
            for url in items {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level deep for wrappers like /Applications/Setapp.
                    // Stamp the wrapper too — an install inside it does not
                    // touch /Applications' own mtime.
                    stamp(url)
                    if let sub = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) {
                        sub.forEach(add)
                    }
                }
            }
        }
        stamps = newStamps
        apps = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True when a folder scanned at the last build was modified since (app
    /// installed / removed / renamed, or a wrapper like Setapp gained a child).
    private func hasFolderChanged() -> Bool {
        guard !stamps.isEmpty else { return true }
        for (path, date) in stamps where AppIndex.modificationDate(of: path) != date {
            return true
        }
        return false
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Alternate-language names from the app's `*.lproj/InfoPlist.strings`
    /// (en / Base / zh-Hans / zh-Hant). Only 企业微信.app and WeChat.app and a
    /// handful of others ship these; the scan costs ~110 ms during a rebuild.
    private static func localizedNames(for url: URL) -> [String] {
        let resources = url.appendingPathComponent("Contents/Resources")
        var names: [String] = []
        for lang in ["en", "Base", "zh-Hans", "zh-Hant"] {
            let strings = resources.appendingPathComponent("\(lang).lproj/InfoPlist.strings")
            guard let dict = NSDictionary(contentsOf: strings) else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = dict[key] as? String, !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    /// Tokenized match against display + folder name + localized aliases
    /// ("wechat dev" hits "Wechat Devtools" even though the folder is
    /// wechatwebdevtools). Every token must appear; prefix hits rank first,
    /// then shorter names.
    func search(_ query: String, limit: Int = 8) -> [Entry] {
        buildIfNeeded()
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let matches = apps.filter { e in tokens.allSatisfy { e.searchBlob.contains($0) } }
        let first = tokens[0]
        return Array(matches.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(first), bp = b.name.lowercased().hasPrefix(first)
            if ap != bp { return ap }
            return a.name.count < b.name.count
        }.prefix(limit))
    }
}
