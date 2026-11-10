import SwiftUI
import AppKit

/// Click, then press a key combination. Uses a local event monitor; the global tap is bypassed while recording.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    var allowClear = true
    /// Only accept a key pressed with a modifier other than ⇧ (the window switcher needs one).
    var requireModifier = false
    @State private var recording = false
    @State private var monitor: Any?
    @State private var gate: RecordingGate?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L("Press keys…") : combo.displayOrUnset)
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.red : (combo.isUnset ? Color.secondary : Color.primary))
            }
            .buttonStyle(.bordered)
            .help(recording ? (requireModifier ? L("Press a key together with ⌘, ⌥ or ⌃. Esc cancels.") : L("Press a key, a combination, or a modifier alone (Windows/⌘, Alt/⌥, …). Esc cancels.")) : L("Click to record"))
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
        gate = RecordingGate { stop() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let flags = e.cgEvent?.flags ?? []
            if e.type == .flagsChanged {
                // A modifier pressed and released on its own (Windows / ⌘, Alt / ⌥, Caps Lock …) is a key too.
                let code = e.keyCode
                let isDown = flags.contains(KeyCodes.modifierFlag(for: code))
                if isDown { pendingModifier = code }
                else if pendingModifier == code {
                    pendingModifier = nil
                    if !requireModifier {
                        combo = KeyCombo(keyCode: code, modifiers: [])
                        stop()
                    }
                }
                return nil
            }
            pendingModifier = nil
            let mods = KeyCodes.modifiers(for: e.keyCode, flags: flags)
            if e.keyCode == 53 && mods.isEmpty { stop(); return nil }
            // Shift alone can't hold a switcher-style shortcut (it means "backwards"); keep waiting.
            if requireModifier && mods.subtracting(.shift).isEmpty { return nil }
            // ⇧ is not part of a switcher-style shortcut: holding it while switching means "backwards".
            combo = KeyCombo(keyCode: e.keyCode, modifiers: requireModifier ? mods.subtracting(.shift) : mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        gate?.end()
        gate = nil
    }
}

/// Bypasses the engines (`InputRouter.recording`) while at least one recorder is active, and cancels
/// a recording when the app or its window loses focus so rules are never left switched off.
/// `end()` is idempotent, so a recorder stopped twice does not release another recorder's hold.
final class RecordingGate {
    private static var count = 0
    private var observers: [NSObjectProtocol] = []
    private var ended = false

    init(onCancel: @escaping () -> Void) {
        Self.count += 1
        InputRouter.shared.recording = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in onCancel() })
        if let w = NSApp.keyWindow {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { _ in onCancel() })
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        Self.count -= 1
        InputRouter.shared.recording = Self.count > 0
    }
}

struct KeyPicker: View {
    @Binding var code: UInt16
    var asSource = false
    var body: some View {
        Picker("", selection: $code) {
            ForEach(asSource ? KeyCodes.pickableSources : KeyCodes.pickable) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
    }
}


/// Record a combo, or pick the key from the list and toggle modifiers. Both edit the same value.
struct KeyComboEditor: View {
    @Binding var combo: KeyCombo
    var allowClear = true
    var asSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row when the column is wide enough, otherwise the key list moves below the recorder.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { recorder; orLabel; keyList }
                VStack(alignment: .leading, spacing: 6) {
                    recorder
                    HStack(spacing: 8) { orLabel; keyList }
                }
            }
            HStack(spacing: 6) {
                Text("Modifiers").font(.caption).foregroundStyle(.secondary)
                modToggle("⌃", .control); modToggle("⌥", .option); modToggle("⇧", .shift); modToggle("⌘", .command); modToggle("fn", .function)
            }
        }
    }

    private var recorder: some View { KeyRecorder(combo: $combo, allowClear: allowClear) }

    private var orLabel: some View { Text("or").foregroundStyle(.secondary).fixedSize() }

    private var keyList: some View {
        Picker("", selection: Binding(get: { combo.isUnset ? UInt16.max : combo.keyCode },
                                      set: { combo = KeyCombo(keyCode: $0, modifiers: combo.modifiers) })) {
            if combo.isUnset { Text("Choose key…").tag(UInt16.max) }
            ForEach(asSource ? KeyCodes.pickableSources : KeyCodes.pickable) { Text($0.name).tag($0.code) }
        }
        .labelsHidden().frame(width: 150)
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
        .help(L(help))
    }
}
