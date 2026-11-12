import SwiftUI

struct TriggerEditorContainer: View {
    @ObservedObject var state: UIState
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        if let id = state.selectedTrigger, let t = store.config.triggers.first(where: { $0.id == id }) {
            TriggerEditor(trigger: store.binding(\.triggers, id: id, fallback: t)).id(id)
        } else {
            ContentUnavailableView("Select a Trigger", systemImage: "hand.point.up.left",
                                   description: Text("Choose a trigger on the left to configure its action."))
        }
    }
}

struct TriggerEditor: View {
    @Binding var trigger: Trigger
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Trigger") {
                TextField("Name (optional)", text: $trigger.name)
                switch trigger.kind {
                case .gesture(let g):
                    GestureEditor(gesture: Binding(get: { g }, set: { trigger.kind = .gesture($0) }))
                case .shortcut(let k):
                    LabeledContent("Shortcut") {
                        KeyRecorder(combo: Binding(get: { k }, set: { trigger.kind = .shortcut($0) }))
                    }
                case .mouse(let m):
                    MouseTriggerEditor(trigger: Binding(get: { m }, set: { trigger.kind = .mouse($0) }))
                }
                Toggle("Enabled", isOn: $trigger.enabled)
                IssueNotes(issues: ConfigValidation.issues(for: trigger, in: store.config))
            }
            Section("Action") {
                ActionEditor(action: $trigger.action)
            }
        }
        .formStyle(.grouped)
    }
}

struct GestureEditor: View {
    @Binding var gesture: Gesture
    var body: some View {
        Picker("Fingers", selection: $gesture.fingers) {
            ForEach(2..<6, id: \.self) { Text("\($0) Fingers").tag($0) }
        }
        Picker("Gesture", selection: $gesture.kind) {
            ForEach(GestureKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        if gesture.fingers == 2 || (!gesture.kind.isStationary && gesture.fingers >= 3) {
            Text("macOS handles this gesture itself too. Disable the overlapping system gesture in System Settings › Trackpad to avoid double actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if gesture.kind == .doubleTap {
            Text("A single tap with the same number of fingers now waits until no second tap can follow (the system double-click speed) before it runs.")
                .font(.caption).foregroundStyle(.secondary)
        } else if gesture.kind == .doubleClick {
            Text("Without a click trigger for the same number of fingers, the first click goes through as a normal click.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum ActionType: String, CaseIterable, Identifiable {
    case none, keyboardShortcut, typeText, launchApp, openURL, runShell, runAppleScript, window, system, showWindowSwitcher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: L("No Action")
        case .keyboardShortcut: L("Send Keyboard Shortcut")
        case .typeText: L("Type Text")
        case .launchApp: L("Launch / Activate Application")
        case .openURL: L("Open URL")
        case .runShell: L("Run Shell Script")
        case .runAppleScript: L("Run AppleScript")
        case .window: L("Window Management")
        case .system: L("System Action")
        case .showWindowSwitcher: L("Show Window Switcher")
        }
    }
    init(_ a: Action) {
        switch a {
        case .none: self = .none
        case .keyboardShortcut: self = .keyboardShortcut
        case .typeText: self = .typeText
        case .launchApp: self = .launchApp
        case .openURL: self = .openURL
        case .runShell: self = .runShell
        case .runAppleScript: self = .runAppleScript
        case .window, .snapAreaFrame, .windowCycle: self = .window
        case .system: self = .system
        case .showWindowSwitcher: self = .showWindowSwitcher
        }
    }
    var defaultAction: Action {
        switch self {
        case .none: .none
        case .keyboardShortcut: .keyboardShortcut(.unset)
        case .typeText: .typeText("")
        case .launchApp: .launchApp("")
        case .openURL: .openURL("https://")
        case .runShell: .runShell("")
        case .runAppleScript: .runAppleScript("")
        case .window: .window(.leftHalf)
        case .system: .system(.missionControl)
        case .showWindowSwitcher: .showWindowSwitcher
        }
    }
}

struct ActionEditor: View {
    @Binding var action: Action

    var body: some View {
        Picker("Type", selection: Binding(get: { ActionType(action) }, set: { action = $0.defaultAction })) {
            ForEach(ActionType.allCases) { Text($0.title).tag($0) }
        }

        switch action {
        case .none, .showWindowSwitcher:
            EmptyView()
        case .keyboardShortcut(let k):
            // Not a LabeledContent: the editor is wider than the value column of a narrow form, and a value
            // that does not fit is drawn sticking out of the row on the left.
            VStack(alignment: .leading, spacing: 6) {
                Text("Key to send")
                KeyComboEditor(combo: Binding(get: { k }, set: { action = .keyboardShortcut($0) }))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("A single key (e.g. 英数 / かな, Escape, F-keys) works too: pick it from the list and leave all modifiers off.")
                .font(.caption).foregroundStyle(.secondary)
        case .typeText(let t):
            TextField("Text to type", text: Binding(get: { t }, set: { action = .typeText($0) }), axis: .vertical)
                .lineLimit(1...4)
            Text("Typed as Unicode input, so any script works; the current app receives it as if entered on the keyboard.")
                .font(.caption).foregroundStyle(.secondary)
        case .launchApp(let s):
            AppChooser(value: Binding(get: { s }, set: { action = .launchApp($0) }))
        case .openURL(let s):
            TextField("URL", text: Binding(get: { s }, set: { action = .openURL($0) }))
        case .runShell(let s):
            ScriptEditor(title: "zsh script", text: Binding(get: { s }, set: { action = .runShell($0) }))
        case .runAppleScript(let s):
            ScriptEditor(title: "AppleScript", text: Binding(get: { s }, set: { action = .runAppleScript($0) }))
        case .window, .snapAreaFrame, .windowCycle:
            WindowChoicePicker(action: $action)
            if case .windowCycle(let steps) = action {
                CycleStepsEditor(steps: Binding(get: { steps }, set: { action = .windowCycle($0) }))
            }
        case .system(let s):
            Picker("System", selection: Binding(get: { s }, set: { action = .system($0) })) {
                ForEach(SystemAction.allCases) { Text($0.title).tag($0) }
            }
            if s == .drag {
                Text("Works like clicking the trackpad and moving without letting go. If fingers are still down when it runs (e.g. a swipe trigger), moving them drags and lifting them lets go; if not (e.g. a tap trigger), the next touch drags and lifting it lets go. With two or more fingers, ConfigBox moves the pointer itself. Clicking or running it again also lets go.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Window Management target: built-in tiling actions plus the window frames of the user's snap areas.
struct WindowChoicePicker: View {
    @Binding var action: Action
    @EnvironmentObject var store: ConfigStore

    private enum Choice: Hashable { case tile(WindowAction), area(UUID), cycle }

    private var current: Choice {
        switch action {
        case .window(let w): .tile(w)
        case .snapAreaFrame(let id): .area(id)
        case .windowCycle: .cycle
        default: .tile(.leftHalf)
        }
    }

    var body: some View {
        Picker("Window", selection: Binding(get: { current }, set: { c in
            switch c {
            case .tile(let w): action = .window(w)
            case .area(let id): action = .snapAreaFrame(id)
            case .cycle: if case .windowCycle = action {} else { action = .windowCycle([.tile(.leftHalf), .tile(.leftTwoThirds), .tile(.leftThird)]) }
            }
        })) {
            Text("Cycle through steps…").tag(Choice.cycle)
            Divider()
            ForEach(WindowAction.allCases) { Text($0.title).tag(Choice.tile($0)) }
            if !store.config.snapAreas.isEmpty {
                Divider()
                ForEach(store.config.snapAreas) { a in
                    Text(a.target == nil ? "“\(a.name)” (area frame)" : "“\(a.name)” window frame").tag(Choice.area(a.id))
                }
            }
            if case .area(let id) = current, !store.config.snapAreas.contains(where: { $0.id == id }) {
                Text("Frame of a deleted snap area").tag(current)
            }
        }
        if case .snapAreaFrame(let id) = action, let a = store.config.snapAreas.first(where: { $0.id == id }) {
            Text("Moves the focused window to the frame attached to “\(a.name)” on \(a.displayName), regardless of where the window currently is.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Ordered steps of a window cycle. Each press of the trigger moves the window to the step after the
/// one it is currently in, so the same key can go Left Half → a frame on another display → … and back.
struct CycleStepsEditor: View {
    @Binding var steps: [WindowTarget]
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 8) {
                    Text("\(i + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Picker("", selection: Binding(get: { step }, set: { if steps.indices.contains(i) { steps[i] = $0 } })) {
                        ForEach(WindowAction.allCases) { Text($0.title).tag(WindowTarget.tile($0)) }
                        if !store.config.snapAreas.isEmpty {
                            Divider()
                            ForEach(store.config.snapAreas) { a in
                                Text("“\(a.name)” \(a.target == nil ? L("area frame") : L("window frame")) · \(a.displayName)").tag(WindowTarget.area(a.id))
                            }
                        }
                    }
                    .labelsHidden()
                    IconButton(systemName: "chevron.up", help: "Move up") { if i > 0 { steps.swapAt(i, i - 1) } }.disabled(i == 0)
                    IconButton(systemName: "chevron.down", help: "Move down") { if i < steps.count - 1 { steps.swapAt(i, i + 1) } }.disabled(i >= steps.count - 1)
                    IconButton(systemName: "minus.circle", role: .destructive, help: "Remove step") { steps.remove(at: i) }.disabled(steps.count <= 1)
                }
            }
            Button { steps.append(.tile(.rightHalf)) } label: { Label("Add Step", systemImage: "plus") }
            Text("Each press moves the window to the step after the one it currently matches (within a few points); if it matches none, it goes to step 1. Steps on other displays simply move the window there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AppChooser: View {
    @Binding var value: String
    @State private var installed: [AppRef] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !value.isEmpty {
                    Image(nsImage: AppIcons.icon(for: value)).resizable().frame(width: 20, height: 20)
                }
                TextField("Bundle identifier or path", text: $value)
                Menu("Choose") {
                    Section("Running") {
                        ForEach(AppIcons.runningApps()) { app in Button(app.name) { value = app.bundleId } }
                    }
                    Section("Installed") {
                        ForEach(installed) { app in Button(app.name) { value = app.bundleId } }
                    }
                    Divider()
                    Button("Browse…") { if let app = AppIcons.chooseApp() { value = app.bundleId } }
                }
                .fixedSize()
            }
            if !value.isEmpty {
                Text(AppIcons.displayName(for: value)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if installed.isEmpty { installed = AppIcons.installedApps() } }
    }
}

struct ScriptEditor: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}
