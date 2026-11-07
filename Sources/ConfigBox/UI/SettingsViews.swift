import SwiftUI
import AppKit
import Combine

struct SwitcherSettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var screenRecording = Permissions.screenRecording
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Enable window switcher", isOn: $store.config.switcher.enabled)
                LabeledContent("Shortcut") {
                    KeyRecorder(combo: $store.config.switcher.shortcut, allowClear: false)
                }
                Text("Hold the modifier(s) and press the key to cycle windows; release the modifier to switch. Add ⇧ to go backwards. At least one modifier is required.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Stay open after releasing") {
                    HStack {
                        Slider(value: Binding(get: { Double(store.config.switcher.releaseDelayMs) },
                                              set: { store.config.switcher.releaseDelayMs = Int($0) }), in: 0...2000, step: 50)
                        TextField("", value: $store.config.switcher.releaseDelayMs, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
                Text(store.config.switcher.releaseDelayMs == 0
                     ? "0 ms: the switch happens the moment the modifier is released."
                     : "After you let go of the modifier the switcher stays open for \(store.config.switcher.releaseDelayMs) ms. In that time ⌥Tab or Tab moves forward, ⇧Tab backward, each press restarting the timer; Return switches at once, Esc cancels, and typing anything else switches and passes the key to the new window.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Activation") }

            Section("Windows") {
                Toggle("Show minimized windows", isOn: $store.config.switcher.showMinimized)
                Toggle("Show windows of hidden apps", isOn: $store.config.switcher.showHidden)
                Toggle("Only windows of the current app", isOn: $store.config.switcher.currentAppOnly)
            }

            Section {
                Toggle("Show window thumbnails", isOn: $store.config.switcher.showThumbnails)
                Toggle("Show window titles", isOn: $store.config.switcher.showTitles)
                LabeledContent("Thumbnail height") {
                    HStack {
                        Slider(value: $store.config.switcher.thumbnailHeight, in: 80...260, step: 10)
                        Text("\(Int(store.config.switcher.thumbnailHeight)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                if store.config.switcher.showThumbnails && !screenRecording {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Thumbnails need the Screen Recording permission. App icons are shown until it is granted.")
                            .font(.caption)
                        Spacer()
                        Button("Grant…") { Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings() }
                    }
                }
            } header: { Text("Appearance") }

            Section("Keys While Open") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow { key("Tab / → / ↓"); Text("Next window") }
                    GridRow { key("⇧Tab / ← / ↑"); Text("Previous window") }
                    GridRow { key("Return"); Text("Switch to selected") }
                    GridRow { key("Esc"); Text("Cancel") }
                    GridRow { key("W"); Text("Close window") }
                    GridRow { key("M"); Text("Minimize window") }
                    GridRow { key("H"); Text("Hide app") }
                    GridRow { key("Q"); Text("Quit app") }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in screenRecording = Permissions.screenRecording }
    }

    private func key(_ s: String) -> some View {
        Text(s).font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    @State private var inputMonitoring = Permissions.inputMonitoring
    @State private var launchAtLogin = Permissions.launchAtLogin
    @State private var language = AppLanguage.current
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permissionRow("Accessibility", granted: accessibility,
                              detail: "Required for key remapping, shortcuts and the window switcher.") {
                    Permissions.requestAccessibility(); Permissions.openAccessibilitySettings()
                }
                permissionRow("Screen Recording", granted: screenRecording,
                              detail: "Optional. Only used for window thumbnails in the switcher.") {
                    Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings()
                }
                permissionRow("Input Monitoring", granted: inputMonitoring,
                              detail: "Optional. Only needed for Simultaneous Keys rules limited to one keyboard.") {
                    Permissions.requestInputMonitoring()
                }
                if !accessibility || !screenRecording || !inputMonitoring {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already enabled in System Settings but still shown as missing? The grant belongs to a previous build signature. Remove the stale entry and grant again:")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if !accessibility { Button("Reset Accessibility entry…") { Permissions.resetAndRequest(service: "Accessibility") } }
                                if !screenRecording { Button("Reset Screen Recording entry…") { Permissions.resetAndRequest(service: "ScreenCapture") } }
                                if !inputMonitoring { Button("Reset Input Monitoring entry…") { Permissions.resetAndRequest(service: "ListenEvent") } }
                            }
                        }
                    }
                }
            } header: { Text("Permissions") } footer: {
                Text("After granting Accessibility for the first time, macOS may require relaunching ConfigBox. Grants are tied to the code signature; the build script signs with a persistent identity so rebuilds keep them.")
            }

            Section("General") {
                Picker("Language", selection: $language) {
                    Text("System default").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.en)
                    Text(verbatim: "日本語").tag(AppLanguage.ja)
                }
                .onChange(of: language) { _, new in AppLanguage.current = new }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("Relaunch ConfigBox to apply the new language.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now") { AppLanguage.relaunch() }
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { Permissions.launchAtLogin = $0; launchAtLogin = Permissions.launchAtLogin }))
                Toggle("Show menu bar icon", isOn: $store.config.general.showMenuBarIcon)
                Toggle("Keyboard shortcuts & remapping", isOn: $store.config.general.keyboardEnabled)
                Toggle("Type on JIS keyboards as ANSI (US)", isOn: $store.config.general.treatJISAsANSI)
                    .disabled(!store.config.general.keyboardEnabled)
                    .help("Keys on JIS keyboards produce the characters of a US layout, e.g. Shift+2 types @. Only works while ConfigBox is running.")
                Toggle("Trackpad gestures", isOn: $store.config.general.trackpadEnabled)
                Toggle("Mouse triggers", isOn: $store.config.general.mouseEnabled)
                if !TrackpadEngine.shared.isAvailable {
                    Label("Multitouch framework not available on this system.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Tools") {
                HStack {
                    Button { MainWindowController.shared.show(.eventViewer) } label: { Label("Event Viewer", systemImage: "waveform.path.ecg") }
                    Button { MainWindowController.shared.show(.hidManager) } label: { Label("HID Device Manager", systemImage: "keyboard.badge.ellipsis") }
                }
                Text("Event Viewer shows live key codes, gestures, the frontmost app and HID devices. HID Device Manager controls the system-level remapping layer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Configuration File") {
                LabeledContent("Path") {
                    Text(store.fileURL.path).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                    Button("Reload") { store.load() }
                    Button("Reset to Sample", role: .destructive) { store.config = .sample }
                }
                HStack {
                    Button("Save Settings…") { ConfigBackup.save(store) }
                    Button("Restore Settings…") { ConfigBackup.restore(store) }
                }
                Text("Saves all rules and settings to a file. The language and Launch at login are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                Text("ConfigBox combines trackpad gestures, keyboard shortcuts, key remapping and a window switcher in one dependency-free native app. The settings window is released from memory when closed; only the event tap and (if used) the multitouch listener stay resident.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
            inputMonitoring = Permissions.inputMonitoring
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                Text(L(detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}
