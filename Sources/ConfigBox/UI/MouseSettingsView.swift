import SwiftUI

/// Mouse › Settings: scrolling, pointer speed / acceleration, convenience buttons (mice only).
struct MouseSettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var devices: [PointerSettings.DeviceState] = []
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Reverse vertical scrolling (mouse wheel only)", isOn: $store.config.mouse.reverseVertical)
                Toggle("Reverse horizontal scrolling (tilt wheel only)", isOn: $store.config.mouse.reverseHorizontal)
                LabeledContent("Scroll speed") {
                    HStack {
                        Slider(value: $store.config.mouse.scrollSpeed, in: 0.25...4, step: 0.25)
                        Text(String(format: "%.2f×", store.config.mouse.scrollSpeed)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Smooth scrolling", isOn: $store.config.mouse.smoothScrolling)
                Toggle("Shift + wheel scrolls horizontally", isOn: $store.config.mouse.shiftScrollsHorizontally)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep the system's scrolling in these apps").font(.callout)
                    ForEach(store.config.mouse.scrollExcludedApps, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(nsImage: AppIcons.icon(for: id)).resizable().frame(width: 18, height: 18)
                            Text(AppIcons.displayNameShort(for: id))
                            Text(id).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            IconButton(systemName: "minus.circle", help: "Remove") { store.config.mouse.scrollExcludedApps.removeAll { $0 == id } }
                        }
                    }
                    Menu {
                        ForEach(AppIcons.runningApps()) { app in Button(app.name) { addExcluded(app.bundleId) } }
                        Divider()
                        Button("Choose Application…") { if let app = AppIcons.chooseApp() { addExcluded(app.bundleId) } }
                    } label: { Label("Add App", systemImage: "plus") }
                    .fixedSize()
                }
                .padding(.vertical, 4)
            } header: { Text("Scrolling") } footer: {
                Text("Applies to discrete mouse wheels only. Trackpads and the Magic Mouse surface keep the system's own direction and speed, so you can have “natural” scrolling on the trackpad and classic scrolling on a mouse at the same time. Excluded apps are matched by the window under the pointer, not the frontmost app.").formFooter()
            }

            Section {
                Toggle("Reverse scrolling direction", isOn: $store.config.mouse.iPhoneMirroringReverse)
                LabeledContent("Scroll speed") {
                    HStack {
                        Slider(value: $store.config.mouse.iPhoneMirroringSpeed, in: 0.25...4, step: 0.25)
                        Text(String(format: "%.2f×", store.config.mouse.iPhoneMirroringSpeed)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            } header: { Text("iPhone Mirroring") } footer: {
                Text("iPhone Mirroring ignores the scrolling settings above, so it has its own. They apply to the mouse wheel while the pointer is over the iPhone Mirroring window. With reversing off and speed at 1×, the wheel is passed through unchanged (macOS's own direction and speed).").formFooter()
            }

            Section {
                Toggle("Custom pointer speed", isOn: $store.config.mouse.pointerSpeedEnabled)
                LabeledContent("Pointer speed") {
                    HStack {
                        Slider(value: $store.config.mouse.pointerSpeed, in: 0.25...4, step: 0.05)
                        Text(String(format: "%.2f×", store.config.mouse.pointerSpeed)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!store.config.mouse.pointerSpeedEnabled)
                Picker("Acceleration", selection: $store.config.mouse.acceleration) {
                    ForEach(AccelerationMode.allCases) { Text($0.title).tag($0) }
                }
                if store.config.mouse.acceleration == .custom {
                    LabeledContent("Acceleration curve") {
                        HStack {
                            Slider(value: $store.config.mouse.accelerationValue, in: 0...3, step: 0.0625)
                            Text(String(format: "%.3f", store.config.mouse.accelerationValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                if devices.isEmpty {
                    Label("No external mouse detected.", systemImage: "computermouse").foregroundStyle(.secondary)
                } else {
                    ForEach(devices) { d in
                        HStack {
                            Image(systemName: "computermouse.fill").foregroundStyle(.secondary)
                            Text(d.name)
                            Spacer()
                            Text(status(d)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Pointer") } footer: {
                Text("Speed changes the HID pointer resolution of each mouse (1.00× = the system's 400 dpi); it is the “DPI” knob when the mouse has no software of its own. Values are re-applied when a mouse reconnects and restored when ConfigBox quits. The system's own tracking-speed slider still applies on top.").formFooter()
            }

            Section {
                Toggle("Buttons 4 / 5 go back / forward (⌘[ / ⌘])", isOn: $store.config.mouse.backForwardButtons)
            } header: { Text("Buttons") } footer: {
                Text("For anything else (remapping a button to another key, double-click actions, button gestures) use the Triggers tab.").formFooter()
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = PointerSettings.shared.devices() }
        .onReceive(timer) { _ in devices = PointerSettings.shared.devices() }
    }

    private func addExcluded(_ id: String) {
        if !store.config.mouse.scrollExcludedApps.contains(id) { store.config.mouse.scrollExcludedApps.append(id) }
    }

    private func status(_ d: PointerSettings.DeviceState) -> String {
        var parts: [String] = []
        if let r = d.resolutionDPI { parts.append(String(format: "%.0f dpi", r)) }
        if let a = d.acceleration { parts.append(a < 0 ? "accel off" : String(format: "accel %.3f", a)) }
        return parts.joined(separator: " · ")
    }
}
