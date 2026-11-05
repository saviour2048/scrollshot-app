import SwiftUI
import AppKit

/// A lightweight translator window: source text → target language via the user's
/// configured LLM (DeepSeek / OpenAI-compatible). Triggered from the launcher.
@MainActor
final class TranslationWindowController {
    static let shared = TranslationWindowController()

    private var window: NSPanel?
    private init() {}

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let root = TranslationView()
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        panel.title = L("translation.title")
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 520, height: 420))
        return panel
    }
}

// MARK: - SwiftUI

private struct TranslationView: View {
    @StateObject private var store = TranslationStore()
    @State private var input = ""
    @State private var target: TargetLanguage = .chinese
    @FocusState private var inputFocused: Bool

    private var canTranslate: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editorSection(title: L("translation.sourcePlaceholder"), text: $input)
                .frame(minHeight: 90)
            Divider()
            controlBar
            Divider()
            outputSection
                .frame(minHeight: 90)
            if let error = store.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack {
            Text(L("translation.title"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(L("translation.close")) { closeWindow() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func editorSection(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($inputFocused)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker(L("translation.target"), selection: $target) {
                ForEach(TargetLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            if !store.output.isEmpty {
                Button(L("translation.copy")) { store.copyOutput() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }

            Button(store.isStreaming ? L("translation.stop") : L("translation.translate")) {
                store.isStreaming ? store.stop() : store.translate(text: input, to: target)
            }
            .font(.system(size: 12))
            .disabled(!canTranslate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("translation.outputPlaceholder"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if store.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            TextEditor(text: .constant(store.output))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    private func closeWindow() {
        TranslationWindowController.shared.close()
    }
}

// MARK: - Store

@MainActor
private final class TranslationStore: ObservableObject {
    @Published var output = ""
    @Published var isStreaming = false
    @Published var errorText: String?

    private var task: Task<Void, Never>?

    func translate(text: String, to target: TargetLanguage) {
        guard LLMSettings.isConfigured else {
            errorText = L("translation.notConfigured"); return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = L("translation.emptyInput"); return }

        errorText = nil
        output = ""
        isStreaming = true
        task?.cancel()

        let prompt = "Translate the following text to \(target.promptName). " +
                     "Output only the translation, no quotes, no explanation.\n\n\(trimmed)"
        let messages = [LLMMessage(role: "user", content: prompt)]

        task = Task { [weak self] in
            do {
                let stream = try await LLMClient.stream(messages: messages)
                for try await delta in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.output += delta
                }
            } catch is CancellationError {
                // keep partial
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.isStreaming = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
}

// MARK: - Target languages

private enum TargetLanguage: String, CaseIterable, Identifiable {
    case chinese, english, japanese, korean, french, german, spanish, russian
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese:  return "中"
        case .english:  return "En"
        case .japanese: return "日"
        case .korean:   return "韩"
        case .french:   return "法"
        case .german:   return "德"
        case .spanish:  return "西"
        case .russian:  return "俄"
        }
    }

    var promptName: String {
        switch self {
        case .chinese:  return "Chinese"
        case .english:  return "English"
        case .japanese: return "Japanese"
        case .korean:   return "Korean"
        case .french:   return "French"
        case .german:   return "German"
        case .spanish:  return "Spanish"
        case .russian:  return "Russian"
        }
    }
}
