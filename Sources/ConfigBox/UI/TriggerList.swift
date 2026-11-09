import SwiftUI

extension KeyCombo {
    static let unset = KeyCombo(keyCode: 0xFFFF)
    var isUnset: Bool { keyCode == 0xFFFF }
    var displayOrUnset: String { isUnset ? L("Not set") : display }
}

struct TriggerListView: View {
    @ObservedObject var state: UIState
    @EnvironmentObject var store: ConfigStore

    private func inSection(_ t: Trigger) -> Bool {
        switch state.section {
        case .trackpad: t.kind.isGesture
        case .mouse: t.kind.isMouse
        default: t.kind.isShortcut
        }
    }

    private var filtered: [Trigger] {
        store.config.triggers.filter { inSection($0) && $0.appBundleId == state.selectedApp }
    }

    private var conflicts: [SystemGestures.Conflict] {
        state.section == .trackpad ? SystemGestures.conflicts(in: store.config.triggers) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !conflicts.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS also reacts to \(conflicts.map { $0.gesture.display }.joined(separator: ", ")).").font(.caption.weight(.semibold))
                        Text(L("System: %@. Both will fire; turn the system gesture off or use another finger count.", conflicts.map { "\($0.gesture.display) → \($0.systemFeature)" }.joined(separator: " · ")))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Trackpad Settings…") { SystemGestures.openTrackpadSettings() }.controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
            List(selection: $state.selectedTrigger) {
                ForEach(filtered) { t in
                    TriggerRow(trigger: t).tag(t.id)
                        .contextMenu {
                            Button("Move to Top") { store.moveTrigger(t.id, visible: filtered.map(\.id), by: Int.min) }
                            Button("Move Up") { store.moveTrigger(t.id, visible: filtered.map(\.id), by: -1) }
                            Button("Move Down") { store.moveTrigger(t.id, visible: filtered.map(\.id), by: 1) }
                            Button("Move to Bottom") { store.moveTrigger(t.id, visible: filtered.map(\.id), by: Int.max) }
                            Divider()
                            Button("Duplicate") {
                                var c = t; c.id = UUID(); c.name = t.name.isEmpty ? "" : t.name + L(" copy")
                                if let i = store.config.triggers.firstIndex(where: { $0.id == t.id }) { store.config.triggers.insert(c, at: i + 1) }
                            }
                            Button("Delete", role: .destructive) { store.remove(triggerIDs: [t.id]) }
                        }
                }
                .onMove { from, to in store.moveTriggers(visible: filtered.map(\.id), from: from, to: to) }
            }
            .listStyle(.inset)
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        state.section == .trackpad ? "No Trackpad Gestures" : state.section == .mouse ? "No Mouse Triggers" : "No Keyboard Shortcuts",
                        systemImage: state.section.symbol,
                        description: Text("Click + to add a trigger for \(state.selectedApp == nil ? L("all apps") : L("this app")).")
                    )
                }
            }

            Divider()
            HStack(spacing: 4) {
                IconButton(systemName: "plus", help: "Add") { add() }
                IconButton(systemName: "minus", help: "Remove selected") { remove() }
                    .disabled(state.selectedTrigger == nil)
                Spacer()
                Text("\(filtered.count) trigger\(filtered.count == 1 ? "" : "s") · drag to reorder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func add() {
        let kind: TriggerKind
        switch state.section {
        case .trackpad: kind = .gesture(Gesture(fingers: 3, kind: .tap))
        case .mouse: kind = .mouse(.click(button: .middle, modifiers: [], clicks: 1))
        default: kind = .shortcut(.unset)
        }
        let t = Trigger(kind: kind, action: .none, appBundleId: state.selectedApp)
        store.config.triggers.append(t)
        state.selectedTrigger = t.id
    }

    private func remove() {
        guard let id = state.selectedTrigger, filtered.contains(where: { $0.id == id }) else { return }
        store.remove(triggerIDs: [id])
        state.selectedTrigger = nil
    }
}

struct TriggerRow: View {
    let trigger: Trigger
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trigger.kind.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(triggerTitle).font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Image(systemName: trigger.action.symbol).font(.caption2)
                    Text(trigger.name.isEmpty ? trigger.action.display : "\(trigger.name) · \(trigger.action.display)")
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { trigger.enabled }, set: { v in
                var t = trigger; t.enabled = v; store.update(t)
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.vertical, 3)
        .opacity(trigger.enabled ? 1 : 0.55)
    }

    private var triggerTitle: String {
        if case .shortcut(let k) = trigger.kind { return k.displayOrUnset }
        return trigger.kind.display
    }
}
