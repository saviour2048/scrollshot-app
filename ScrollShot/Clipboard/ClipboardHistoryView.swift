import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Posted by the window controllers when a picker (re)opens → focus its
    /// search field (windows are reused, so onAppear alone doesn't re-fire).
    static let scrollShotPickerFocus = Notification.Name("scrollShotPickerFocus")
}

enum ClipboardTypeFilter: String, CaseIterable {
    case all, text, image, file
    var label: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .image: "图片"
        case .file: "文件"
        }
    }
    func matches(_ k: ClipboardItem.Kind) -> Bool { self == .all || rawValue == k.rawValue }
}

/// Shared selection/filter state so the AppKit key monitor (which handles ↑↓ and
/// modifier-held J/K, even while ⌥⌘ stays down) and the SwiftUI view agree.
///
/// Filtering is performed off the main thread and debounced so that fast typing
/// does not block the UI. Results are cached in `filteredItems`.
@MainActor
final class ClipboardPickerModel: ObservableObject {
    @Published var query = ""
    @Published var typeFilter: ClipboardTypeFilter = .all
    @Published var selected = 0
    @Published private(set) var filteredItems: [ClipboardItem] = []
    /// (item, pasteAsPlainText)
    var onChoose: (ClipboardItem, Bool) -> Void = { _, _ in }

    private var cancellables = Set<AnyCancellable>()
    private let searchQueue = DispatchQueue(label: "com.scrollshot.clipboard-search", qos: .userInitiated)
    private let searchLock = NSLock()
    private var pendingSearch = 0

    init() {
        // Debounce typing: wait 100 ms after the last character before filtering.
        $query
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resetSelection()
                self?.updateFilter()
            }
            .store(in: &cancellables)

        $typeFilter
            .dropFirst()
            .sink { [weak self] _ in
                self?.resetSelection()
                self?.updateFilter()
            }
            .store(in: &cancellables)

        ClipboardStore.shared.$items
            .sink { [weak self] _ in self?.updateFilter() }
            .store(in: &cancellables)

        updateFilter()
    }

    private func updateFilter() {
        let query = self.query
        let typeFilter = self.typeFilter
        let items = ClipboardStore.shared.items

        searchLock.lock()
        pendingSearch += 1
        let token = pendingSearch
        searchLock.unlock()

        searchQueue.async { [weak self] in
            let result = ClipboardPickerModel.filter(items: items, query: query, typeFilter: typeFilter)
            DispatchQueue.main.async {
                guard let self else { return }
                self.searchLock.lock()
                let isLatest = token == self.pendingSearch
                self.searchLock.unlock()
                guard isLatest else { return }
                self.filteredItems = result
            }
        }
    }

    /// Stable, deterministic filter/ordering done entirely on a background queue.
    nonisolated static func filter(items: [ClipboardItem], query: String, typeFilter: ClipboardTypeFilter) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesQuery: (ClipboardItem) -> Bool = {
            trimmed.isEmpty || $0.searchText.localizedCaseInsensitiveContains(trimmed)
        }

        // Source array is already newest-first; split pinned/unpinned in one pass
        // instead of sorting, keeping this O(n).
        var pinned: [ClipboardItem] = []
        var others: [ClipboardItem] = []
        pinned.reserveCapacity(items.count / 4)
        others.reserveCapacity(items.count)

        for item in items where typeFilter.matches(item.kind) && matchesQuery(item) {
            if item.pinned {
                pinned.append(item)
            } else {
                others.append(item)
            }
        }
        return pinned + others
    }

    func move(_ delta: Int) {
        let f = filteredItems
        guard !f.isEmpty else { return }
        selected = min(max(0, selected + delta), f.count - 1)
    }
    func choose(plain: Bool = false) {
        let f = filteredItems
        if f.indices.contains(selected) { onChoose(f[selected], plain) }
    }
    func deleteSelected() {
        let f = filteredItems
        guard f.indices.contains(selected) else { return }
        ClipboardStore.shared.delete(f[selected])
        selected = min(selected, max(0, filteredItems.count - 1))
    }
    func pinSelected() {
        let f = filteredItems
        guard f.indices.contains(selected) else { return }
        ClipboardStore.shared.togglePin(f[selected])
    }
    func resetSelection() { selected = 0 }
}

/// Raycast-style clipboard picker: search + type filter on top, a selectable list
/// on the left (↑↓ or ⌥⌘-held J/K to move, ↵ to paste, double-click to paste),
/// and an info/preview panel on the right.
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardPickerModel
    let onClose: () -> Void

    @ObservedObject private var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索剪贴板历史…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($searchFocused)
                Picker("", selection: $model.typeFilter) {
                    ForEach(ClipboardTypeFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 92)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            HStack(spacing: 0) {
                listPane.frame(width: 320)
                Divider()
                infoPane.frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Text("↑↓/⌥⌘JK 选 · ↵ 粘贴 · ⌘↵ 纯文本 · ⌘P 置顶 · ⌘⌫ 删 · ⌘F 搜索 · esc 关")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                // Shows the model's live filter word — if this ever disagrees
                // with the search field, the window is rendering stale state.
                Text(model.query.isEmpty
                     ? "\(model.filteredItems.count) 条"
                     : "筛选「\(model.query)」· \(model.filteredItems.count) 条")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .scrollShotPickerFocus)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
        }
        .onExitCommand(perform: onClose)
    }

    private var listPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.filteredItems.isEmpty {
                        Text(store.items.isEmpty ? "还没有记录 —— 复制点东西" : "无匹配")
                            .font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 40)
                    }
                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { idx, item in
                        Row(item: item, selected: idx == model.selected)
                            // Identity by ELEMENT id. `.id(idx)` (index identity,
                            // for scrollTo) made the lazy container reuse rows
                            // with stale pre-filter content — the list showed
                            // images for a "cd" query while footer/preview were
                            // correct ("左边是假的", root-caused on real data).
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.onChoose(item, false) }
                            .onTapGesture { model.selected = idx }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selected) { s in
                let f = model.filteredItems
                guard f.indices.contains(s) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(f[s].id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private var infoPane: some View {
        let f = model.filteredItems
        if f.indices.contains(model.selected) {
            InfoPanel(item: f[model.selected])
        } else {
            VStack { Spacer(); Text("无内容").font(.system(size: 12)).foregroundColor(.secondary); Spacer() }
        }
    }
}

// MARK: - List row

private struct Row: View {
    let item: ClipboardItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview).lineLimit(1).font(.system(size: 13))
                    .foregroundColor(selected ? .white : .primary)
                Text(item.sourceApp ?? "").lineLimit(1).font(.system(size: 11))
                    .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9))
                    .foregroundColor(selected ? .white : .orange)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6).padding(.vertical, 1)
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .text: symbol("text.alignleft")
        case .file: symbol("doc")
        case .image:
            AsyncThumbnailImage(item: item, contentMode: .fit) { symbol("photo") }
                .id(item.id)
                .frame(width: 36, height: 36)
        }
    }
    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16))
            .foregroundColor(selected ? .white : .secondary)
            .frame(width: 36, height: 36)
    }
}

// MARK: - Right info / preview panel

private struct InfoPanel: View {
    let item: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview.frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                infoRow("类型", kindLabel)
                if let s = item.sourceApp, !s.isEmpty { infoRow("来源", s) }
                if item.kind == .text {
                    infoRow("字符", "\(item.charCount)")
                    infoRow("词数", "\(item.wordCount)")
                }
                if item.kind == .file { infoRow("文件数", "\((item.filePaths ?? []).count)") }
                infoRow("时间", Self.full.string(from: item.timestamp))
            }
            .padding(14)
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            // Large text can stall SwiftUI's layout engine for seconds.
            // Fall back to an AppKit text view which only renders the visible area.
            if text.count > Self.bigTextThreshold {
                BigTextPreview(text: text)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .image:
            ScrollView {
                AsyncThumbnailImage(item: item, contentMode: .fit) {
                    Text("图片").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        Text(path).font(.system(size: 12)).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static let bigTextThreshold = 1000

    private var kindLabel: String {
        switch item.kind {
        case .text: "文本"
        case .image: "图片"
        case .file: "文件"
        }
    }
    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundColor(.primary).lineLimit(1).truncationMode(.middle)
        }
    }
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hans"); f.dateFormat = "M月d日 HH:mm"; return f
    }()
}

// MARK: - Async thumbnail loading

/// SwiftUI view that asynchronously decodes a clipboard image thumbnail.
/// Uses `.task(id:)` so SwiftUI itself cancels the previous load when the item
/// changes; this avoids the manual lifecycle bugs that can leave a stale image.
struct AsyncThumbnailImage<Placeholder: View>: View {
    let item: ClipboardItem
    let contentMode: ContentMode
    @ViewBuilder let placeholder: Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: item.id) {
            // Clear immediately so a reused row never briefly shows the previous image.
            image = nil
            guard item.kind == .image else { return }
            image = await ClipboardStore.shared.thumbnail(for: item)
        }
    }
}

// MARK: - AppKit-backed large text preview

/// A read-only NSTextView wrapped for SwiftUI. Unlike SwiftUI's `Text`, it only
/// lays out and renders the currently visible portion, so selecting a clipboard
/// entry with thousands of characters no longer blocks the main thread for seconds.
private struct BigTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
