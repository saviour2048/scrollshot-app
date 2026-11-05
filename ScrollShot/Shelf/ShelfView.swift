import SwiftUI
import AppKit

/// The shelf panel content: a list of parked items; each row is draggable back
/// out to Finder / any app. Drop handling is implemented in `ShelfDropTarget`
/// (AppKit `NSDraggingDestination`) because SwiftUI's `.onDrop` loses file
/// identities for image files.
struct ShelfView: View {
    @ObservedObject private var store = ShelfStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("暂存架").font(.system(size: 12, weight: .semibold))
            Spacer()
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button(action: { store.clear() }) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .help("清空暂存架")
            }
            Button(action: { ShelfWindowController.shared.dismiss() }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
            .help("收起暂存架(⌥⌘Y)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28)).foregroundColor(.secondary.opacity(0.6))
            Text("把文件 / 图片 / 文字拖到这里\n腾出手,再拖去目的地")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(store.items) { item in
                    DraggableShelfRow(
                        item: item,
                        imageURL: store.imageURL(for: item),
                        onDragOut: { removeAfterDragOut(item) },
                        onDragOutToTerminal: { removeAfterTerminalDragOut(item) },
                        onRemove: { removeItem(item) }
                    )
                    .frame(height: 46)
                }
            }
            .padding(10)
        }
    }

    private func removeAfterDragOut(_ item: ShelfItem) {
        // Yoink behavior: an item dragged out to its destination leaves the
        // shelf; the underlying files are kept briefly so the destination has
        // time to finish copying, then cleaned up.
        store.removeAfterDragOut(item)
        if store.items.isEmpty { ShelfWindowController.shared.dismiss() }
    }

    /// 拖到终端: UI 移除但保留底稿文件(终端只拿到路径, CLI 之后还要读)。
    private func removeAfterTerminalDragOut(_ item: ShelfItem) {
        store.removeAfterTerminalDragOut(item)
        if store.items.isEmpty { ShelfWindowController.shared.dismiss() }
    }

    private func removeItem(_ item: ShelfItem) {
        store.remove(item)
        if store.items.isEmpty { ShelfWindowController.shared.dismiss() }
    }
}
