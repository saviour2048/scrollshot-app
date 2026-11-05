import SwiftUI
import ApplicationServices

struct BrightnessPreferencesView: View {
    @StateObject private var controller = M1DDCBrightnessController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("brightness.displaysFound"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(L("brightness.refresh")) { controller.refreshDisplays() }
            }

            Toggle(L("brightness.showMenuBarIcon"), isOn: Binding(
                get: { controller.showMenuBarIcon },
                set: { controller.showMenuBarIcon = $0 }
            ))
            .font(.system(size: 12))

            Toggle(L("brightness.interceptKeys"), isOn: Binding(
                get: { controller.interceptBrightnessKeys },
                set: { controller.interceptBrightnessKeys = $0 }
            ))
            .font(.system(size: 12))

            HStack(spacing: 8) {
                StatusBadge(granted: AXIsProcessTrusted())
                Text(L("brightness.permissionHint"))
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

            Text(L("brightness.interceptKeysHint"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = controller.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.displays.isEmpty {
                Text(L("brightness.noDisplays"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(controller.displays) { display in
                    DisplayBrightnessRow(display: display, value: value(for: display))
                }
            }
        }
    }

    private func value(for display: M1DDCDisplay) -> Binding<Int> {
        Binding(
            get: { controller.brightnessValues[display.uuid] ?? 50 },
            set: { newValue in
                controller.writeBrightness(display: display, value: newValue)
            }
        )
    }
}

struct DisplayBrightnessRow: View {
    let display: M1DDCDisplay
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(display.name).font(.system(size: 13))
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0) }
            ), in: 0...100, step: 1)
        }
    }
}
