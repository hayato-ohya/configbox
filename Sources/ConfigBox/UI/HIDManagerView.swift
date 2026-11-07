import SwiftUI

/// Karabiner-VirtualHIDDevice-Manager equivalent for ConfigBox's HID-level remapping layer.
struct HIDManagerView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var status: [HIDUtil.DeviceStatus] = []
    @State private var loading = false
    @State private var agentInstalled = HIDUtil.launchAgentInstalled

    private var configured: Int {
        func routed(_ code: UInt16, _ device: DeviceRef?) -> Bool {
            device != nil || code == KeyCodes.capsLock || KeyCodes.hidOnly.contains(code)
        }
        let c = store.config
        return c.simpleModifications.filter(\.enabled).count
            + c.complexRules.filter { $0.enabled && routed($0.from, $0.device) }.count
            + c.keyActionRules.filter { $0.enabled && !$0.from.isUnset && routed($0.from.keyCode, $0.device) }.count
            - InputRouter.shared.remapper.unroutable.count
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: HIDUtil.isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(HIDUtil.isActive ? Color.green : Color.secondary).font(.title2)
                    VStack(alignment: .leading) {
                        Text(HIDUtil.isActive ? "HID remapping layer active" : "HID remapping layer inactive")
                        Text("\(configured) mapping\(configured == 1 ? "" : "s") configured in ConfigBox").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Activate") { activate() }
                    Button("Deactivate") { HIDUtil.clear(); refresh() }.disabled(!HIDUtil.isActive)
                }
            } header: { Text("Status") } footer: {
                Text("“Activate” installs the simple modifications and the F-key routes used by Key → Actions and Mod-Tap rules into the HID event system. “Deactivate” removes exactly what ConfigBox installed.")
            }

            Section {
                if loading {
                    ProgressView().controlSize(.small)
                } else if status.isEmpty {
                    Text("Press Refresh to read the current state.").foregroundStyle(.secondary)
                } else {
                    ForEach(status) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.device.map { "\($0.name)  (\(String(format: "0x%04X / 0x%04X", $0.vendorId, $0.productId)))" } ?? L("All keyboards (global)"))
                                .font(.callout.weight(.medium))
                            if s.mappings.isEmpty {
                                Text(s.device == nil ? "No mappings" : "No device-specific mappings").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(s.mappings.enumerated()), id: \.offset) { _, m in
                                    Text(m.display).font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack {
                    Button("Refresh") { refresh() }
                    Spacer()
                    Button("Remove all HID mappings (including other tools’)", role: .destructive) {
                        HIDUtil.clearEverything(); refresh()
                    }
                }
            } header: { Text("Installed in the system (hidutil UserKeyMapping)") }

            Section {
                Toggle("Keep mappings active at login, even when ConfigBox is not running", isOn: Binding(
                    get: { store.config.general.keepHIDMappingsAtLogin },
                    set: { on in
                        store.config.general.keepHIDMappingsAtLogin = on
                        if on { HIDUtil.writeLaunchAgent() } else { HIDUtil.removeLaunchAgent() }
                        agentInstalled = HIDUtil.launchAgentInstalled
                    }))
                LabeledContent("LaunchAgent") {
                    Text(agentInstalled ? "Installed" : "Not installed").foregroundStyle(.secondary)
                }
                if agentInstalled {
                    Text(HIDUtil.launchAgentURL.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } header: { Text("Persistence") } footer: {
                Text("A LaunchAgent re-applies the same hidutil mappings at login. Without it, macOS forgets UserKeyMapping on logout and ConfigBox re-applies it at launch.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func activate() {
        InputRouter.shared.apply(config: store.config)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
    }

    private func refresh() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let s = HIDUtil.currentStatus()
            DispatchQueue.main.async { status = s; loading = false; agentInstalled = HIDUtil.launchAgentInstalled }
        }
    }
}
