import SwiftUI
import AppKit
import Combine

struct DevicePicker: View {
    @Binding var device: DeviceRef?
    let keyboards: [HIDDeviceInfo]

    var body: some View {
        Picker("", selection: Binding(get: { device.map { "\($0.vendorId):\($0.productId)" } ?? "" },
                                      set: { key in device = keyboards.first { "\($0.vendorId):\($0.productId)" == key }?.ref })) {
            Text("All keyboards").tag("")
            ForEach(keyboards) { k in Text(k.name).tag("\(k.vendorId):\(k.productId)") }
            if let d = device, !keyboards.contains(where: { $0.vendorId == d.vendorId && $0.productId == d.productId }) {
                Text("\(d.name) (disconnected)").tag("\(d.vendorId):\(d.productId)")
            }
        }
        .labelsHidden()
    }
}

struct ActionSequenceEditor: View {
    @Binding var actions: [Action]
    var minimum = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { i, _ in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Step \(i + 1)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        IconButton(systemName: "chevron.up", help: "Move up") { if i > 0 { actions.swapAt(i, i - 1) } }.disabled(i == 0)
                        IconButton(systemName: "chevron.down", help: "Move down") { if i < actions.count - 1 { actions.swapAt(i, i + 1) } }.disabled(i >= actions.count - 1)
                        IconButton(systemName: "minus.circle", role: .destructive, help: "Remove step") { actions.remove(at: i) }.disabled(actions.count <= minimum)
                    }
                    ActionEditor(action: Binding(get: { actions.indices.contains(i) ? actions[i] : .none },
                                                 set: { if actions.indices.contains(i) { actions[i] = $0 } }))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Button { actions.append(.keyboardShortcut(.unset)) } label: { Label("Add Step", systemImage: "plus") }
        }
    }
}

struct ChordRecorder: View {
    @Binding var keys: [UInt16]
    @State private var recording = false
    @State private var pressed: [UInt16] = []
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? (pressed.isEmpty ? "Press 2–3 keys together…" : pressed.map { KeyCodes.name(for: $0) }.joined(separator: " + ")) : (keys.isEmpty ? "Click to record" : keys.map { KeyCodes.name(for: $0) }.joined(separator: " + ")))
                .frame(minWidth: 140)
                .foregroundStyle(recording ? Color.red : (keys.isEmpty ? Color.secondary : Color.primary))
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        pressed = []
        InputRouter.shared.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            if e.type == .keyDown {
                if e.keyCode == 53 && pressed.isEmpty { stop(); return nil }
                if !pressed.contains(e.keyCode) && pressed.count < 3 { pressed.append(e.keyCode) }
            } else if !pressed.isEmpty {
                if pressed.count >= 2 { keys = pressed }
                stop()
            }
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
