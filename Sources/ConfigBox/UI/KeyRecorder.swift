import SwiftUI
import AppKit

/// Click, then press a key combination. Uses a local event monitor; the global tap is bypassed while recording.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    var allowClear = true
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : combo.displayOrUnset)
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.red : (combo.isUnset ? Color.secondary : Color.primary))
            }
            .buttonStyle(.bordered)
            .help(recording ? "Press a key, a combination, or a modifier alone (Windows/⌘, Alt/⌥, …). Esc cancels." : "Click to record")
            if allowClear && !combo.isUnset && !recording {
                ClearButton { combo = .unset }
            }
        }
        .onDisappear { stop() }
    }

    @State private var pendingModifier: UInt16?

    private func start() {
        recording = true
        pendingModifier = nil
        InputRouter.shared.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let flags = e.cgEvent?.flags ?? []
            if e.type == .flagsChanged {
                // A modifier pressed and released on its own (Windows / ⌘, Alt / ⌥, Caps Lock …) is a key too.
                let code = e.keyCode
                let isDown = flags.contains(KeyCodes.modifierFlag(for: code))
                if isDown { pendingModifier = code }
                else if pendingModifier == code {
                    combo = KeyCombo(keyCode: code, modifiers: [])
                    stop()
                }
                return nil
            }
            pendingModifier = nil
            let mods = KeyCodes.modifiers(for: e.keyCode, flags: flags)
            combo = KeyCombo(keyCode: e.keyCode, modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        InputRouter.shared.recording = false
    }
}

struct KeyPicker: View {
    @Binding var code: UInt16
    var body: some View {
        Picker("", selection: $code) {
            ForEach(KeyCodes.pickable) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
    }
}


/// Record a combo, or pick the key from the list and toggle modifiers. Both edit the same value.
struct KeyComboEditor: View {
    @Binding var combo: KeyCombo
    var allowClear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KeyRecorder(combo: $combo, allowClear: allowClear)
                Text("or").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { combo.isUnset ? UInt16.max : combo.keyCode },
                                              set: { combo = KeyCombo(keyCode: $0, modifiers: combo.modifiers) })) {
                    if combo.isUnset { Text("Choose key…").tag(UInt16.max) }
                    ForEach(KeyCodes.pickable) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().frame(width: 150)
            }
            HStack(spacing: 6) {
                Text("Modifiers").font(.caption).foregroundStyle(.secondary)
                modToggle("⌃", .control); modToggle("⌥", .option); modToggle("⇧", .shift); modToggle("⌘", .command); modToggle("fn", .function)
            }
        }
    }

    private func modToggle(_ t: String, _ m: Modifiers) -> some View {
        Toggle(t, isOn: Binding(get: { combo.modifiers.contains(m) }, set: { on in
            var c = combo
            if on { c.modifiers.insert(m) } else { c.modifiers.remove(m) }
            combo = c
        }))
        .toggleStyle(.button).controlSize(.small)
        .disabled(combo.isUnset)
    }
}


/// Small round “clear” button with a comfortable hit area.
struct ClearButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Clear")
    }
}

/// Borderless icon button with a generous hit area (used for − / ↑ / ↓ / trash in rows).
struct IconButton: View {
    let systemName: String
    var role: ButtonRole? = nil
    var help: String = ""
    var action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
