import SwiftUI
import ApplicationServices

/// Keyboard-remapping configuration UI shown inside PreferencesView.
struct KeyMappingPreferencesView: View {
    @StateObject private var store = KeyMappingStore.shared
    @State private var isAdding = false
    @State private var newFromKey = KeyCode.h
    @State private var newToKey = KeyCode.leftArrow
    @State private var newCommand = true
    @State private var newOption = false
    @State private var newControl = false
    @State private var newShift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(L("settings.keyMapping.enable"), isOn: $store.isEnabled)
                    .font(.system(size: 14))
                Spacer()
            }

            HStack(spacing: 8) {
                StatusBadge(granted: AXIsProcessTrusted())
                Text(L("settings.keyMapping.permissionHint"))
                    .font(.system(size: 12))
                    .foregroundColor(.ssMuted)
                Spacer()
                Button(L("settings.openSettings")) {
                    if let url = AppConfig.accessibilitySettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(.ssSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.ssControlBorder, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }

            if store.isEnabled {
                if store.rules.isEmpty {
                    Text(L("settings.keyMapping.noRules"))
                        .font(.system(size: 13))
                        .foregroundColor(.ssMuted)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach($store.rules) { $rule in
                            KeyMappingRuleRow(rule: $rule, onDelete: {
                                store.removeRule(id: rule.id)
                            })
                            if rule.id != store.rules.last?.id {
                                Divider().overlay(Color.ssHairline)
                            }
                        }
                    }
                    .background(Color.ssCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if isAdding {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Picker(L("settings.keyMapping.from"), selection: $newFromKey) {
                                ForEach(filteredSourceKeys) { key in
                                    Text(key.displayName).tag(key)
                                }
                            }
                            .frame(width: 90)
                            .pickerStyle(.menu)
                            .labelsHidden()

                            modifierToggles

                            Text("→")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.ssMuted)

                            Picker(L("settings.keyMapping.to"), selection: $newToKey) {
                                ForEach(filteredTargetKeys) { key in
                                    Text(key.displayName).tag(key)
                                }
                            }
                            .frame(width: 90)
                            .pickerStyle(.menu)
                            .labelsHidden()

                            Spacer()
                        }

                        HStack {
                            Spacer()
                            Button(L("settings.usage.cancel")) { isAdding = false }
                                .font(.system(size: 13))
                                .buttonStyle(.plain)
                            Button(L("settings.quicklinks.add")) {
                                var modifiers = KeyModifiers()
                                if newCommand { modifiers.insert(.command) }
                                if newOption   { modifiers.insert(.option) }
                                if newControl  { modifiers.insert(.control) }
                                if newShift    { modifiers.insert(.shift) }
                                store.addRule(KeyMappingRule(
                                    fromKeyCode: newFromKey.rawValue,
                                    fromModifiers: modifiers,
                                    toKeyCode: newToKey.rawValue,
                                    toModifiers: []
                                ))
                                isAdding = false
                            }
                            .font(.system(size: 13, weight: .medium))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(Color.ssCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    Button(isAdding ? L("settings.keyMapping.cancelAdd") : L("settings.keyMapping.addRule")) {
                        isAdding.toggle()
                    }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)

                    Spacer()

                    Button(L("settings.keyMapping.restoreDefaults")) {
                        store.resetToDefaults()
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.ssOrange)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filteredSourceKeys: [KeyCode] {
        KeyCode.allCases.filter { ![.leftCommand, .rightCommand, .leftOption, .rightOption, .leftControl, .rightControl, .leftShift, .rightShift].contains($0) }
    }

    private var filteredTargetKeys: [KeyCode] {
        KeyCode.allCases
    }

    private var modifierToggles: some View {
        HStack(spacing: 4) {
            Toggle("⌘", isOn: $newCommand)
                .toggleStyle(.button)
                .font(.system(size: 13, weight: .semibold))
            Toggle("⌥", isOn: $newOption)
                .toggleStyle(.button)
                .font(.system(size: 13, weight: .semibold))
            Toggle("⌃", isOn: $newControl)
                .toggleStyle(.button)
                .font(.system(size: 13, weight: .semibold))
            Toggle("⇧", isOn: $newShift)
                .toggleStyle(.button)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(height: 24)
    }
}

private struct KeyMappingRuleRow: View {
    @Binding var rule: KeyMappingRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()

            Text(ruleDescription)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(rule.isEnabled ? .ssText : .ssMuted)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.ssOrange)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var ruleDescription: String {
        let fromModifiers = rule.fromModifiers.description
        let fromName = KeyCode.name(for: rule.fromKeyCode)
        let toName = KeyCode.name(for: rule.toKeyCode)
        return "\(fromModifiers)\(fromModifiers.isEmpty ? "" : " + ")\(fromName) → \(toName)"
    }
}

extension KeyModifiers {
    var description: String {
        var parts: [String] = []
        if contains(.command) { parts.append("⌘") }
        if contains(.option)   { parts.append("⌥") }
        if contains(.control)  { parts.append("⌃") }
        if contains(.shift)    { parts.append("⇧") }
        return parts.joined(separator: " ")
    }
}
