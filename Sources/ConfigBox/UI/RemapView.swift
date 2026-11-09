import SwiftUI
import AppKit
import Combine

enum RemapCategory: String, CaseIterable, Identifiable {
    case simple, macro, chord, modTap
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simple: L("Simple Modifications")
        case .macro: L("Key → Actions")
        case .chord: L("Simultaneous Keys")
        case .modTap: L("Mod-Tap Keys")
        }
    }
    var symbol: String {
        switch self {
        case .simple: "arrow.right"
        case .macro: "list.number"
        case .chord: "rectangle.2.swap"
        case .modTap: "hand.tap"
        }
    }
    var blurb: String {
        switch self {
        case .simple: L("One key becomes another, at the HID level (zero cost, works everywhere, per keyboard if you like).")
        case .macro: L("One key (with or without modifiers) runs a sequence of actions: other shortcuts, text, apps, window tiling…")
        case .chord: L("Two or three keys pressed together run an action; pressed alone they type normally.")
        case .modTap: L("Tap for a key or an action sequence, hold for modifiers (QMK Mod-Tap / Karabiner to_if_alone).")
        }
    }
}

/// Key Remapping: categories · rules · editor, in the same three-pane layout as the trigger tabs.
struct RemapView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var state: UIState
    @State private var keyboards: [HIDDeviceInfo] = []
    @State private var karabiner = false
    @State private var unroutable: [String] = []

    var body: some View {
        HSplitView {
            RemapSidebar(state: state)
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 300, maxHeight: .infinity)
            RemapRuleList(state: state, keyboards: keyboards, karabiner: karabiner, unroutable: unroutable)
                .frame(minWidth: 300, idealWidth: 380, maxHeight: .infinity)
            RemapEditorContainer(state: state, keyboards: keyboards)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshDevices)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refreshDevices() }
    }

    /// Polled while this tab is on screen, so plugging a keyboard in or out shows up without reopening it.
    private func refreshDevices() {
        let now = HIDDevices.keyboards()
        if now != keyboards { keyboards = now }
        store.rememberKeyboards(now.map(\.ref))
        let active = HIDDevices.karabinerActive
        if active != karabiner { karabiner = active }
        let failed = InputRouter.shared.remapper.unroutable
        if failed != unroutable { unroutable = failed }
    }
}

// MARK: - Sidebar

private struct RemapSidebar: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var state: UIState

    private func count(_ c: RemapCategory) -> Int {
        switch c {
        case .simple: store.config.simpleModifications.count
        case .macro: store.config.keyActionRules.count
        case .chord: store.config.chordRules.count
        case .modTap: store.config.complexRules.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.remapCategory) {
                ForEach(RemapCategory.allCases) { c in
                    HStack {
                        Label(c.title, systemImage: c.symbol)
                        Spacer()
                        if count(c) > 0 {
                            Text("\(count(c))").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    .tag(c)
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button { MainWindowController.shared.show(.hidManager) } label: { Label("HID Device Manager…", systemImage: "keyboard.badge.ellipsis") }
                Button { MainWindowController.shared.show(.eventViewer) } label: { Label("Event Viewer…", systemImage: "waveform.path.ecg") }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(10)
        }
    }
}

// MARK: - Rule list

private struct RemapRuleList: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var state: UIState
    let keyboards: [HIDDeviceInfo]
    let karabiner: Bool
    let unroutable: [String]

    private var category: RemapCategory { state.remapCategory }

    private var hasDeviceRules: Bool {
        store.config.simpleModifications.contains { $0.enabled && $0.device != nil } ||
        store.config.complexRules.contains { $0.enabled && $0.device != nil } ||
        store.config.keyActionRules.contains { $0.enabled && $0.device != nil } ||
        store.config.chordRules.contains { $0.enabled && $0.device != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if karabiner && hasDeviceRules {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Karabiner-Elements is active: device-specific rules cannot see keys from the keyboards it manages. Untick them in Karabiner › Devices, or quit Karabiner.")
                        .font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
            if !unroutable.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Not working: \(unroutable.joined(separator: ", ")). Device-limited Key → Actions and Mod-Tap rules can use at most 10 routing keys. Set some of them to All keyboards, or turn others off.")
                        .font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
            List(selection: $state.selectedRemapID) {
                switch category {
                case .simple:
                    ForEach(store.config.simpleModifications) { m in
                        RuleRow(icon: category.symbol,
                                title: "\(KeyCodes.name(for: m.from))  →  \(KeyCodes.name(for: m.to))",
                                subtitle: m.device?.name ?? L("All keyboards"),
                                enabled: Binding(get: { m.enabled }, set: { v in set(\.simpleModifications, m.id) { $0.enabled = v } }))
                            .tag(m.id)
                            .contextMenu { menu(\.simpleModifications, m.id) }
                    }
                    .onMove { store.config.simpleModifications.move(fromOffsets: $0, toOffset: $1) }
                case .macro:
                    ForEach(store.config.keyActionRules) { r in
                        RuleRow(icon: category.symbol,
                                title: r.from.isUnset ? L("Not set") : r.from.display,
                                subtitle: [r.actions.map(\.display).joined(separator: " → "), r.device?.name].compactMap { $0 }.joined(separator: " · "),
                                name: r.name,
                                enabled: Binding(get: { r.enabled }, set: { v in set(\.keyActionRules, r.id) { $0.enabled = v } }))
                            .tag(r.id)
                            .contextMenu { menu(\.keyActionRules, r.id) }
                    }
                    .onMove { store.config.keyActionRules.move(fromOffsets: $0, toOffset: $1) }
                case .chord:
                    ForEach(store.config.chordRules) { r in
                        RuleRow(icon: category.symbol,
                                title: r.keysDisplay,
                                subtitle: [r.action.display, r.device?.name].compactMap { $0 }.joined(separator: " · "),
                                name: r.name,
                                enabled: Binding(get: { r.enabled }, set: { v in set(\.chordRules, r.id) { $0.enabled = v } }))
                            .tag(r.id)
                            .contextMenu { menu(\.chordRules, r.id) }
                    }
                    .onMove { store.config.chordRules.move(fromOffsets: $0, toOffset: $1) }
                case .modTap:
                    ForEach(store.config.complexRules) { r in
                        RuleRow(icon: category.symbol,
                                title: KeyCodes.name(for: r.from),
                                subtitle: modTapSummary(r),
                                name: r.name,
                                enabled: Binding(get: { r.enabled }, set: { v in set(\.complexRules, r.id) { $0.enabled = v } }))
                            .tag(r.id)
                            .contextMenu { menu(\.complexRules, r.id) }
                    }
                    .onMove { store.config.complexRules.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.inset)
            .overlay {
                if isEmpty {
                    ContentUnavailableView(category.title, systemImage: category.symbol, description: Text(category.blurb + "\n\n" + L("Click + to add a rule.")))
                }
            }
            Divider()
            HStack(spacing: 4) {
                IconButton(systemName: "plus", help: "Add") { add() }
                IconButton(systemName: "minus", help: "Remove selected") { remove() }.disabled(state.selectedRemapID == nil)
                if category == .simple {
                    Menu {
                        Section("JIS keyboard as US (ANSI)") {
                            Button("¥ → ` ~  and  _ (ろ) → \\ |") { addPreset(jisAsUS: true) }
                            Button("Also 英数 → Left ⌘, かな → Right ⌘") { addPreset(jisAsUS: true, commandKeys: true) }
                        }
                        Section("Windows keyboard on a Mac") {
                            Button("無変換 → 英数, 変換 → かな") {
                                addSimple(from: KeyCodes.muhenkan, to: 102)
                                addSimple(from: KeyCodes.henkan, to: 104)
                            }
                        }
                        Section("Common") {
                            Button("Caps Lock → Escape") { addSimple(from: KeyCodes.capsLock, to: 53) }
                            Button("Caps Lock → Left ⌃") { addSimple(from: KeyCodes.capsLock, to: 59) }
                            Button("Right ⌘ → Right ⌥") { addSimple(from: 54, to: 61) }
                        }
                    } label: { Label("Presets", systemImage: "wand.and.stars") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add commonly used mappings (you can set a keyboard for each afterwards)")
                }
                Spacer()
                Text("\(total) rule\(total == 1 ? "" : "s") · drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func modTapSummary(_ r: ComplexRule) -> String {
        var parts: [String] = []
        if !r.tapActions.isEmpty { parts.append(L("Tap: %@", r.tapActions.map(\.display).joined(separator: " → "))) }
        else if let k = r.aloneKey { parts.append(L("Tap: %@", k.display)) }
        if !r.heldModifiers.isEmpty { parts.append(L("Hold: %@", r.heldModifiers.symbols)) }
        if let d = r.device { parts.append(d.name) }
        return parts.joined(separator: " · ")
    }

    private var total: Int {
        switch category {
        case .simple: store.config.simpleModifications.count
        case .macro: store.config.keyActionRules.count
        case .chord: store.config.chordRules.count
        case .modTap: store.config.complexRules.count
        }
    }
    private var isEmpty: Bool { total == 0 }

    private func set<T: Identifiable>(_ kp: WritableKeyPath<Config, [T]>, _ id: T.ID, _ f: (inout T) -> Void) {
        if let i = store.config[keyPath: kp].firstIndex(where: { $0.id == id }) { f(&store.config[keyPath: kp][i]) }
    }

    @ViewBuilder
    private func menu<T: Identifiable & Hashable>(_ kp: WritableKeyPath<Config, [T]>, _ id: T.ID) -> some View {
        let arr = store.config[keyPath: kp]
        let i = arr.firstIndex { $0.id == id } ?? 0
        Button("Move to Top") { move(kp, i, 0) }.disabled(i == 0)
        Button("Move Up") { move(kp, i, i - 1) }.disabled(i == 0)
        Button("Move Down") { move(kp, i, i + 1) }.disabled(i >= arr.count - 1)
        Button("Move to Bottom") { move(kp, i, arr.count - 1) }.disabled(i >= arr.count - 1)
        Divider()
        Button("Delete", role: .destructive) { store.config[keyPath: kp].removeAll { $0.id == id }; if state.selectedRemapID as? T.ID == id { state.selectedRemapID = nil } }
    }

    private func move<T>(_ kp: WritableKeyPath<Config, [T]>, _ from: Int, _ to: Int) {
        var arr = store.config[keyPath: kp]
        guard arr.indices.contains(from), arr.indices.contains(to) else { return }
        let item = arr.remove(at: from); arr.insert(item, at: to)
        store.config[keyPath: kp] = arr
    }

    private func add() {
        switch category {
        case .simple:
            let m = SimpleModification(from: KeyCodes.capsLock, to: 53); store.config.simpleModifications.append(m); state.selectedRemapID = m.id
        case .macro:
            let r = KeyActionRule(); store.config.keyActionRules.append(r); state.selectedRemapID = r.id
        case .chord:
            let r = ChordRule(); store.config.chordRules.append(r); state.selectedRemapID = r.id
        case .modTap:
            let r = ComplexRule(from: KeyCodes.capsLock, aloneKey: KeyCombo(keyCode: 53), heldModifiers: [.control]); store.config.complexRules.append(r); state.selectedRemapID = r.id
        }
    }

    private func addSimple(from: UInt16, to: UInt16) {
        guard !store.config.simpleModifications.contains(where: { $0.from == from && $0.to == to && $0.device == nil }) else { return }
        let m = SimpleModification(from: from, to: to)
        store.config.simpleModifications.append(m)
        state.selectedRemapID = m.id
    }

    /// JIS keyboards used with a U.S. layout: give the leftover JIS keys the ANSI keys they are missing.
    private func addPreset(jisAsUS: Bool, commandKeys: Bool = false) {
        addSimple(from: 93, to: 50)        // ¥ (international3) → ` ~
        addSimple(from: 94, to: 42)        // _ ろ (international1) → \ |
        if commandKeys {
            addSimple(from: 102, to: 55)   // 英数 → Left ⌘
            addSimple(from: 104, to: 54)   // かな → Right ⌘
        }
    }

    private func remove() {
        guard let id = state.selectedRemapID else { return }
        store.config.simpleModifications.removeAll { $0.id == id }
        store.config.keyActionRules.removeAll { $0.id == id }
        store.config.chordRules.removeAll { $0.id == id }
        store.config.complexRules.removeAll { $0.id == id }
        state.selectedRemapID = nil
    }
}

private struct RuleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var name: String = ""
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(name.isEmpty ? subtitle : (subtitle.isEmpty ? name : "\(name) · \(subtitle)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.vertical, 3)
        .opacity(enabled ? 1 : 0.55)
    }
}

// MARK: - Editors

private struct RemapEditorContainer: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var state: UIState
    let keyboards: [HIDDeviceInfo]

    var body: some View {
        if let id = state.selectedRemapID {
            if let m = store.config.simpleModifications.first(where: { $0.id == id }) {
                SimpleEditor(rule: store.binding(\.simpleModifications, id: id, fallback: m), keyboards: keyboards).id(id)
            } else if let r = store.config.keyActionRules.first(where: { $0.id == id }) {
                MacroEditor(rule: store.binding(\.keyActionRules, id: id, fallback: r), keyboards: keyboards).id(id)
            } else if let r = store.config.chordRules.first(where: { $0.id == id }) {
                ChordEditor(rule: store.binding(\.chordRules, id: id, fallback: r), keyboards: keyboards).id(id)
            } else if let r = store.config.complexRules.first(where: { $0.id == id }) {
                ModTapEditor(rule: store.binding(\.complexRules, id: id, fallback: r), keyboards: keyboards).id(id)
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Select a Rule", systemImage: state.remapCategory.symbol,
                               description: Text(state.remapCategory.blurb))
    }
}

private struct DeviceRow: View {
    @Binding var device: DeviceRef?
    let keyboards: [HIDDeviceInfo]
    var note: String = "Other keyboards keep the key unchanged."
    var body: some View {
        LabeledContent("Keyboard") { DevicePicker(device: $device, keyboards: keyboards).frame(maxWidth: 260) }
        if device != nil { Text(L(note)).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct SimpleEditor: View {
    @Binding var rule: SimpleModification
    let keyboards: [HIDDeviceInfo]
    var body: some View {
        Form {
            Section("Mapping") {
                LabeledContent("From") { KeyPicker(code: $rule.from, asSource: true).frame(maxWidth: 220) }
                LabeledContent("To") { KeyPicker(code: $rule.to).frame(maxWidth: 220) }
                Toggle("Enabled", isOn: $rule.enabled)
            }
            Section {
                DeviceRow(device: $rule.device, keyboards: keyboards)
            } footer: {
                Text("Applied through hidutil at the HID level, exactly like System Settings' modifier-key mapping: no runtime cost and it even works in secure input fields.").formFooter()
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacroEditor: View {
    @Binding var rule: KeyActionRule
    let keyboards: [HIDDeviceInfo]
    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name (optional)", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
            }
            Section("When pressed") {
                KeyComboEditor(combo: $rule.from, asSource: true)
                DeviceRow(device: $rule.device, keyboards: keyboards)
                Toggle("Repeat while the key is held", isOn: $rule.repeats)
            }
            Section("Actions, in order") {
                ActionSequenceEditor(actions: $rule.actions, minimum: 1)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ChordEditor: View {
    @Binding var rule: ChordRule
    let keyboards: [HIDDeviceInfo]
    @State private var inputMonitoring = KeyDeviceTracker.hasPermission
    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name (optional)", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
            }
            Section {
                LabeledContent("Keys") { ChordRecorder(keys: $rule.keys) }
                Stepper(value: $rule.thresholdMs, in: 20...300, step: 10) {
                    LabeledContent("Threshold", value: "\(rule.thresholdMs) ms")
                }
                DeviceRow(device: $rule.device, keyboards: keyboards, note: inputMonitoring
                          ? L("Only fires when every key came from this keyboard.")
                          : L("Needs the Input Monitoring permission to tell keyboards apart (Settings › Permissions)."))
            } header: { Text("Simultaneous keys") } footer: {
                Text("Keys that could start a chord are held back for the threshold; if the chord is not completed they are delivered unchanged, in order.").formFooter()
            }
            Section("Action") {
                ActionEditor(action: $rule.action)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in inputMonitoring = KeyDeviceTracker.hasPermission }
    }
}

private struct ModTapEditor: View {
    @Binding var rule: ComplexRule
    let keyboards: [HIDDeviceInfo]
    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name (optional)", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
            }
            Section("Key") {
                LabeledContent("Key") { KeyPicker(code: $rule.from, asSource: true).frame(maxWidth: 220) }
                DeviceRow(device: $rule.device, keyboards: keyboards)
            }
            Section("Tap") {
                Picker("On tap", selection: Binding(get: { rule.tapActions.isEmpty ? 0 : 1 }, set: { mode in
                    if mode == 1 { if rule.tapActions.isEmpty { rule.tapActions = [.typeText("")] } } else { rule.tapActions = [] }
                })) {
                    Text("Send a key").tag(0)
                    Text("Run actions").tag(1)
                }
                .pickerStyle(.segmented)
                if rule.tapActions.isEmpty {
                    KeyComboEditor(combo: Binding(get: { rule.aloneKey ?? .unset }, set: { rule.aloneKey = $0.isUnset ? nil : $0 }))
                } else {
                    ActionSequenceEditor(actions: $rule.tapActions, minimum: 1)
                }
            }
            Section {
                LabeledContent("Acts as") {
                    HStack(spacing: 6) {
                        modToggle("⌃ Control", .control); modToggle("⌥ Option", .option); modToggle("⇧ Shift", .shift); modToggle("⌘ Command", .command)
                    }
                }
                Stepper(value: $rule.aloneTimeoutMs, in: 100...1000, step: 50) {
                    LabeledContent("Tapping term", value: "\(rule.aloneTimeoutMs) ms")
                }
            } header: { Text("Hold") } footer: {
                Text("Tapping term is the longest hold still counted as a tap. Caps Lock and device-limited keys are rerouted through a spare F-key (F13–F20) at the HID level.").formFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func modToggle(_ title: String, _ m: Modifiers) -> some View {
        Toggle(title, isOn: Binding(get: { rule.heldModifiers.contains(m) },
                                    set: { on in if on { rule.heldModifiers.insert(m) } else { rule.heldModifiers.remove(m) } }))
            .toggleStyle(.button).controlSize(.small)
    }
}
