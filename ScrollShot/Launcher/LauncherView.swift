import SwiftUI
import AppKit

/// Root search UI: a search field + results (apps / commands / quicklinks). When
/// a quicklink is chosen it flips to argument mode (a tag + a query field).
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let ql = model.argumentMode {
                    Text(ql.title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                }
                TextField(model.argumentMode == nil ? "搜索应用、命令、快链…" : "输入搜索内容,回车打开",
                          text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()

            if let ql = model.argumentMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.query.isEmpty
                         ? "回车用「\(ql.title)」搜索"
                         : "回车用「\(ql.title)」搜索:\(model.query)")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                    Text("esc 返回").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                }
                .padding(16)
                Spacer()
            } else {
                resultsList
            }
        }
        .frame(width: 640, height: 400)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .scrollShotPickerFocus)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        .onExitCommand(perform: onClose)
        .onChange(of: model.query) { _ in if model.argumentMode == nil { model.selected = 0 } }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let r = model.results
                    if r.isEmpty {
                        Text(model.query.isEmpty ? "输入以搜索应用 / 命令 / 快链" : "无结果")
                            .font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 44)
                    }
                    ForEach(Array(r.enumerated()), id: \.element.id) { idx, item in
                        LauncherRow(item: item, selected: idx == model.selected)
                            // Element identity — index identity left stale rows
                            // in the lazy container (see ClipboardHistoryView).
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(item) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selected) { s in
                let r = model.results
                guard r.indices.contains(s) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(r[s].id, anchor: .center) }
            }
        }
    }
}

private struct LauncherRow: View {
    let item: LauncherModel.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14)).lineLimit(1)
                    .foregroundColor(selected ? .white : .primary)
                Text(item.subtitle).font(.system(size: 11)).lineLimit(1)
                    .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 4)
            if case .quicklink = item.kind {
                Image(systemName: "arrow.right").font(.system(size: 11))
                    .foregroundColor(selected ? .white : .secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8).padding(.vertical, 1)
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .app(let a):
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path))
                .resizable().frame(width: 24, height: 24)
        case .quicklink:
            Image(systemName: "magnifyingglass").font(.system(size: 15))
                .foregroundColor(selected ? .white : .secondary)
        case .command(let c):
            Image(systemName: c.systemImage).font(.system(size: 15))
                .foregroundColor(selected ? .white : .secondary)
        case .calculator:
            Image(systemName: "equal").font(.system(size: 15))
                .foregroundColor(selected ? .white : .secondary)
        }
    }
}
