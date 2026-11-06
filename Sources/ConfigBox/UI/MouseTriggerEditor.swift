import SwiftUI
import AppKit

enum MouseTriggerType: String, CaseIterable, Identifiable {
    case click, scroll, gesture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .click: "Button Click"
        case .scroll: "Modifier + Scroll"
        case .gesture: "Button Gesture (hold & move)"
        }
    }
    init(_ m: MouseTrigger) {
        switch m {
        case .click: self = .click
        case .scroll: self = .scroll
        case .gesture: self = .gesture
        }
    }
}

struct MouseTriggerEditor: View {
    @Binding var trigger: MouseTrigger

    var body: some View {
        Picker("Trigger Type", selection: Binding(get: { MouseTriggerType(trigger) }, set: { t in
            switch t {
            case .click: trigger = .click(button: .middle, modifiers: [], clicks: 1)
            case .scroll: trigger = .scroll(direction: .up, modifiers: [.command])
            case .gesture: trigger = .gesture(button: .right, direction: .right, modifiers: [])
            }
        })) {
            ForEach(MouseTriggerType.allCases) { Text($0.title).tag($0) }
        }

        switch trigger {
        case .click(let b, let m, let c):
            LabeledContent("Record") {
                MouseRecorder(current: trigger) { button, mods in trigger = .click(button: button, modifiers: mods, clicks: c) }
            }
            Picker("Button", selection: Binding(get: { b }, set: { trigger = .click(button: $0, modifiers: m, clicks: c) })) {
                ForEach(MouseButton.allCases) { Text($0.title).tag($0) }
            }
            ModifierToggles(modifiers: Binding(get: { m }, set: { trigger = .click(button: b, modifiers: $0, clicks: c) }))
            Picker("Clicks", selection: Binding(get: { c }, set: { trigger = .click(button: b, modifiers: m, clicks: $0) })) {
                Text("Single").tag(1)
                Text("Double").tag(2)
            }
            if b.needsModifier && m.isEmpty {
                Label("Left and right clicks need at least one modifier so normal clicking keeps working.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        case .scroll(let d, let m):
            Picker("Direction", selection: Binding(get: { d }, set: { trigger = .scroll(direction: $0, modifiers: m) })) {
                ForEach(Direction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            ModifierToggles(modifiers: Binding(get: { m }, set: { trigger = .scroll(direction: d, modifiers: $0) }))
            if m.isEmpty {
                Label("Choose at least one modifier; plain scrolling is never intercepted.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Left / right also covers tilt wheels and horizontal trackpad scrolling. Fires at most every 150 ms while scrolling.")
                .font(.caption).foregroundStyle(.secondary)
        case .gesture(let b, let d, let m):
            LabeledContent("Record button") {
                MouseRecorder(current: trigger) { button, mods in trigger = .gesture(button: button, direction: d, modifiers: mods) }
            }
            Picker("Button", selection: Binding(get: { b }, set: { trigger = .gesture(button: $0, direction: d, modifiers: m) })) {
                ForEach(MouseButton.allCases) { Text($0.title).tag($0) }
            }
            Picker("Move", selection: Binding(get: { d }, set: { trigger = .gesture(button: b, direction: $0, modifiers: m) })) {
                ForEach(Direction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            ModifierToggles(modifiers: Binding(get: { m }, set: { trigger = .gesture(button: b, direction: d, modifiers: $0) }))
            if b == .left && m.isEmpty {
                Label("A left-button gesture needs a modifier, otherwise normal dragging would break.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Hold the button, move at least 30 pt, release. A press without movement is delivered as a normal click (so a bare right button still opens context menus).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ModifierToggles: View {
    @Binding var modifiers: Modifiers
    var body: some View {
        LabeledContent("Modifiers") {
            HStack(spacing: 6) {
                toggle("⌃", .control); toggle("⌥", .option); toggle("⇧", .shift); toggle("⌘", .command); toggle("fn", .function)
            }
        }
    }
    private func toggle(_ t: String, _ m: Modifiers) -> some View {
        Toggle(t, isOn: Binding(get: { modifiers.contains(m) }, set: { on in if on { modifiers.insert(m) } else { modifiers.remove(m) } }))
            .toggleStyle(.button).controlSize(.small)
    }
}

/// Click, then press any mouse button (with modifiers) inside the highlighted box.
struct MouseRecorder: View {
    let current: MouseTrigger
    var onRecord: (MouseButton, Modifiers) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Press a mouse button here…" : "Record…") { recording ? stop() : start() }
                .buttonStyle(.bordered)
                .foregroundStyle(recording ? Color.red : Color.primary)
            if recording {
                Text("Any button, with the modifiers you want. Esc to cancel.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        InputRouter.shared.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { e in
            if e.type == .keyDown { if e.keyCode == 53 { stop() }; return e }
            // Ignore the click that lands on the Record button itself (left, no modifiers) when it started recording.
            let mods = Modifiers(cgFlags: e.cgEvent?.flags ?? [])
            guard let button = MouseButton(rawValue: e.buttonNumber) else { return e }
            onRecord(button, mods)
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
