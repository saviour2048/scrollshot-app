import SwiftUI

/// Root view of the notch panel: shows the oldest pending request as a card
/// dropping out of the notch. Empty regions of the view are click-through.
struct NotchRootView: View {
    @ObservedObject var store: AgentBridgeStore
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            if let request = store.pending.first {
                NotchCardView(store: store, request: request)
                    .id(request.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, max(geometry.notchHeight, 24) - 6)
            }
            Spacer(minLength: 0)
        }
        .frame(width: geometry.cardWidth)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: store.pending.first?.id)
    }
}

private struct NotchCardView: View {
    @ObservedObject var store: AgentBridgeStore
    let request: AgentBridgeStore.PendingRequest

    /// ScrollShot-owned approval chrome stays English regardless of the app
    /// locale. Agent-provided commands, questions, and options remain as returned.
    private enum Copy {
        static let deny = "Deny"
        static let allowAlways = "Always Allow"
        static let allow = "Allow"
        static let cancel = "Cancel"
        static let confirm = "Confirm"
        static let waitingForConfirmation = "Kimi Code is waiting for confirmation"
        static let dismiss = "Dismiss"
        static let openTerminal = "Open Terminal"
        static let answerPlaceholder = "Type your answer…"
    }

    /// question.text → selected labels (multiSelect accumulates, single
    /// select replaces). Reset per request via .id on the parent.
    @State private var selections: [String: [String]] = [:]
    /// question.text → free-text answer, for questions that offer no options.
    @State private var customs: [String: String] = [:]

    private var model: AgentBridgeProtocols.CardModel { request.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch model.interaction {
            case .permission:
                permissionBody
            case .question:
                questionBody
            case .notify:
                notifyBody
            case .ignore:
                EmptyView()
            }
        }
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.42))
                RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12))
            }
        )
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.source.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.ssBlue.opacity(0.85), in: Capsule())
                if !model.toolName.isEmpty {
                    Text(model.toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
            }
            // 哪个 session 发来的：文件夹 · 会话名。同一时刻可能有好几个
            // Codex/Claude 会话在跑，没有这行根本分不清卡片属于谁。
            if let session = request.sessionLabel, !session.isEmpty {
                Text(session)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if !model.detail.isEmpty {
            Text(model.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailLine
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                cardButton(Copy.deny, color: .red) {
                    store.respond(id: request.id, decision: .deny(message: nil))
                }
                if model.hasPermissionSuggestions {
                    cardButton(Copy.allowAlways, color: .ssGreen) {
                        store.respond(id: request.id, decision: .allowAlways)
                    }
                }
                cardButton(Copy.allow, color: .ssBlue) {
                    store.respond(id: request.id, decision: .allow)
                }
            }
        }
    }

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.questions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.text)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            if question.options.isEmpty {
                                customAnswerField(question: question)
                            } else {
                                ForEach(question.options) { option in
                                    optionButton(question: question, option: option)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            if needsConfirmButton {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    cardButton(Copy.cancel, color: .gray) {
                        store.respond(id: request.id, decision: .cancel)
                    }
                    cardButton(Copy.confirm, color: allAnswered ? .ssBlue : .gray) {
                        store.respond(id: request.id, decision: .answer(selections: selections, customs: customs))
                    }
                    .disabled(!allAnswered)
                }
            }
        }
    }

    private var notifyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.waitingForConfirmation)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            detailLine
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                cardButton(Copy.dismiss, color: .gray) {
                    store.dismiss(id: request.id)
                }
                cardButton(Copy.openTerminal, color: .ssBlue) {
                    NotchPanelController.activateTerminal(bundleID: model.terminalBundleID)
                    store.dismiss(id: request.id)
                }
            }
        }
    }

    // MARK: - Question helpers

    private var singleQuickPick: Bool {
        model.questions.count == 1
            && model.questions.first?.multiSelect == false
            && model.questions.first?.options.isEmpty == false
    }

    private var needsConfirmButton: Bool { !singleQuickPick }

    private var allAnswered: Bool {
        model.questions.allSatisfy {
            selections[$0.text]?.isEmpty == false
                || customs[$0.text]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Free-text field for questions that offer no options (dsh allows that;
    /// without it the confirm button could never enable and the card stuck).
    private func customAnswerField(question: AgentBridgeProtocols.Question) -> some View {
        TextField(Copy.answerPlaceholder, text: Binding(
            get: { customs[question.text] ?? "" },
            set: { customs[question.text] = $0 }
        ))
        .font(.system(size: 12))
        .textFieldStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func optionButton(question: AgentBridgeProtocols.Question, option: AgentBridgeProtocols.Option) -> some View {
        let selected = selections[question.text]?.contains(option.label) ?? false
        return Button {
            if singleQuickPick {
                store.respond(id: request.id, decision: .answer(selections: [question.text: [option.label]], customs: [:]))
            } else if question.multiSelect {
                var labels = selections[question.text] ?? []
                if let index = labels.firstIndex(of: option.label) {
                    labels.remove(at: index)
                } else {
                    labels.append(option.label)
                }
                selections[question.text] = labels
            } else {
                selections[question.text] = [option.label]
            }
        } label: {
            HStack(spacing: 6) {
                if !singleQuickPick {
                    Image(systemName: question.multiSelect
                          ? (selected ? "checkmark.square.fill" : "square")
                          : (selected ? "checkmark.circle.fill" : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.ssBlue : .white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private func cardButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
