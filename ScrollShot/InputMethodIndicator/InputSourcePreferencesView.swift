import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Preferences pane for the Input Source Pro-style feature.
struct InputSourcePreferencesView: View {
    @StateObject private var store = InputSourceStore.shared
    @State private var isAdding = false
    @State private var addMode: AddMode = .app
    @State private var newBundleID = ""
    @State private var newDomain = ""
    @State private var selectedInputSourceID = ""
    @State private var availableSources: [InputSourceController.InputSource] = []
    @State private var shiftEnabled = InputSourceSettings.shiftToggleEnabled
    @State private var shiftSideSel = InputSourceSettings.shiftToggleSide
    @State private var shiftCJKSel = InputSourceSettings.resolvedCJKSourceID ?? ""
    @State private var shiftLatinSel = InputSourceSettings.resolvedLatinSourceID ?? ""
    @State private var capsLockDelayOn = CapsLockDelayOverride.isEnabled
    @State private var capsLockStatus = ""
    @State private var capsLockStatusError = false

    private var shiftToggleBinding: Binding<Bool> {
        Binding(
            get: { InputSourceSettings.shiftToggleEnabled },
            set: { v in
                InputSourceSettings.shiftToggleEnabled = v
                shiftEnabled = v
                ShiftInputToggle.shared.updateRegistration()
            }
        )
    }

    /// Reads the live hidutil override back and turns it into a user-visible
    /// status line — the page must show whether it actually took effect.
    private func refreshCapsLockStatus() {
        let live = CapsLockDelayOverride.currentOverride()
        if capsLockDelayOn {
            capsLockStatus = (live == 0) ? L("settings.capsLock.statusOn") : L("settings.capsLock.statusFail")
            capsLockStatusError = (live != 0)
        } else {
            capsLockStatus = (live == 0) ? L("settings.capsLock.statusFail") : L("settings.capsLock.statusOff")
            capsLockStatusError = (live == 0)
        }
    }

    private func sourcePickerRow(title: String, selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.ssText)
                .frame(width: 70, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(availableSources) { source in
                    Text(source.displayTitle).tag(source.sourceID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    enum AddMode {
        case app, domain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L("settings.shiftToggle.enable"), isOn: shiftToggleBinding)
                    .font(.system(size: 14))

                if shiftEnabled {
                    HStack(spacing: 8) {
                        Text(L("settings.shiftToggle.trigger"))
                            .font(.system(size: 13))
                            .foregroundColor(.ssText)
                            .frame(width: 70, alignment: .leading)
                        Picker("", selection: $shiftSideSel) {
                            ForEach(ShiftInputToggle.Side.allCases) { s in
                                Text(L(s.titleKey)).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: shiftSideSel) { InputSourceSettings.shiftToggleSide = $0 }
                    }
                    sourcePickerRow(title: L("settings.shiftToggle.cjk"), selection: $shiftCJKSel)
                        .onChange(of: shiftCJKSel) { InputSourceSettings.shiftToggleCJKSourceID = $0 }
                    sourcePickerRow(title: L("settings.shiftToggle.latin"), selection: $shiftLatinSel)
                        .onChange(of: shiftLatinSel) { InputSourceSettings.shiftToggleLatinSourceID = $0 }

                    Text(L("settings.shiftToggle.hint"))
                        .font(.system(size: 12))
                        .foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Color.ssHairline)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.capsLock.title"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.ssText)
                    Toggle(L("settings.capsLock.instant"), isOn: $capsLockDelayOn)
                        .font(.system(size: 13))
                        .onChange(of: capsLockDelayOn) { on in
                            CapsLockDelayOverride.isEnabled = on
                            CapsLockDelayOverride.applyNow()
                            refreshCapsLockStatus()
                        }
                    Text(capsLockStatus)
                        .font(.system(size: 11))
                        .foregroundColor(capsLockStatusError ? .ssOrange : .ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        Text(L("settings.capsLock.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(.ssMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("settings.capsLock.openSettings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .background(Color.ssCard)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Toggle(L("settings.inputSource.enable"), isOn: $store.isEnabled)
                    .font(.system(size: 14))
                Spacer()
            }

            if store.isEnabled {
                HStack {
                    Toggle(L("settings.inputSource.enableDomain"), isOn: $store.isDomainEnabled)
                        .font(.system(size: 14))
                    Spacer()
                }

                Text(L("settings.inputSource.permissionHint"))
                    .font(.system(size: 12))
                    .foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if store.rules.isEmpty {
                    Text(L("settings.inputSource.noRules"))
                        .font(.system(size: 13))
                        .foregroundColor(.ssMuted)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach($store.rules) { $rule in
                            InputSourceRuleRow(
                                rule: $rule,
                                sources: availableSources,
                                onDelete: { store.removeRule(id: rule.id) }
                            )
                            if rule.id != store.rules.last?.id {
                                Divider().overlay(Color.ssHairline)
                            }
                        }
                    }
                    .background(Color.ssCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if isAdding {
                    addRuleForm
                }

                HStack {
                    Button(isAdding ? L("settings.keyMapping.cancelAdd") : L("settings.inputSource.addRule")) {
                        if isAdding {
                            isAdding = false
                            resetAddForm()
                        } else {
                            isAdding = true
                            refreshSources()
                        }
                    }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)

                    Spacer()

                    Button(L("settings.inputSource.restoreDefaults")) {
                        store.resetToDefaults()
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.ssOrange)
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            refreshSources()
            refreshCapsLockStatus()
        }
    }

    // MARK: - Add form

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $addMode) {
                Text(L("settings.inputSource.modeApp")).tag(AddMode.app)
                Text(L("settings.inputSource.modeDomain")).tag(AddMode.domain)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if addMode == .domain {
                Text(L("settings.inputSource.domainHint"))
                    .font(.system(size: 12))
                    .foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(L("settings.inputSource.app"))
                    .font(.system(size: 13))
                    .foregroundColor(.ssText)
                    .frame(width: 70, alignment: .leading)
                TextField(L("settings.inputSource.appPlaceholder"), text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(L("settings.inputSource.chooseApp")) {
                    chooseApplicationBundleID()
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if addMode == .domain {
                HStack(spacing: 8) {
                    Text(L("settings.inputSource.domain"))
                        .font(.system(size: 13))
                        .foregroundColor(.ssText)
                        .frame(width: 70, alignment: .leading)
                    TextField(L("settings.inputSource.domainPlaceholder"), text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            HStack(spacing: 8) {
                Text(L("settings.inputSource.inputMethod"))
                    .font(.system(size: 13))
                    .foregroundColor(.ssText)
                    .frame(width: 70, alignment: .leading)
                Picker("", selection: $selectedInputSourceID) {
                    Text(L("settings.inputSource.choose")).tag("")
                    ForEach(availableSources) { source in
                        Text(source.displayTitle).tag(source.sourceID)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120)
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()
                Button(L("settings.usage.cancel")) {
                    isAdding = false
                    resetAddForm()
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                Button(L("settings.quicklinks.add")) {
                    addRule()
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        }
        .padding(12)
        .background(Color.ssCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canAdd: Bool {
        let bundleOK = !newBundleID.trimmingCharacters(in: .whitespaces).isEmpty
        let sourceOK = !selectedInputSourceID.isEmpty
        if addMode == .app {
            return bundleOK && sourceOK
        }
        let domainOK = !newDomain.trimmingCharacters(in: .whitespaces).isEmpty
        return bundleOK && domainOK && sourceOK
    }

    // MARK: - Helpers

    private func refreshSources() {
        availableSources = InputSourceController.enabledInputSources
        if let first = availableSources.first, selectedInputSourceID.isEmpty {
            selectedInputSourceID = first.sourceID
        }
    }

    private func resetAddForm() {
        addMode = .app
        newBundleID = ""
        newDomain = ""
        selectedInputSourceID = availableSources.first?.sourceID ?? ""
    }

    private func addRule() {
        let bundleID = newBundleID.trimmingCharacters(in: .whitespaces)
        let domain = addMode == .domain ? newDomain.trimmingCharacters(in: .whitespaces) : nil
        guard !bundleID.isEmpty, !selectedInputSourceID.isEmpty else { return }
        guard let source = availableSources.first(where: { $0.sourceID == selectedInputSourceID }) else { return }
        store.addRule(InputSourceRule(
            bundleID: bundleID,
            domain: domain,
            inputSourceID: source.sourceID,
            inputSourceName: source.localizedName
        ))
        isAdding = false
        resetAddForm()
    }

    private func chooseApplicationBundleID() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType.applicationBundle, UTType.bundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = L("settings.inputSource.chooseAppMessage")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Try multiple ways to read the bundle identifier; some apps (e.g. VS Code)
        // may not return one through the generic Bundle(url:) path due to packaging.
        let id = bundleIdentifier(for: url)
        newBundleID = id ?? url.lastPathComponent
    }

    private func bundleIdentifier(for appURL: URL) -> String? {
        if let id = Bundle(path: appURL.path)?.bundleIdentifier, !id.isEmpty {
            return id
        }
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL) else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}

// MARK: - Rule row

private struct InputSourceRuleRow: View {
    @Binding var rule: InputSourceRule
    let sources: [InputSourceController.InputSource]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.bundleLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(rule.isEnabled ? .ssText : .ssMuted)
                HStack(spacing: 4) {
                    if let domain = rule.domainLabel {
                        Text(domain)
                            .font(.system(size: 11))
                            .foregroundColor(.ssOrange)
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(.ssMuted)
                    }
                    Text(rule.inputSourceName)
                        .font(.system(size: 11))
                        .foregroundColor(.ssMuted)
                }
            }

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
}
