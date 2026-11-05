import AppKit

/// A built-in launcher command (ScrollShot's own actions, etc.).
struct LauncherCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let keywords: [String]
    let action: () -> Void
}

/// Root-search state for the launcher. Shared between the SwiftUI view and the
/// AppKit key monitor (which drives ↑↓ / ⌥⌘-held J/K navigation).
@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = ""
    @Published var selected = 0
    /// Non-nil while entering the argument for a selected quicklink.
    @Published var argumentMode: Quicklink?

    /// Called to close the window after an action runs.
    var onRun: () -> Void = {}

    private let commands: [LauncherCommand]
    init(commands: [LauncherCommand]) { self.commands = commands }

    enum ItemKind { case app(AppIndex.Entry), quicklink(Quicklink), command(LauncherCommand), calculator(String) }
    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let kind: ItemKind
    }

    var results: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Item] = []

        func addQuicklink(_ ql: Quicklink) {
            out.append(Item(id: "ql.\(ql.keyword)", title: ql.title,
                            subtitle: String(format: L("launcher.subtitle.search"), ql.keyword), kind: .quicklink(ql)))
        }
        func addCommand(_ c: LauncherCommand) {
            out.append(Item(id: "cmd.\(c.id)", title: c.title, subtitle: L("launcher.subtitle.command"), kind: .command(c)))
        }

        // Empty query: browse mode — own commands, then search shortcuts.
        guard !q.isEmpty else {
            commands.forEach(addCommand)
            Quicklinks.all.forEach(addQuicklink)
            return out
        }

        // Calculator: evaluate the raw query first; if it resolves, pin it to
        // the top so ↵ copies the result (Raycast-style).
        if let result = LauncherCalculator.evaluate(query) {
            out.append(Item(id: "calc.result", title: result,
                            subtitle: L("launcher.subtitle.calculator"), kind: .calculator(result)))
        }

        // With a query: APPS FIRST (launching apps is the primary use), then
        // search shortcuts, then commands. (Quicklinks-first made "safari" ↵
        // land in Bing argument mode — wrong.)
        for a in AppIndex.shared.search(q) {
            out.append(Item(id: "app.\(a.id)", title: a.name, subtitle: L("launcher.subtitle.app"), kind: .app(a)))
        }
        for ql in Quicklinks.all where ql.matches(q) { addQuicklink(ql) }
        for c in commands where c.title.localizedCaseInsensitiveContains(q)
            || c.keywords.contains(where: { $0.hasPrefix(q) }) {
            addCommand(c)
        }
        return out
    }

    // MARK: Navigation / actions

    func move(_ delta: Int) {
        guard argumentMode == nil else { return }
        let r = results
        guard !r.isEmpty else { return }
        selected = min(max(0, selected + delta), r.count - 1)
    }

    /// Enter / choose the selected item.
    func submit() {
        if let ql = argumentMode { runQuicklink(ql); return }
        let r = results
        guard r.indices.contains(selected) else { return }
        switch r[selected].kind {
        case .app(let a):
            NSWorkspace.shared.open(a.url)
            onRun()
        case .command(let c):
            onRun()
            c.action()
        case .quicklink(let ql):
            enterArgumentMode(ql)   // ask for the query next
        case .calculator(let result):
            copyToPasteboard(result)
            onRun()
        }
    }

    func choose(_ item: Item) {
        switch item.kind {
        case .app(let a): NSWorkspace.shared.open(a.url); onRun()
        case .command(let c): onRun(); c.action()
        case .quicklink(let ql): enterArgumentMode(ql)
        case .calculator(let result): copyToPasteboard(result); onRun()
        }
    }

    /// Esc handling. Returns true if it was consumed internally (leave window open).
    func escape() -> Bool {
        if argumentMode != nil { exitArgumentMode(); return true }
        return false
    }

    private func enterArgumentMode(_ ql: Quicklink) {
        argumentMode = ql
        query = ""
        selected = 0
    }
    func exitArgumentMode() {
        argumentMode = nil
        query = ""
        selected = 0
    }
    private func runQuicklink(_ ql: Quicklink) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let url = ql.url(for: q) else { return }
        NSWorkspace.shared.open(url)
        onRun()
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reset() {
        query = ""
        selected = 0
        argumentMode = nil
    }
}
