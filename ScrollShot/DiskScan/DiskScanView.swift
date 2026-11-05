import SwiftUI
import AppKit

// MARK: - Color tokens (match the Preferences / HIG palette)

private extension Color {
    static let dsText      = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let dsSecondary = Color(red: 0x3C / 255, green: 0x3C / 255, blue: 0x43 / 255)
    static let dsMuted     = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    static let dsBlue      = Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255)
    static let dsGreen     = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let dsOrange    = Color(red: 0xFF / 255, green: 0x95 / 255, blue: 0x00 / 255)
    static let dsRed       = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)
    static let dsHairline  = Color.black.opacity(0.08)
}

struct DiskScanView: View {
    @ObservedObject var scanner: DiskScanner

    @State private var showTrashConfirm = false
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var showFDAButton = false
    @State private var hasFDA = DiskScanner.hasFullDiskAccess()

    private var needsFDABanner: Bool { !hasFDA }

    var body: some View {
        VStack(spacing: 0) {
            header
            controlBar
            if needsFDABanner { fdaBanner }
            Divider().overlay(Color.dsHairline)
            content
            Divider().overlay(Color.dsHairline)
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { hasFDA = DiskScanner.hasFullDiskAccess() }
        .alert("移到废纸篓?", isPresented: $showTrashConfirm) {
            Button("移到废纸篓", role: .destructive) { performTrash() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将把选中的 \(scanner.selectedItems.count) 项(共 \(scanner.selectedTotalText))移到废纸篓。\n可随时在「访达 ▸ 废纸篓」里恢复,不会永久删除。")
        }
        .alert("完成", isPresented: $showResult) {
            if showFDAButton {
                Button("打开完全磁盘访问") {
                    if let url = AppConfig.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
                }
            }
            Button("好", role: .cancel) { }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("磁盘清理")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.dsText)
            Text("扫描大文件,标出可安全删除的缓存与构建产物 — 删除一律移到废纸篓。")
                .font(.system(size: 12))
                .foregroundColor(.dsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 30)        // clear the transparent title bar / traffic lights
        .padding(.bottom, 12)
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $scanner.range) {
                Text("主目录 ~").tag(ScanRange.home)
                Text("整个磁盘").tag(ScanRange.fullDisk)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(scanner.isScanning)

            Picker("最小", selection: $scanner.thresholdMB) {
                Text("≥ 100 MB").tag(100)
                Text("≥ 500 MB").tag(500)
                Text("≥ 1 GB").tag(1000)
            }
            .fixedSize()
            .disabled(scanner.isScanning)

            Spacer()

            if scanner.isScanning {
                ProgressView().controlSize(.small)
                Text("已扫描 \(scanner.scannedCount) 项")
                    .font(.system(size: 12)).foregroundColor(.dsMuted)
                Button("停止") { scanner.cancelScan() }
            } else {
                Button(action: { scanner.startScan() }) {
                    Label("开始扫描", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundColor(.dsOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text("建议授予「完全磁盘访问」—— 一次授权,不再反复弹窗")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.dsText)
                Text("否则扫到 桌面 / 文稿 / 下载 等目录时,系统会逐个弹窗要权限。授权后请退出并重开 ScrollShot 生效。系统目录任何情况下都不会动。")
                    .font(.system(size: 11)).foregroundColor(.dsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("打开设置") {
                if let url = AppConfig.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.dsOrange.opacity(0.10))
    }

    // MARK: Content (list / empty states)

    @ViewBuilder
    private var content: some View {
        if scanner.items.isEmpty {
            emptyState
        } else {
            List {
                ForEach($scanner.items) { $item in
                    DiskRowView(item: $item)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: scanner.isScanning ? "hourglass" : "internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.dsMuted)
            Text(scanner.isScanning ? "正在扫描…" : "点「开始扫描」查找大文件")
                .font(.system(size: 13)).foregroundColor(.dsMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom action bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if scanner.hasSelection {
                Text("已选 \(scanner.selectedItems.count) 项 · \(scanner.selectedTotalText)")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.dsText)
            } else {
                Text("勾选要清理的项目。默认不选任何项。")
                    .font(.system(size: 12)).foregroundColor(.dsMuted)
            }
            Spacer()
            Button("一键选中可清缓存") { scanner.selectOneClick() }
                .disabled(scanner.items.allSatisfy { !$0.oneClickEligible })
            Button(role: .destructive) {
                showTrashConfirm = true
            } label: {
                Label("移到废纸篓", systemImage: "trash")
            }
            .disabled(!scanner.hasSelection)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func performTrash() {
        scanner.moveSelectedToTrash { outcome in
            var msg = "已移到废纸篓 \(outcome.removed) 项,可在访达里恢复。"
            if outcome.skipped > 0 {
                msg += "\n另有 \(outcome.skipped) 项未能删除——多是沙盒 App 的受保护容器缓存(~/Library/Containers/…)。授予「完全磁盘访问」并重开 ScrollShot 后,大多可删除。"
            }
            resultMessage = msg
            showFDAButton = outcome.skipped > 0
            showResult = true
        }
    }
}

// MARK: - Row

private struct DiskRowView: View {
    @Binding var item: DiskScanItem

    private var selectable: Bool { item.safety != .keep }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()
                .disabled(!selectable)
                .opacity(selectable ? 1 : 0.3)

            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundColor(.dsMuted)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.dsText)
                        .lineLimit(1)
                    CategoryTag(text: item.category.label)
                    SafetyBadge(safety: item.safety)
                }
                Text(item.reason)
                    .font(.system(size: 11))
                    .foregroundColor(.dsSecondary)
                    .lineLimit(1)
                Text("\(item.displayPath) · 修改于 \(item.modifiedText)")
                    .font(.system(size: 10))
                    .foregroundColor(.dsMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.isSizing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("计算中…").font(.system(size: 11)).foregroundColor(.dsMuted)
                }
            } else {
                Text(item.sizeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.dsText)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if selectable { item.isSelected.toggle() } }
    }
}

private struct CategoryTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.dsSecondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Color.black.opacity(0.06), in: Capsule())
    }
}

private struct SafetyBadge: View {
    let safety: DiskItemSafety

    private var config: (String, Color)? {
        switch safety {
        case .safe:   return ("可安全删除", .dsGreen)
        case .review: return ("需你判断", .dsOrange)
        case .keep:   return nil
        }
    }

    var body: some View {
        if let (text, color) = config {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}
