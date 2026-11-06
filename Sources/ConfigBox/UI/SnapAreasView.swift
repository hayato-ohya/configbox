import SwiftUI
import AppKit

/// BetterTouchTool-style "Snap Areas" block: Create · Edit · Manage · Show Description · Show Settings.
struct SnapAreasSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var session = SnapAreaEditSession.shared
    @AppStorage("snapAreas.showDescription") private var showDescription = true
    @AppStorage("snapAreas.showSettings") private var showSettings = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button { session.addArea(on: .underMouse) } label: { Label("Create", systemImage: "plus.rectangle.on.rectangle") }
                    .buttonStyle(.borderedProminent).help("Create a new snap area on the display under the mouse")
                Button { session.isActive ? session.end() : session.begin() } label: {
                    Label(session.isActive ? "Finish" : "Edit", systemImage: session.isActive ? "checkmark.rectangle" : "rectangle.and.pencil.and.ellipsis")
                }
                .disabled(store.config.snapAreas.isEmpty && !session.isActive)
                .help("Show all snap areas as movable, resizable windows")
                if session.isActive {
                    Button { session.cancel() } label: { Label("Cancel", systemImage: "xmark.rectangle") }
                        .help("Discard changes made since editing started (Esc)")
                }
                Button { MainWindowController.shared.show(.snapAreas) } label: { Label("Manage", systemImage: "list.bullet.rectangle") }
                    .help("List, enable, duplicate, delete and fine-tune snap areas")
                Spacer(minLength: 12)
                Toggle(isOn: $showDescription) { Label("Description", systemImage: "questionmark.circle") }.toggleStyle(.button)
                Toggle(isOn: $showSettings) { Label("Settings", systemImage: "slider.horizontal.3") }.toggleStyle(.button)
            }
            .fixedSize(horizontal: false, vertical: true)
            .controlSize(.regular)

            if showDescription {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snap areas are custom drop zones. While you drag a window, the areas on the display under the mouse light up; drop the window inside one and it takes the area's frame.")
                    Text("**Create** places a new colored window on the display under the mouse: move and resize it like any window, then press Done. **Edit** shows every area as such a window again. Inside a window, **Settings…** sets the name, color, a modifier key or app restriction.")
                    Text("**Attach Window…** links a window frame to the area: arrange any window the way it should look after being dropped, press Attach, and from then on windows dropped on the area get exactly that position and size instead of the drop zone's frame.")
                    Text("**Manage** lists all areas for enabling, duplicating, deleting and precise numeric editing. Areas are stored per display as fractions of the screen, so they survive resolution changes.")
                    Text("While editing, **Esc** (or Cancel) discards everything changed in that session, including added or deleted areas; **Return** or Done keeps it.")
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }

            if showSettings {
                Group {
                    LabeledContent("Area opacity") {
                        HStack {
                            Slider(value: $store.config.snapping.areaOpacity, in: 0.05...0.8)
                            Text("\(Int(store.config.snapping.areaOpacity * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    LabeledContent("Border width") {
                        HStack {
                            Slider(value: $store.config.snapping.areaBorderWidth, in: 0...6, step: 0.5)
                            Text(String(format: "%.1f pt", store.config.snapping.areaBorderWidth)).monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    Stepper(value: $store.config.snapping.areaShowDelayMs, in: 0...2000, step: 100) {
                        LabeledContent("Show areas after dragging for", value: store.config.snapping.areaShowDelayMs == 0 ? "immediately" : "\(store.config.snapping.areaShowDelayMs) ms")
                    }
                    Toggle("Show area names while dragging", isOn: $store.config.snapping.areaShowNames)
                }
            }

            if store.config.snapAreas.isEmpty {
                Text("No snap areas yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(store.config.snapAreas) { a in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: a.nsColor)).frame(width: 14, height: 14)
                        Text(a.name).fontWeight(.medium)
                        Text(SnapAreaManageView.summary(a)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !a.requireModifier.isEmpty { Text(a.requireModifier.symbols).foregroundStyle(.secondary) }
                        if let app = a.appBundleId { Image(nsImage: AppIcons.icon(for: app)).resizable().frame(width: 16, height: 16) }
                        Toggle("", isOn: Binding(get: { a.enabled }, set: { v in
                            if let i = store.config.snapAreas.firstIndex(where: { $0.id == a.id }) { store.config.snapAreas[i].enabled = v }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    .opacity(a.enabled ? 1 : 0.55)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { MainWindowController.shared.show(.snapAreas) }
                }
            }
        } header: {
            Text("Snap Areas (advanced)")
        }
    }
}

// MARK: - Manage window

struct SnapAreaManageView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var session = SnapAreaEditSession.shared
    @State private var selection: UUID? = CommandLine.arguments.contains("--select-first") ? ConfigStore.shared.config.snapAreas.first?.id : nil

    static func summary(_ a: SnapArea) -> String {
        guard let screen = NSScreen.screen(withDisplayID: a.displayID) else { return "\(a.displayName) · not connected" }
        let r = a.triggerRect(on: screen)
        var s = "\(a.displayName) · \(Int(r.width)) × \(Int(r.height)) pt"
        if a.target != nil { s += " · custom window frame" }
        return s
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.snapAreas) { a in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { a.enabled }, set: { v in
                                if let i = store.config.snapAreas.firstIndex(where: { $0.id == a.id }) { store.config.snapAreas[i].enabled = v }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: a.nsColor)).frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).fontWeight(.medium)
                                Text(Self.summary(a)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !a.requireModifier.isEmpty { Text(a.requireModifier.symbols).foregroundStyle(.secondary) }
                            if let app = a.appBundleId { Image(nsImage: AppIcons.icon(for: app)).resizable().frame(width: 16, height: 16) }
                        }
                        .padding(.vertical, 2)
                        .tag(a.id)
                    }
                    .onMove { from, to in store.config.snapAreas.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
                .overlay {
                    if store.config.snapAreas.isEmpty {
                        ContentUnavailableView("No Snap Areas", systemImage: "rectangle.dashed", description: Text("Click + to create one on the display under the mouse."))
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    IconButton(systemName: "plus", help: "Add") { selection = session.addArea(on: .underMouse).id }
                    IconButton(systemName: "minus", help: "Remove selected") { if let s = selection { session.remove(s); selection = nil } }.disabled(selection == nil)
                    IconButton(systemName: "plus.square.on.square", help: "Duplicate") { if let s = selection { session.duplicate(s) } }.disabled(selection == nil)
                    Spacer()
                    Button(session.isActive ? "Finish Editing" : "Edit on Screen") { session.isActive ? session.end() : session.begin() }
                        .disabled(store.config.snapAreas.isEmpty && !session.isActive)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(minWidth: 320, idealWidth: 380)

            Group {
                if let s = selection, let area = store.config.snapAreas.first(where: { $0.id == s }) {
                    ScrollView {
                        SnapAreaForm(area: store.binding(\.snapAreas, id: s, fallback: area)).padding(20)
                    }
                    .id(s)
                } else {
                    ContentUnavailableView("Select a Snap Area", systemImage: "rectangle.dashed", description: Text("Choose an area on the left to edit its settings."))
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Shared form

struct SnapAreaForm: View {
    @Binding var area: SnapArea
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var session = SnapAreaEditSession.shared

    private var screen: NSScreen? { NSScreen.screen(withDisplayID: area.displayID) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField("Name", text: $area.name).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Enabled").foregroundStyle(.secondary)
                Toggle("", isOn: $area.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            GridRow {
                Text("Color").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(SnapArea.colors.enumerated()), id: \.offset) { i, c in
                        Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(area.colorIndex == i ? 0.9 : 0), lineWidth: 2))
                            .onTapGesture { area.colorIndex = i }
                            .help(c.name)
                    }
                }
            }
            GridRow {
                Text("Display").foregroundStyle(.secondary)
                Text(screen == nil ? "\(area.displayName) (not connected)" : area.displayName)
            }
            GridRow {
                Text("Drop area").foregroundStyle(.secondary)
                RectFields(rect: $area.trigger, screen: screen)
            }
            GridRow {
                Text("Attached window").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    if let t = area.target, let screen {
                        let r = t.rect(in: screen.frame)
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow").foregroundStyle(.secondary)
                            Text("\(Int(r.width)) × \(Int(r.height)) pt at (\(Int(r.minX - screen.frame.minX)), \(Int(screen.frame.maxY - r.maxY)))")
                                .font(.system(.callout, design: .monospaced))
                        }
                        RectFields(rect: Binding(get: { area.target ?? area.trigger }, set: { area.target = $0 }), screen: screen)
                    } else {
                        Text("None — dropped windows take the drop area's own frame.").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button { WindowAttachSession.shared.begin(areaID: area.id) } label: {
                            Label("Attach Window…", systemImage: "macwindow.badge.plus")
                        }
                        .help("Arrange any window as it should appear after dropping, then press Attach")
                        Button(area.target == nil ? "Add as Dashed Window" : "Edit as Dashed Window") { session.editFrame(of: area.id) }
                        if area.target != nil {
                            Button("Detach") { area.target = nil }
                        }
                    }
                }
            }
            GridRow {
                Text("Only while holding").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $area.requireModifier) {
                        Text("Always").tag(Modifiers([]))
                        Text("⌥ Option").tag(Modifiers.option)
                        Text("⌃ Control").tag(Modifiers.control)
                        Text("⌘ Command").tag(Modifiers.command)
                        Text("⇧ Shift").tag(Modifiers.shift)
                        Text("fn").tag(Modifiers.function)
                    }.labelsHidden().frame(maxWidth: 220)
                    if !area.requireModifier.isEmpty {
                        Label("This area only appears while \(area.requireModifier.symbols) is held during the drag.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Only for app").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { area.appBundleId ?? "" }, set: { area.appBundleId = $0.isEmpty ? nil : $0 })) {
                    Text("Any app").tag("")
                    ForEach(store.config.apps) { Text($0.name).tag($0.bundleId) }
                    ForEach(AppIcons.runningApps().filter { r in !store.config.apps.contains { $0.bundleId == r.bundleId } }) { Text($0.name).tag($0.bundleId) }
                }.labelsHidden().frame(maxWidth: 260)
            }
            GridRow {
                Text("Visibility").foregroundStyle(.secondary)
                Toggle("Show this area while dragging", isOn: $area.showWhileDragging)
            }
            GridRow {
                Text("")
                HStack {
                    Button(session.isActive ? "Finish Editing" : "Position on Screen…") { session.isActive ? session.end() : session.begin() }
                    Button("Duplicate") { session.duplicate(area.id) }
                    Spacer()
                    Button(role: .destructive) { session.remove(area.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .font(.callout)
    }
}

/// X / Y (from the top-left of the display) / Width / Height in points, stored normalized.
struct RectFields: View {
    @Binding var rect: NRect
    let screen: NSScreen?

    var body: some View {
        if let screen {
            let f = screen.frame
            let r = rect.rect(in: f)
            HStack(spacing: 6) {
                field("X", value: r.minX - f.minX) { v in set(CGRect(x: f.minX + v, y: r.minY, width: r.width, height: r.height), f) }
                field("Y", value: f.maxY - r.maxY) { v in set(CGRect(x: r.minX, y: f.maxY - v - r.height, width: r.width, height: r.height), f) }
                field("W", value: r.width) { v in set(CGRect(x: r.minX, y: r.minY, width: max(20, v), height: r.height), f) }
                field("H", value: r.height) { v in set(CGRect(x: r.minX, y: r.maxY - max(20, v), width: r.width, height: max(20, v)), f) }
            }
        } else {
            Text(String(format: "x %.2f  y %.2f  w %.2f  h %.2f (normalized)", rect.x, rect.y, rect.w, rect.h)).foregroundStyle(.secondary)
        }
    }

    private func set(_ r: CGRect, _ f: CGRect) { rect = NRect(rect: r, in: f) }

    private func field(_ label: String, value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        VStack(spacing: 1) {
            TextField("", value: Binding(get: { Double(value.rounded()) }, set: { set(CGFloat($0)) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
