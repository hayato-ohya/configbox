import SwiftUI

/// Karabiner-VirtualHIDDevice-Manager equivalent for ConfigBox's HID-level remapping layer.
struct HIDManagerView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var status: [HIDUtil.DeviceStatus] = []
    @State private var loading = false
    @State private var agentInstalled = HIDUtil.launchAgentInstalled

    private var configured: Int {
        store.config.simpleModifications.filter(\.enabled).count +
        store.config.complexRules.filter { $0.enabled && ($0.from == KeyCodes.capsLock || $0.device != nil) }.count
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
                Text("“Activate” installs the simple modifications (and the Caps Lock → F18 route used by Mod-Tap keys) into the HID event system. “Deactivate” removes exactly what ConfigBox installed.")
            }

            Section {
                if loading {
                    ProgressView().controlSize(.small)
                } else if status.isEmpty {
                    Text("Press Refresh to read the current state.").foregroundStyle(.secondary)
                } else {
                    ForEach(status) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.device.map { "\($0.name)  (\(String(format: "0x%04X / 0x%04X", $0.vendorId, $0.productId)))" } ?? "All keyboards (global)")
                                .font(.callout.weight(.medium))
                            if s.mappings.isEmpty {
                                Text("no UserKeyMapping").font(.caption).foregroundStyle(.secondary)
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

            Section("Why hidutil instead of a virtual HID driver") {
                Text("Karabiner-Elements ships a DriverKit virtual keyboard (Karabiner-VirtualHIDDevice) that needs a DriverKit entitlement issued by Apple and a notarized system extension. ConfigBox deliberately avoids installing kernel-adjacent code: simple key-to-key mappings go through Apple's own HID remapping property (the same path System Settings uses for modifier keys), per keyboard if you want, while anything needing logic (Mod-Tap keys, shortcuts) runs in a user-space event tap. The trade-off: remaps cannot create new virtual keys that the HID system does not know, and secure input fields receive the HID-level remaps but not the event-tap ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func activate() {
        let cfg = store.config
        InputRouter.shared.remapper.apply(simple: cfg.simpleModifications, complex: cfg.complexRules)
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
