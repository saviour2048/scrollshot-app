import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by ChatWindowController when the window (re)opens → focus input.
    static let scrollShotChatFocus = Notification.Name("scrollShotChatFocus")
}

/// The AI chat window: Claude-style sessions sidebar on the left, transcript +
/// input on the right. Markdown is rendered in bubbles.
struct ChatView: View {
    @ObservedObject private var store = ChatStore.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @AppStorage("chat.renderMarkdown") private var renderMD = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                inputBar
            }
        }
        .frame(minWidth: 660, minHeight: 480)
        .onAppear { focusSoon() }
        .onReceive(NotificationCenter.default.publisher(for: .scrollShotChatFocus)) { _ in focusSoon() }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { inputFocused = true }
    }

    // MARK: Sidebar (sessions)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { store.beginFreshSession(); focusSoon() }) {
                Label("新对话", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(10)

            Text("历史会话").font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.recents) { conv in
                        SessionRow(conv: conv, selected: conv.id == store.currentID,
                                   onDelete: { store.deleteConversation(conv.id) })
                            .contentShape(Rectangle())
                            .onTapGesture { store.select(conv.id); focusSoon() }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Color.primary.opacity(0.035))
    }

    // MARK: Main pane

    private var header: some View {
        HStack(spacing: 10) {
            Text(store.current?.title ?? "AI 对话").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(LLMSettings.model).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text("⌘N 新对话 · ↑↓ 切会话(输入框空时)").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
            Button(renderMD ? "原文" : "MD") { renderMD.toggle() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.accentColor)
                .help(renderMD ? "切换到原始 Markdown 文本" : "切换到渲染格式")
            Button("设置") { PreferencesWindowController.shared.show() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    let bubbles = store.current?.bubbles ?? []
                    if bubbles.isEmpty {
                        Text(LLMSettings.isConfigured
                             ? "新会话 — 直接输入,回车发送。旧会话在左边。"
                             : "先到 偏好设置 ▸ AI 对话 配好 Base URL / 模型 / API Key。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .padding(.top, 60)
                    }
                    ForEach(bubbles) { bubble in
                        BubbleRow(bubble: bubble, renderMD: renderMD).id(bubble.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(12)
            }
            .onChange(of: store.current?.bubbles.last?.content) { _ in
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onChange(of: store.currentID) { _ in
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息,回车发送…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(sendDraft)
            if store.isStreaming {
                Button("停止") { store.stop() }.font(.system(size: 12))
            } else {
                Button("发送") { sendDraft() }
                    .font(.system(size: 12))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        store.send(text)
    }
}

// MARK: - Rows

private struct SessionRow: View {
    let conv: Conversation
    let selected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(conv.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundColor(selected ? .white : .primary)
                Text(Self.rel.localizedString(for: conv.updatedAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(selected ? .white.opacity(0.8) : .secondary)
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu { Button("删除会话", role: .destructive, action: onDelete) }
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "zh_Hans"); return f
    }()
}

private struct BubbleRow: View {
    let bubble: ChatBubble
    let renderMD: Bool

    var body: some View {
        HStack {
            if bubble.role == "user" { Spacer(minLength: 48) }
            content
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(bubble.role == "user"
                            ? Color.accentColor.opacity(0.85)
                            : Color.primary.opacity(0.06))
                .foregroundColor(bubble.role == "user" ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            if bubble.role != "user" { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private var content: some View {
        let text = bubble.content.isEmpty ? "…" : bubble.content
        if bubble.role == "user" {
            Text(MarkdownBlocks.inline(text)).font(.system(size: 13))
        } else if renderMD {
            MarkdownBlocks(text: text)
        } else {
            // 原文 mode: raw markdown, monospaced for fidelity.
            Text(verbatim: text).font(.system(size: 12, design: .monospaced))
        }
    }
}

/// Lightweight block-level Markdown renderer for assistant replies: headings,
/// fenced code, tables (Grid), bullets; everything else inline-parsed. Tolerant
/// of half-streamed fences.
private struct MarkdownBlocks: View {
    let text: String

    private enum Block {
        case heading(String, Int)
        case code(String)
        case table([[String]])
        case bullet(String)
        case para(String)
        case gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let t, let level):
            Text(Self.inline(t))
                .font(.system(size: level <= 2 ? 16 : 14, weight: .bold))
                .padding(.top, 4)
        case .code(let c):
            Text(verbatim: c)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .font(.system(size: 12, weight: ri == 0 ? .semibold : .regular))
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .bullet(let t):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(Self.inline(t))
            }
        case .para(let t):
            Text(Self.inline(t))
        case .gap:
            Spacer().frame(height: 2)
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false
        var codeBuf: [String] = []
        var tableBuf: [[String]] = []
        func flushTable() {
            if !tableBuf.isEmpty { out.append(.table(tableBuf)); tableBuf = [] }
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(codeBuf.joined(separator: "\n"))); codeBuf = [] }
                inCode.toggle()
                continue
            }
            if inCode { codeBuf.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { ":-".contains($0) } }
                if !isSeparator { tableBuf.append(cells) }
                continue
            }
            flushTable()
            if trimmed.isEmpty { out.append(.gap); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.count > level {
                    out.append(.heading(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces), level))
                    continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            out.append(.para(line))
        }
        if inCode, !codeBuf.isEmpty { out.append(.code(codeBuf.joined(separator: "\n"))) }
        flushTable()
        return out
    }

    /// Inline markdown (bold/italic/code/links); plain text on parse failure.
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
