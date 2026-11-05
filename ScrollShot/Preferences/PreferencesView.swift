import SwiftUI
import AppKit
import CoreGraphics
import ApplicationServices
import KeyboardShortcuts
import Combine

// MARK: - Adaptive color tokens

extension Color {
    static let ssText = adaptive(
        light: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
    )
    static let ssSecondary = adaptive(
        light: NSColor(srgbRed: 0x3C / 255, green: 0x3C / 255, blue: 0x43 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xEB / 255, green: 0xEB / 255, blue: 0xF5 / 255, alpha: 0.60)
    )
    static let ssTertiary = adaptive(
        light: NSColor(srgbRed: 0x6C / 255, green: 0x6C / 255, blue: 0x70 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xEB / 255, green: 0xEB / 255, blue: 0xF5 / 255, alpha: 0.60)
    )
    static let ssMuted = adaptive(
        light: NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)
    )
    static let ssBlue = adaptive(
        light: NSColor(srgbRed: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
    )
    static let ssGreen = adaptive(
        light: NSColor(srgbRed: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
    )
    static let ssOrange = adaptive(
        light: NSColor(srgbRed: 0xFF / 255, green: 0x95 / 255, blue: 0x00 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    )
    static let ssPage = adaptive(
        light: NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    )
    static let ssCard = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1)
    )
    static let ssFill = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.70),
        dark: NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 0.70)
    )
    static let ssHairline = adaptive(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let ssControlBorder = adaptive(
        light: NSColor.black.withAlphaComponent(0.15),
        dark: NSColor.white.withAlphaComponent(0.18)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Sidebar data

enum PreferenceTag: String, CaseIterable, Identifiable {
    case all, shortcut, menubar, ai, permission, privacy, sync
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:       return L("settings.tag.all")
        case .shortcut:  return L("settings.tag.shortcut")
        case .menubar:   return L("settings.tag.menubar")
        case .ai:        return L("settings.tag.ai")
        case .permission:return L("settings.tag.permission")
        case .privacy:   return L("settings.tag.privacy")
        case .sync:      return L("settings.tag.sync")
        }
    }
}

/// Sidebar grouping for the (long) module list.
enum PreferenceSection: String, CaseIterable, Identifiable {
    case general, capture, menuBar, input, tools, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "截图"
        case .menuBar: return "菜单栏与监控"
        case .input:   return "键鼠与快捷键"
        case .tools:   return "效率工具"
        case .other:   return "其他"
        }
    }
}

enum PreferenceModule: String, CaseIterable, Identifiable {
    // Declaration order = sidebar order within each section.
    case general
    case capture
    case usage
    case systemMonitor
    case deviceBattery
    case brightness
    case inputStats
    case shortcuts
    case keyMapping
    case inputSource
    case smartPaste
    case mouseAccel
    case windowTiling
    case launcher
    case aiChat
    case agentBridge
    case clipboardShelf
    case keyChatter
    case cableInfo
    case privacy
    case credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:        return L("settings.module.general")
        case .shortcuts:      return L("settings.shortcuts")
        case .capture:        return L("settings.module.capture")
        case .usage:          return L("settings.module.usage")
        case .inputStats:     return L("settings.inputStats")
        case .clipboardShelf: return L("settings.module.clipboardShelf")
        case .keyChatter:     return L("settings.module.keyChatter")
        case .launcher:       return L("settings.launcher")
        case .aiChat:         return L("settings.ai")
        case .agentBridge:    return L("settings.module.agentBridge")
        case .keyMapping:     return L("settings.module.keyMapping")
        case .inputSource:    return L("settings.module.inputSource")
        case .smartPaste:     return L("settings.module.smartPaste")
        case .brightness:     return L("settings.brightness")
        case .mouseAccel:     return L("settings.mouseAccel")
        case .windowTiling:   return "窗口分屏"
        case .systemMonitor:  return "系统监控"
        case .deviceBattery:  return L("settings.module.deviceBattery")
        case .cableInfo:      return "线缆检测"
        case .privacy:        return L("settings.privacy")
        case .credits:        return L("settings.credits")
        }
    }

    var icon: String {
        switch self {
        case .general:        return "gear"
        case .shortcuts:      return "keyboard"
        case .capture:        return "camera"
        case .usage:          return "chart.bar"
        case .inputStats:     return "keyboard.fill"
        case .clipboardShelf: return "clipboard"
        case .keyChatter:     return "waveform.path.ecg"
        case .launcher:       return "magnifyingglass"
        case .aiChat:         return "bubble.left.and.bubble.right"
        case .agentBridge:    return "checkmark.shield"
        case .keyMapping:     return "arrow.left.arrow.right"
        case .inputSource:    return "character"
        case .smartPaste:     return "doc.on.clipboard"
        case .brightness:     return "sun.max"
        case .mouseAccel:     return "cursorarrow.motionlines"
        case .windowTiling:   return "rectangle.split.2x1"
        case .systemMonitor:  return "cpu"
        case .deviceBattery:  return "battery.75"
        case .cableInfo:      return "cable.connector"
        case .privacy:        return "hand.raised"
        case .credits:        return "heart.text.square"
        }
    }

    var tags: [PreferenceTag] {
        switch self {
        case .general:        return [.permission, .sync]
        case .shortcuts:      return [.shortcut]
        case .capture:        return []
        case .usage:          return [.menubar, .ai]
        case .inputStats:     return [.menubar, .privacy]
        case .clipboardShelf: return [.privacy]
        case .keyChatter:     return []
        case .launcher:       return [.shortcut]
        case .aiChat:         return [.ai]
        case .agentBridge:    return [.ai]
        case .keyMapping:     return [.permission]
        case .inputSource:    return [.permission]
        case .smartPaste:     return [.shortcut, .permission]
        case .brightness:     return [.menubar]
        case .mouseAccel:     return []
        case .windowTiling:   return [.shortcut]
        case .systemMonitor:  return [.menubar]
        case .deviceBattery:  return [.menubar]
        case .cableInfo:      return []
        case .privacy:        return [.privacy]
        case .credits:        return []
        }
    }

    /// Sidebar section (grouping order = `PreferenceSection.allCases`).
    var section: PreferenceSection {
        switch self {
        case .general:                                  return .general
        case .capture:                                  return .capture
        case .usage, .systemMonitor, .deviceBattery, .brightness, .inputStats: return .menuBar
        case .shortcuts, .keyMapping, .inputSource, .smartPaste, .mouseAccel, .windowTiling: return .input
        case .launcher, .aiChat, .clipboardShelf:       return .tools
        case .keyChatter:                               return .tools
        case .agentBridge:                              return .tools
        case .cableInfo, .privacy, .credits:            return .other
        }
    }

    /// The master feature switch shown at the trailing edge of the sidebar row;
    /// nil = no background feature to switch (core capture, plain panes).
    var feature: FeatureSwitches.AppFeature? {
        switch self {
        case .usage:          return .usage
        case .inputStats:     return .inputStats
        case .clipboardShelf: return .clipboard
        case .launcher:       return .launcher
        case .aiChat:         return .aiChat
        case .agentBridge:    return .agentBridge
        case .keyMapping:     return .keyMapping
        case .inputSource:    return .inputSource
        case .smartPaste:     return .smartPaste
        case .brightness:     return .brightness
        case .mouseAccel:     return .mouseAccel
        case .windowTiling:   return .windowTiling
        case .systemMonitor:  return .systemMonitor
        case .deviceBattery:  return .deviceBattery
        case .general, .shortcuts, .capture, .cableInfo, .privacy, .credits: return nil
        case .keyChatter: return nil
        }
    }
}

// MARK: - Main view

struct PreferencesView: View {
    @State private var selectedModule: PreferenceModule = .general
    @State private var selectedTag: PreferenceTag? = nil
    @State private var searchQuery = ""

    @State private var screenGranted = false
    @State private var accessibilityGranted = false
    @State private var saveDir: URL = AppConfig.saveDirectory
    @State private var usageSectionVisible = UsageMonitorSettings.enabled
    @State private var iCloudSync = SettingsSync.shared.iCloudDriveAvailable
    @State private var clipboardEnabled = ClipboardMonitor.isEnabled
    @State private var llmBaseURL = LLMSettings.baseURL
    @State private var llmModel = LLMSettings.model
    @State private var llmKey = LLMSettings.apiKey
    @State private var kimiKey = KimiSettings.apiKey
    @State private var consoleToken = DeepSeekConsoleSettings.consoleToken
    @State private var kimiBaseURL = KimiSettings.baseURL
    @State private var claudeWebSessionKey = ClaudeWebSettings.sessionKey
    @State private var shelfAutoPresent = ShelfSettings.autoPresent
    @State private var shelfCopyImageOnTerminalDrop = ShelfSettings.copyImageOnTerminalDrop
    @State private var inputStatsEnabled = InputStatsSettings.enabled
    @State private var smartPasteEnabled = SmartPasteController.isEnabled
    @State private var inputStatsShowInMenuBar = InputStatsSettings.showInMenuBar
    @State private var mouseAccelDisabled = MouseAccelerationController.enabled
    @State private var mouseAccelSpeed = MouseAccelerationController.speed
    @State private var windowTilingEnabled = WindowTilingController.enabled
    @State private var sysmonEnabled = SystemMonitorSettings.enabled
    @State private var sysmonCPU = SystemMonitorSettings.shows(.cpu)
    @State private var sysmonMem = SystemMonitorSettings.shows(.memory)
    @State private var sysmonNet = SystemMonitorSettings.shows(.network)
    @State private var sysmonTemp = SystemMonitorSettings.shows(.temperature)
    @State private var sysmonFan = SystemMonitorSettings.shows(.fan)
    @State private var sysmonMemPressure = SystemMonitorSettings.showsMemPressure
    @State private var sysmonSim = SystemMonitorSettings.shows(.simulator)
    @State private var sysmonMergeWhenCrowded = SystemMonitorSettings.mergeWhenCrowded
    @State private var analyticsEnabled = AnalyticsSettings.enabled
    @State private var selectedLanguage = LocalizationManager.shared.current
    @AppStorage(AppThemeMode.storageKey) private var themeMode = AppThemeMode.system.rawValue
    @State private var launchAtLoginOn = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("menubar.showCamera") private var showCameraIcon = true
    @AppStorage("chat.renderMarkdown") private var renderMarkdown = true
    @State private var claudeLoggedIn = ClaudeOAuthStore.isLoggedIn
    @State private var loginVerifier: String?
    @State private var loginCode = ""
    @State private var loginBusy = false
    @State private var loginError: String?

    @State private var quicklinks = Quicklinks.all
    @State private var newKeyword = ""
    @State private var newTitle = ""
    @State private var newURL = ""

    /// Master feature switches shown on the sidebar rows.
    @StateObject private var featureSwitches = FeatureSwitches.shared

    // 手动 connect/cancel:只在设置窗口可见时运行。窗口 close 只隐藏不销毁
    // (isReleasedWhenClosed = false),onDisappear 不会触发,所以可见性要靠
    // NSWindow.didChangeOcclusionStateNotification 判断(见 body 里的 onReceive)。
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common)
    @State private var refreshTimerConnection: Cancellable?
    @State private var hostingWindow: NSWindow?

    var body: some View {
        NavigationSplitView {
            sidebar
                // macOS 27 gives the column too narrow a default width —
                // every label truncated ("用…/系…/键…") on each open. Pin it:
                // wide enough for the longest module title + master switch.
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 320)
        } detail: {
            detailView
        }
        .frame(minWidth: 720, idealWidth: 800, maxWidth: .infinity,
               minHeight: 520, idealHeight: 600, maxHeight: .infinity)
        .background(Color.ssPage)
        .background(WindowAccessor(window: $hostingWindow))
        .onAppear {
            refresh()
            startRefreshTimer()
        }
        .onDisappear { stopRefreshTimer() }
        // 窗口关闭/最小化时 occlusion 失去 .visible,重新打开时恢复 —— 据此启停定时器
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w === hostingWindow else { return }
            if w.occlusionState.contains(.visible) { startRefreshTimer() } else { stopRefreshTimer() }
        }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func startRefreshTimer() {
        guard refreshTimerConnection == nil else { return }
        refreshTimerConnection = refreshTimer.connect()
    }

    private func stopRefreshTimer() {
        refreshTimerConnection?.cancel()
        refreshTimerConnection = nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("settings.title"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.ssText)
                TextField(L("settings.search"), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                tagBar
            }
            .padding()
            .background(Color.ssPage)

            List(selection: $selectedModule) {
                if isFiltering {
                    // Flat list while searching / tag-filtering so matches stay together.
                    ForEach(filteredModules) { module in sidebarRow(module) }
                } else {
                    ForEach(PreferenceSection.allCases) { section in
                        let modules = PreferenceModule.allCases.filter { $0.section == section }
                        if !modules.isEmpty {
                            Section(header: Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.ssMuted)) {
                                ForEach(modules) { module in sidebarRow(module) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// One sidebar row; features with background resources get a master switch
    /// on the trailing edge (off = timers/taps/monitors/hotkeys truly stopped).
    @ViewBuilder private func sidebarRow(_ module: PreferenceModule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: module.icon)
                .frame(width: 20, alignment: .center)
                .foregroundColor(.ssBlue)
            Text(module.title)
                .font(.system(size: 13))
            Spacer()
            if let feature = module.feature {
                Toggle("", isOn: Binding(
                    get: { featureSwitches.isEnabled(feature) },
                    set: { featureSwitches.setEnabled(feature, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .tag(module)
    }

    private var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            || (selectedTag != nil && selectedTag != .all)
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PreferenceTag.allCases) { tag in
                    Button(tag.title) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTag = (selectedTag == tag ? nil : tag)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: selectedTag == tag ? .semibold : .regular))
                    .foregroundColor(selectedTag == tag ? .white : .ssSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selectedTag == tag ? Color.ssBlue : Color.ssFill)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.ssHairline, lineWidth: 1))
                }
            }
        }
    }

    private var filteredModules: [PreferenceModule] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return PreferenceModule.allCases.filter { module in
            let matchesTag = selectedTag == nil || selectedTag == .all || module.tags.contains(selectedTag!)
            let tagString = module.tags.map(\.title).joined(separator: " ")
            let matchesSearch = q.isEmpty
                || module.title.localizedCaseInsensitiveContains(q)
                || tagString.localizedCaseInsensitiveContains(q)
            return matchesTag && matchesSearch
        }
    }

    // MARK: Detail

    @ViewBuilder private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selectedModule.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.ssText)

                switch selectedModule {
                case .general:        generalPane
                case .shortcuts:      shortcutsPane
                case .capture:        capturePane
                case .usage:          usagePane
                case .inputStats:     inputStatsPane
                case .clipboardShelf: clipboardShelfPane
                case .launcher:       launcherPane
                case .aiChat:         aiChatPane
                case .agentBridge:    AgentBridgePane()
                case .keyMapping:     keyMappingPane
                case .inputSource:    inputSourcePane
                case .smartPaste:     smartPastePane
                case .brightness:     brightnessPane
                case .mouseAccel:     mouseAccelPane
                case .windowTiling:   windowTilingPane
                case .systemMonitor:  systemMonitorPane
                case .deviceBattery:  DeviceBatteryPreferencesView()
                case .keyChatter:     keyChatterPane
                case .cableInfo:      CableInfoPane()
                case .privacy:        privacyPane
                case .credits:        creditsPane
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.ssPage)
    }

    // MARK: - Panes

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            appearanceSection
            languageSection
            launchSection
            permissionSection
            syncSection
            aboutSection
        }
    }

    private var appearanceSection: some View {
        Card(title: L("settings.appearance")) {
            Picker("", selection: $themeMode) {
                ForEach(AppThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: themeMode) { _ in AppTheme.applyStored() }
            Text(L("settings.appearance.hint"))
                .font(.system(size: 11)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var launchSection: some View {
        Card(title: L("settings.launchAtLogin.title")) {
            VStack(alignment: .leading, spacing: 8) {
                // @State mirror + onChange (same pattern as the other toggles
                // here): a computed Binding(get:set:) never triggers a SwiftUI
                // re-render on success, so the checkbox looked dead even though
                // SMAppService registration had worked.
                Toggle(L("settings.launchAtLogin.enable"), isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { on in
                        launchAtLoginError = LaunchAtLogin.set(on)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 11))
                        .foregroundColor(.ssOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var shortcutsPane: some View {
        Card(title: L("settings.shortcuts")) {
            VStack(alignment: .leading, spacing: 18) {
                ShortcutRow(title: L("settings.shortcuts.capture"),
                            hint: L("settings.shortcuts.captureHint"),
                            name: .captureRegion)
                ShortcutRow(title: L("settings.clipboard.shortcut"),
                            hint: L("settings.clipboard.hint"),
                            name: .clipboardHistory)
                ShortcutRow(title: L("settings.launcher.shortcut"),
                            hint: L("settings.launcher.defaultHint"),
                            name: .launcher)
                ShortcutRow(title: L("settings.ai.shortcut"),
                            hint: L("settings.ai.hint"),
                            name: .aiChat)
                ShortcutRow(title: L("settings.shelf.shortcut"),
                            hint: L("settings.shelf.hint"),
                            name: .shelf)
            }
        }
    }

    private var capturePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            saveSection
            menuBarIconSection
        }
    }

    private var menuBarIconSection: some View {
        Card(title: L("settings.menubar")) {
            Toggle(L("settings.menubar.showCamera"), isOn: $showCameraIcon)
                .onChange(of: showCameraIcon) { _ in MainMenuBarController.shared.reload() }
            Text(L("settings.menubar.showCameraHint"))
                .font(.system(size: 11)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageEnabledBinding: Binding<Bool> {
        Binding(
            get: { UsageMonitorSettings.enabled },
            set: { v in
                UsageMonitorSettings.enabled = v
                usageSectionVisible = v
                UsageStatusItemController.shared.reload()
            }
        )
    }

    private var usageLeftSlotBinding: Binding<MenuBarSlot> {
        Binding(
            get: { UsageMonitorSettings.menuBarLeft },
            set: { v in
                UsageMonitorSettings.menuBarLeft = v
                UsageStore.shared.refresh()
                UsageStatusItemController.shared.reload()
            }
        )
    }

    private var usageRightSlotBinding: Binding<MenuBarSlot> {
        Binding(
            get: { UsageMonitorSettings.menuBarRight },
            set: { v in
                UsageMonitorSettings.menuBarRight = v
                UsageStore.shared.refresh()
                UsageStatusItemController.shared.reload()
            }
        )
    }

    private var usageShowCatBinding: Binding<Bool> {
        Binding(
            get: { UsageMonitorSettings.showCatIcon },
            set: { v in
                UsageMonitorSettings.showCatIcon = v
                UsageStatusItemController.shared.reload()
            }
        )
    }

    private var usageMetricBinding: Binding<MenuBarMetric> {
        Binding(
            get: { UsageMonitorSettings.menuBarMetric },
            set: { v in
                UsageMonitorSettings.menuBarMetric = v
                UsageStatusItemController.shared.reload()
            }
        )
    }

    private var usageIntervalBinding: Binding<TimeInterval> {
        Binding(
            get: { UsageMonitorSettings.refreshInterval },
            set: { v in
                UsageMonitorSettings.refreshInterval = v
                UsageStore.shared.scheduleTimer()
            }
        )
    }

    private var usagePane: some View {
        Card(title: L("settings.module.usage")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.menubar.showUsage"), isOn: usageEnabledBinding)

                if usageSectionVisible {
                    Divider().overlay(Color.ssHairline)

                    Toggle(L("settings.menubar.showCatIcon"), isOn: usageShowCatBinding)

                    PickerRow(title: L("settings.menubar.leftColumn"), selection: usageLeftSlotBinding) {
                        ForEach(MenuBarSlot.allCases) { s in Text(s.label).tag(s) }
                    }

                    PickerRow(title: L("settings.menubar.rightColumn"), selection: usageRightSlotBinding) {
                        ForEach(MenuBarSlot.allCases) { s in Text(s.label).tag(s) }
                    }

                    PickerRow(title: L("settings.menubar.metric"), selection: usageMetricBinding) {
                        ForEach(MenuBarMetric.allCases) { m in Text(m.label).tag(m) }
                    }

                    PickerRow(title: L("settings.menubar.refresh"), selection: usageIntervalBinding) {
                        Text(L("settings.interval.manual")).tag(TimeInterval(0))
                        Text(L("settings.interval.1m")).tag(TimeInterval(60))
                        Text(L("settings.interval.2m")).tag(TimeInterval(120))
                        Text(L("settings.interval.5m")).tag(TimeInterval(300))
                        Text(L("settings.interval.15m")).tag(TimeInterval(900))
                    }

                    Divider().overlay(Color.ssHairline)
                    claudeLoginSection

                    Divider().overlay(Color.ssHairline)

                    Text(L("settings.usage.webTitle"))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                    HStack {
                        Text(L("settings.usage.sessionKey"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .frame(width: 62, alignment: .leading)
                        SecureField(L("settings.usage.sessionKeyPlaceholder"), text: $claudeWebSessionKey)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onChange(of: claudeWebSessionKey) { v in
                                ClaudeWebSettings.sessionKey = v
                                UsageStore.shared.refresh()
                            }
                    }
                    Text(L("settings.usage.sessionKeyHint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Color.ssHairline)

                    Text(L("settings.usage.kimiTitle"))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                    HStack {
                        Text(L("settings.menubar.kimiKey"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .frame(width: 62, alignment: .leading)
                        SecureField("sk-…(Kimi For Coding 的 Key)", text: $kimiKey)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onChange(of: kimiKey) { v in
                                KimiSettings.apiKey = v
                                UsageStore.shared.refresh()
                            }
                    }
                    HStack {
                        Text(L("settings.menubar.kimiBaseURL"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .frame(width: 62, alignment: .leading)
                        TextField("https://api.kimi.com", text: $kimiBaseURL)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onChange(of: kimiBaseURL) { v in KimiSettings.baseURL = v }
                    }
                    Text(L("settings.menubar.kimiHint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Color.ssHairline)

                    Text(L("settings.usage.codexTitle"))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                    if CodexSettings.isConfigured {
                        let detail = UsageStore.shared.snapshot.codex?.planType?.capitalized
                            ?? CodexSettings.accountEmail
                        Label(L("settings.usage.codexLoggedIn") + (detail.map { " · \($0)" } ?? ""),
                              systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13)).foregroundColor(.ssGreen)
                    } else {
                        Text(L("settings.usage.codexNotLoggedIn"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(Color.ssHairline)

                    Text(L("settings.usage.opencodeTitle"))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                    if OpenCodeSettings.isConfigured {
                        let detail = OpenCodeSettings.maskedKey.map { " · \($0)" } ?? ""
                        Label(L("settings.usage.opencodeLoggedIn") + detail,
                              systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13)).foregroundColor(.ssGreen)
                    } else {
                        Text(L("settings.usage.opencodeNotLoggedIn"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(Color.ssHairline)

                    Text(L("settings.usage.deepseekTitle"))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                    HStack {
                        Text(L("settings.usage.consoleToken"))
                            .font(.system(size: 12)).foregroundColor(.ssMuted)
                            .frame(width: 62, alignment: .leading)
                        SecureField("userToken", text: $consoleToken)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onChange(of: consoleToken) { v in
                                DeepSeekConsoleSettings.consoleToken = v
                                UsageStore.shared.refresh()
                            }
                    }
                    Text(L("settings.usage.consoleTokenHint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("settings.usage.copyConsoleCommand")) {
                        // 在 platform.deepseek.com 的 F12 控制台执行后,令牌直接进剪贴板,回来 ⌘V 即可
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("copy(JSON.parse(localStorage.userToken).value)", forType: .string)
                    }
                    .font(.system(size: 12))

                    Text(L("settings.menubar.costHint"))
                        .font(.system(size: 12)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var inputStatsPane: some View {
        Card(title: L("settings.inputStats")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.inputStats.enable"), isOn: $inputStatsEnabled)
                    .onChange(of: inputStatsEnabled) { on in
                        InputStatsSettings.enabled = on
                        InputStatsStatusItemController.shared.reload()
                        if on {
                            if !InputEventTap.shared.isAccessibilityGranted() {
                                _ = InputEventTap.shared.promptAccessibilityTrust()
                            }
                            InputStatsSync.shared.startSyncing()
                        } else {
                            InputStatsSync.shared.stopSyncing()
                        }
                        InputStatsEventMonitor.shared.updateMonitors()
                    }

                if inputStatsEnabled {
                    Divider().overlay(Color.ssHairline)
                    Toggle(L("settings.inputStats.showInMenuBar"), isOn: $inputStatsShowInMenuBar)
                        .onChange(of: inputStatsShowInMenuBar) { v in
                            InputStatsSettings.showInMenuBar = v
                            InputStatsStatusItemController.shared.reload()
                        }
                    Text(L("settings.inputStats.hint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var privacyPane: some View {
        Card(title: L("settings.privacy")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.privacy.analytics"), isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { on in AnalyticsSettings.enabled = on }
                Text(L("settings.privacy.analytics.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyChatterPane: some View {
        Card(title: L("settings.module.keyChatter")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("settings.keyChatter.hint"))
                    .font(.system(size: 12)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("settings.keyChatter.open")) {
                    KeyChatterWindowController.shared.show()
                }
                .buttonStyle(.borderedProminent)
                Text(L("settings.keyChatter.where"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var creditsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.credits.intro"))
                .font(.system(size: 12)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)

            Card(title: L("settings.credits.libraries")) {
                ForEach(Credits.libraries) { CreditRow(credit: $0) }
            }
            Card(title: L("settings.credits.assets")) {
                ForEach(Credits.assets) { CreditRow(credit: $0) }
            }
            Card(title: L("settings.credits.inspiration")) {
                ForEach(Credits.inspiration) { CreditRow(credit: $0) }
            }
        }
    }

    private var mouseAccelPane: some View {
        Card(title: L("settings.mouseAccel")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.mouseAccel.enable"), isOn: $mouseAccelDisabled)
                    .onChange(of: mouseAccelDisabled) { on in
                        MouseAccelerationController.enabled = on
                        MouseAccelerationController.shared.reload()
                    }
                Text(L("settings.mouseAccel.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if mouseAccelDisabled {
                    Divider().overlay(Color.ssHairline)
                    HStack(spacing: 8) {
                        Text(L("settings.mouseAccel.speed"))
                            .font(.system(size: 13))
                            .foregroundColor(.ssText)
                        Slider(value: $mouseAccelSpeed, in: 0.2 ... 8.0)
                            .onChange(of: mouseAccelSpeed) { v in
                                MouseAccelerationController.speed = v
                                MouseAccelerationController.shared.applyTrackingSpeed()
                            }
                        Text(String(format: "%.1f", mouseAccelSpeed))
                            .font(.system(size: 12))
                            .foregroundColor(.ssMuted)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Text(L("settings.mouseAccel.speedHint"))
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var windowTilingPane: some View {
        Card(title: "窗口分屏") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("启用键盘分屏", isOn: $windowTilingEnabled)
                    .onChange(of: windowTilingEnabled) { on in
                        WindowTilingController.enabled = on
                        WindowTilingController.shared.reload()
                    }
                Text("给下面每个排列各设一个全局快捷键;需要「辅助功能」权限来移动其它 App 的窗口。")
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if windowTilingEnabled {
                    ForEach(Tile.allCases) { tile in
                        HStack {
                            Text(tile.title).font(.system(size: 13)).foregroundColor(.ssText)
                            Spacer()
                            KeyboardShortcuts.Recorder(for: tile.shortcutName)
                        }
                    }
                }
            }
        }
    }

    private var systemMonitorPane: some View {
        Card(title: "系统监控") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("在菜单栏显示系统监控", isOn: $sysmonEnabled)
                    .onChange(of: sysmonEnabled) { on in
                        SystemMonitorSettings.enabled = on
                        SystemMonitorStatusItems.shared.reload()
                    }
                if sysmonEnabled {
                    Text("每个指标是一个独立的菜单栏项(⌘拖动可排序);点开看该资源占用最高的进程。")
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("空间不够时自动合并成一个项", isOn: $sysmonMergeWhenCrowded)
                        .onChange(of: sysmonMergeWhenCrowded) { v in
                            SystemMonitorSettings.mergeWhenCrowded = v
                            SystemMonitorStatusItems.shared.reload()
                        }
                    Text("屏幕小/接外接屏时菜单栏可能放不下,系统会把项折叠或叠在一起。开启后检测到这种情况就把上面的指标合并成一个两行项,信息不会被藏起来;空间恢复(插拔屏、合盖)后自动拆回独立项。")
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("CPU 占用", isOn: $sysmonCPU)
                        .onChange(of: sysmonCPU) { v in SystemMonitorSettings.setShows(.cpu, v); SystemMonitorStatusItems.shared.reload() }
                    Toggle("内存", isOn: $sysmonMem)
                        .onChange(of: sysmonMem) { v in SystemMonitorSettings.setShows(.memory, v); SystemMonitorStatusItems.shared.reload() }
                    Toggle("网速(↓↑)", isOn: $sysmonNet)
                        .onChange(of: sysmonNet) { v in SystemMonitorSettings.setShows(.network, v); SystemMonitorStatusItems.shared.reload() }
                    Toggle("核心温度", isOn: $sysmonTemp)
                        .onChange(of: sysmonTemp) { v in SystemMonitorSettings.setShows(.temperature, v); SystemMonitorStatusItems.shared.reload() }
                    Toggle("风扇转速", isOn: $sysmonFan)
                        .onChange(of: sysmonFan) { v in SystemMonitorSettings.setShows(.fan, v); SystemMonitorStatusItems.shared.reload() }
                    Toggle(L("sysmon.memPressure"), isOn: $sysmonMemPressure)
                        .onChange(of: sysmonMemPressure) { v in SystemMonitorSettings.showsMemPressure = v; SystemMonitorStatusItems.shared.reload() }
                    Toggle("iOS 模拟器", isOn: $sysmonSim)
                        .onChange(of: sysmonSim) { v in SystemMonitorSettings.setShows(.simulator, v); SystemMonitorStatusItems.shared.reload() }
                    Text("有模拟器在跑时才出现在菜单栏(显示其内存占用),没跑不占空间;点开看已启动的设备和进程明细。")
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("温度和风扇转速都需要读取 SMC 传感器;部分机型读不到(分别显示「—°」「—」),无风扇机型没有可显示的风扇是正常情况。")
                        .font(.system(size: 11)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var clipboardShelfPane: some View {
        Card(title: L("settings.module.clipboardShelf")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.clipboard.record"), isOn: $clipboardEnabled)
                    .onChange(of: clipboardEnabled) { on in
                        ClipboardMonitor.isEnabled = on
                        if on { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
                    }

                Divider().overlay(Color.ssHairline)

                ShortcutRow(title: L("settings.clipboard.shortcut"),
                            hint: L("settings.clipboard.hint"),
                            name: .clipboardHistory)

                Text(L("settings.clipboard.privacyHint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.ssHairline)

                Toggle(isOn: Binding(
                    get: { featureSwitches.isEnabled(.shelf) },
                    set: { featureSwitches.setEnabled(.shelf, $0) }
                )) {
                    Text("启用暂存架").font(.system(size: 13)).foregroundColor(.ssText)
                }

                ShortcutRow(title: L("settings.shelf.shortcut"),
                            hint: L("settings.shelf.hint"),
                            name: .shelf)
                    .disabled(!featureSwitches.isEnabled(.shelf))

                Toggle(isOn: $shelfAutoPresent) {
                    Text(L("settings.shelf.autoPresent")).font(.system(size: 13)).foregroundColor(.ssText)
                }
                .disabled(!featureSwitches.isEnabled(.shelf))
                .onChange(of: shelfAutoPresent) { v in ShelfSettings.autoPresent = v }

                Toggle(isOn: $shelfCopyImageOnTerminalDrop) {
                    Text(L("settings.shelf.copyImageOnTerminalDrop")).font(.system(size: 13)).foregroundColor(.ssText)
                }
                .disabled(!featureSwitches.isEnabled(.shelf))
                .onChange(of: shelfCopyImageOnTerminalDrop) { v in ShelfSettings.copyImageOnTerminalDrop = v }

                Text(L("settings.shelf.copyImageOnTerminalDropHint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("settings.shelf.autoPresentHint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launcherPane: some View {
        Card(title: L("settings.launcher")) {
            VStack(alignment: .leading, spacing: 14) {
                ShortcutRow(title: L("settings.launcher.shortcut"),
                            hint: L("settings.launcher.defaultHint"),
                            name: .launcher)

                Divider().overlay(Color.ssHairline)

                Text(L("settings.quicklinks"))
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                Text(L("settings.quicklinks.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach($quicklinks) { $link in
                        HStack(spacing: 6) {
                            TextField(L("settings.quicklinks.keyword"), text: $link.keyword)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                .frame(width: 70)
                            TextField(L("settings.quicklinks.title"), text: $link.title)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                .frame(minWidth: 70)
                            TextField(L("settings.quicklinks.url"), text: $link.urlTemplate)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                            Button(action: { removeQuicklink(link) }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.ssOrange)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        if link.id != quicklinks.last?.id {
                            Divider().overlay(Color.ssHairline)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField(L("settings.quicklinks.keyword"), text: $newKeyword)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                            .frame(width: 70)
                        TextField(L("settings.quicklinks.title"), text: $newTitle)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        TextField(L("settings.quicklinks.url"), text: $newURL)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        Button(L("settings.quicklinks.add")) { addQuicklink() }
                            .font(.system(size: 12))
                            .disabled(newKeyword.isEmpty || newURL.isEmpty)
                    }
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, 10)
                .background(Color.ssCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    Spacer()
                    Button(L("settings.quicklinks.default")) {
                        quicklinks = Quicklinks.defaults
                        Quicklinks.save(quicklinks)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.ssOrange)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aiChatPane: some View {
        Card(title: L("settings.ai")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("settings.ai.baseURL")).font(.system(size: 13)).foregroundColor(.ssText).frame(width: 70, alignment: .leading)
                    TextField("https://api.deepseek.com", text: $llmBaseURL)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onChange(of: llmBaseURL) { v in LLMSettings.baseURL = v }
                }
                HStack {
                    Text(L("settings.ai.model")).font(.system(size: 13)).foregroundColor(.ssText).frame(width: 70, alignment: .leading)
                    TextField("deepseek-flash", text: $llmModel)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onChange(of: llmModel) { v in LLMSettings.model = v }
                }
                HStack {
                    Text(L("settings.ai.apiKey")).font(.system(size: 13)).foregroundColor(.ssText).frame(width: 70, alignment: .leading)
                    SecureField("sk-…", text: $llmKey)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onChange(of: llmKey) { v in LLMSettings.apiKey = v }
                }

                Divider().overlay(Color.ssHairline)

                Toggle(isOn: $renderMarkdown) {
                    Text(L("settings.renderMarkdown")).font(.system(size: 13)).foregroundColor(.ssText)
                }
                Text(L("settings.renderMarkdown.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.ssHairline)

                ShortcutRow(title: L("settings.ai.shortcut"),
                            hint: L("settings.ai.hint"),
                            name: .aiChat)
            }
        }
    }

    private var keyMappingPane: some View {
        Card(title: L("settings.module.keyMapping")) {
            KeyMappingPreferencesView()
        }
    }

    private var inputSourcePane: some View {
        Card(title: L("settings.module.inputSource")) {
            InputSourcePreferencesView()
        }
    }

    private var smartPastePane: some View {
        Card(title: L("settings.module.smartPaste")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("settings.smartPaste.enable"), isOn: $smartPasteEnabled)
                    .onChange(of: smartPasteEnabled) { on in
                        // 先弹权限引导再应用：无辅助功能权限时 start() 不会注册。
                        if on && !InputEventTap.shared.isAccessibilityGranted() {
                            _ = InputEventTap.shared.promptAccessibilityTrust()
                        }
                        featureSwitches.setEnabled(.smartPaste, on)
                    }
                Text(L("settings.smartPaste.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !accessibilityGranted {
                    Divider().overlay(Color.ssHairline)
                    HStack(spacing: 8) {
                        StatusBadge(granted: false)
                        Text(L("settings.smartPaste.permissionHint"))
                            .font(.system(size: 12))
                            .foregroundColor(.ssMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("settings.openSettings")) {
                            open(AppConfig.accessibilitySettingsURL)
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
                }
            }
        }
    }

    private var brightnessPane: some View {
        Card(title: L("settings.brightness")) {
            VStack(alignment: .leading, spacing: 14) {
                BrightnessPreferencesView()
                Text(L("settings.brightness.hint"))
                    .font(.system(size: 11)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Existing sections (reused in panes)

    private var languageSection: some View {
        Card(title: L("settings.language")) {
            Picker("", selection: $selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedLanguage) { language in
                LocalizationManager.shared.setLanguage(language)
            }
            Text(L("settings.language.restartHint"))
                .font(.system(size: 11)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        Card(title: L("settings.permissions")) {
            PermissionRow(
                title: L("settings.permissions.screenRecording"),
                detail: L("settings.permissions.screenRecordingHint"),
                granted: screenGranted
            ) { open(AppConfig.screenRecordingSettingsURL) }

            Divider().overlay(Color.ssHairline)

            PermissionRow(
                title: L("settings.permissions.accessibility"),
                detail: L("settings.permissions.accessibilityHint"),
                granted: accessibilityGranted
            ) { open(AppConfig.accessibilitySettingsURL) }

            Text(L("settings.permissions.restartHint"))
                .font(.system(size: 12))
                .foregroundColor(.ssMuted)
                .padding(.top, 2)
        }
    }

    private var saveSection: some View {
        Card(title: L("settings.save")) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.save.location")).font(.system(size: 14, weight: .medium)).foregroundColor(.ssText)
                    Text(saveLocationDisplay)
                        .font(.system(size: 12)).foregroundColor(.ssMuted)
                        .lineLimit(1).truncationMode(.middle)
                        .help(saveDir.path)
                }
                Spacer(minLength: 8)
                if AppConfig.hasCustomSaveDirectory {
                    Button(L("settings.save.default")) {
                        AppConfig.resetSaveDirectory()
                        saveDir = AppConfig.saveDirectory
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.ssBlue)
                }
                Button(action: chooseSaveLocation) {
                    Text(L("settings.save.change"))
                        .font(.system(size: 13))
                        .foregroundColor(.ssSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.ssControlBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(L("settings.save.hint"))
                .font(.system(size: 12))
                .foregroundColor(.ssMuted)
                .padding(.top, 2)
        }
    }

    private var syncSection: some View {
        Card(title: L("settings.sync")) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(iCloudSync ? L("settings.sync.icloudOn") : L("settings.sync.icloudOff"))
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.ssText)
                    Text(iCloudSync
                         ? L("settings.sync.icloudOnHint")
                         : L("settings.sync.icloudOffHint"))
                        .font(.system(size: 12)).foregroundColor(.ssMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(iCloudSync ? Color.ssGreen : Color.ssMuted)
                        .frame(width: 7, height: 7)
                    Text(iCloudSync ? "iCloud" : L("settings.sync.icloudOff"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(iCloudSync ? .ssGreen : .ssMuted)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background((iCloudSync ? Color.ssGreen : Color.ssMuted).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var aboutSection: some View {
        Card(title: L("settings.about")) {
            HStack {
                Text(L("settings.about.version")).font(.system(size: 14)).foregroundColor(.ssText)
                Spacer()
                Text(versionString).font(.system(size: 14)).foregroundColor(.ssMuted)
            }
            Text(L("settings.about.credit"))
                .font(.system(size: 11)).foregroundColor(.ssMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Claude login

    @ViewBuilder private var claudeLoginSection: some View {
        // The store can be cleared in the background (failed token refresh with
        // invalid_grant), so re-read it every time instead of trusting @State.
        let loggedIn = ClaudeOAuthStore.isLoggedIn
        if loggedIn {
            HStack {
                Label(L("settings.usage.claudeLoggedIn"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13)).foregroundColor(.ssGreen)
                Spacer()
                Button(L("settings.usage.logout")) {
                    ClaudeOAuthStore.clear()
                    claudeLoggedIn = false
                    UsageStore.shared.refresh()
                }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundColor(.ssBlue)
            }
        } else if loginVerifier != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("settings.usage.authHint"))
                    .font(.system(size: 12)).foregroundColor(.ssText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(L("settings.usage.authPlaceholder"), text: $loginCode)
                        .textFieldStyle(.roundedBorder)
                    Button(L("settings.usage.submit")) { submitLoginCode() }
                        .disabled(loginBusy || loginCode.isEmpty)
                    Button(L("settings.usage.cancel")) { cancelLogin() }
                        .buttonStyle(.plain).foregroundColor(.ssMuted)
                }
                if let e = loginError {
                    Text(e).font(.system(size: 11)).foregroundColor(.ssOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack {
                Button(L("settings.usage.claudeLogin")) { startLogin() }
                Spacer()
            }
        }
    }

    private func startLogin() {
        let verifier = ClaudeLogin.makeVerifier()
        loginVerifier = verifier
        loginCode = ""
        loginError = nil
        NSWorkspace.shared.open(ClaudeLogin.authorizeURL(verifier: verifier))
    }

    private func cancelLogin() {
        loginVerifier = nil
        loginCode = ""
        loginError = nil
    }

    private func submitLoginCode() {
        guard let verifier = loginVerifier else { return }
        let pasted = loginCode.trimmingCharacters(in: .whitespacesAndNewlines)
        loginBusy = true
        loginError = nil
        Task {
            do {
                try await ClaudeLogin.exchange(pastedCode: pasted, verifier: verifier)
                await MainActor.run {
                    claudeLoggedIn = true
                    loginVerifier = nil
                    loginCode = ""
                    loginBusy = false
                    UsageStore.shared.refresh()
                }
            } catch {
                await MainActor.run {
                    loginError = error.localizedDescription
                    loginBusy = false
                }
            }
        }
    }

    // MARK: - Quicklinks helpers

    private func addQuicklink() {
        let kw = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !newURL.isEmpty else { return }
        var list = quicklinks
        list.removeAll { $0.keyword == kw }
        list.append(Quicklink(keyword: kw,
                              title: newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? kw : newTitle.trimmingCharacters(in: .whitespaces),
                              urlTemplate: newURL.trimmingCharacters(in: .whitespaces)))
        quicklinks = list
        Quicklinks.save(list)
        newKeyword = ""
        newTitle = ""
        newURL = ""
    }

    private func removeQuicklink(_ link: Quicklink) {
        quicklinks.removeAll { $0.id == link.id }
        Quicklinks.save(quicklinks)
    }

    // MARK: - Helpers

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var saveLocationDisplay: String {
        (saveDir.path as NSString).abbreviatingWithTildeInPath
    }

    private func refresh() {
        screenGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        saveDir = AppConfig.saveDirectory
        iCloudSync = SettingsSync.shared.iCloudDriveAvailable
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("settings.save.choosePrompt")
        panel.message = L("settings.save.chooseMessage")
        panel.directoryURL = saveDir
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            AppConfig.saveDirectory = url
            saveDir = url
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Reusable building blocks

/// 读取承载视图的 NSWindow。设置窗口关闭时只是隐藏(不销毁),SwiftUI 的
/// onDisappear 不会触发,需要拿到 window 配合 occlusion 通知判断可见性。
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 异步赋值,避免在 view update 周期内改 @State 触发运行时警告
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard window !== nsView.window else { return }
        DispatchQueue.main.async { window = nsView.window }
    }
}

private struct PickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let content: () -> Content
    let onChange: (Selection) -> Void

    init(title: String,
         selection: Binding<Selection>,
         @ViewBuilder content: @escaping () -> Content,
         onChange: @escaping (Selection) -> Void = { _ in }) {
        self.title = title
        self._selection = selection
        self.content = content
        self.onChange = onChange
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundColor(.ssText)
            Spacer()
            Picker("", selection: $selection) {
                content()
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: selection, perform: onChange)
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let hint: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundColor(.ssText)
                Text(hint).font(.system(size: 12)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.ssMuted)
                .tracking(0.2)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ssCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(.ssText)
                Text(detail).font(.system(size: 12)).foregroundColor(.ssMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusBadge(granted: granted)
            Button(action: openSettings) {
                Text(L("settings.openSettings"))
                    .font(.system(size: 13))
                    .foregroundColor(.ssSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.ssControlBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

struct StatusBadge: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(granted ? Color.ssGreen : Color.ssOrange)
                .frame(width: 7, height: 7)
            Text(granted ? L("settings.granted") : L("settings.notGranted"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(granted ? .ssGreen : .ssOrange)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            (granted ? Color.ssGreen : Color.ssOrange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}

#Preview {
    PreferencesView()
}
