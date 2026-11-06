import SwiftUI

struct SnappingSettingsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Enable window snapping", isOn: $store.config.snapping.enabled)
                    Toggle("Show preview while dragging", isOn: $store.config.snapping.showPreview)
                    Picker("Only snap while holding", selection: $store.config.snapping.requireModifier) {
                        Text("Always snap").tag(Modifiers([]))
                        Text("⌥ Option").tag(Modifiers.option)
                        Text("⌃ Control").tag(Modifiers.control)
                        Text("⌘ Command").tag(Modifiers.command)
                        Text("fn").tag(Modifiers.function)
                    }
                } header: { Text("Drag a window to a screen edge") } footer: {
                    Text("Drag a window by its title bar to an edge or corner of the screen. A preview shows the target area; release the mouse to resize. Keyboard tiling is available as a Window Management action in Keyboard Shortcuts.")
                }

                Section {
                    EdgeTargetPicker(title: "Left edge", selection: $store.config.snapping.leftEdge, halfName: "Left half")
                    EdgeTargetPicker(title: "Right edge", selection: $store.config.snapping.rightEdge, halfName: "Right half")
                    EdgeTargetPicker(title: "Top edge", selection: $store.config.snapping.topEdge, halfName: "Top half")
                    EdgeTargetPicker(title: "Bottom edge", selection: $store.config.snapping.bottomEdge, halfName: "Bottom half")
                    Toggle("Corners snap to quarters", isOn: $store.config.snapping.corners)
                    Toggle("Ignore edges shared with another display", isOn: $store.config.snapping.ignoreSharedEdges)
                } header: { Text("Zones") } footer: {
                    Text("Each edge can tile the window, or apply the window frame attached to one of your snap areas (created in the Snap Areas section below). At a boundary between two displays the edge of whichever display the pointer is on reacts; turn on “Ignore edges shared…” if you keep triggering it while moving windows across.")
                }

                SnapAreasSection()

                Section {
                    LabeledContent("Edge margin") {
                        HStack {
                            Slider(value: $store.config.snapping.edgeMargin, in: 0...150, step: 5)
                            TextField("", value: $store.config.snapping.edgeMargin, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Corner size") {
                        HStack {
                            Slider(value: $store.config.snapping.cornerSize, in: 30...400, step: 10)
                            TextField("", value: $store.config.snapping.cornerSize, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Sensitivity") } footer: {
                    Text("Edge margin is how far from the screen edge the pointer may be for an edge zone to trigger (1–150 pt; type a value for anything precise). Larger values are easier to hit but also easier to trigger by accident. Corners use the corner size instead.")
                }
            }
            .formStyle(.grouped)

            Divider()
            ZonePreview(settings: store.config.snapping, areas: store.config.snapAreas)
                .frame(width: 300)
                .padding(24)
        }
    }
}

/// Picker for one screen edge: built-in tiling plus the window frames of the user's snap areas.
struct EdgeTargetPicker: View {
    let title: String
    @Binding var selection: EdgeTarget
    let halfName: String
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Nothing").tag(EdgeTarget.none)
            Text(halfName).tag(EdgeTarget.half)
            Text("Maximize").tag(EdgeTarget.maximize)
            Text("Almost maximize").tag(EdgeTarget.almostMaximize)
            if !store.config.snapAreas.isEmpty {
                Divider()
                ForEach(store.config.snapAreas) { a in
                    Text(a.target == nil ? "“\(a.name)” (area frame)" : "“\(a.name)” window frame").tag(EdgeTarget.snapArea(a.id))
                }
            }
            if case .snapArea(let id) = selection, !store.config.snapAreas.contains(where: { $0.id == id }) {
                Text("Frame of a deleted snap area").tag(selection)
            }
        }
    }
}

/// Small illustration of the active snap zones.
private struct ZonePreview: View {
    let settings: SnappingSettings
    let areas: [SnapArea]

    private func short(_ t: EdgeTarget) -> String {
        switch t {
        case .none: "—"
        case .half: "½"
        case .maximize: "Max"
        case .almostMaximize: "≈Max"
        case .snapArea(let id): areas.first { $0.id == id }?.name ?? "?"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Snap zones").font(.headline)
            GeometryReader { geo in
                let w = geo.size.width, h = w * 0.625
                let c = min(w, h) * 0.28
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.2)))
                    if settings.leftEdge != .none { zone(w: 10, h: h, x: 0, y: 0, label: short(settings.leftEdge)) }
                    if settings.rightEdge != .none { zone(w: 10, h: h, x: w - 10, y: 0, label: short(settings.rightEdge)) }
                    if settings.topEdge != .none { zone(w: w, h: 10, x: 0, y: 0, label: short(settings.topEdge)) }
                    if settings.bottomEdge != .none { zone(w: w, h: 10, x: 0, y: h - 10, label: short(settings.bottomEdge)) }
                    if settings.corners {
                        corner(c, x: 0, y: 0); corner(c, x: w - c, y: 0); corner(c, x: 0, y: h - c); corner(c, x: w - c, y: h - c)
                    }
                }
                .frame(width: w, height: h)
            }
            .aspectRatio(1.6, contentMode: .fit)
            if settings.enabled {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow { Text("Left").foregroundStyle(.secondary); Text(settings.leftEdge.title(areas: areas)) }
                    GridRow { Text("Right").foregroundStyle(.secondary); Text(settings.rightEdge.title(areas: areas)) }
                    GridRow { Text("Top").foregroundStyle(.secondary); Text(settings.topEdge.title(areas: areas)) }
                    GridRow { Text("Bottom").foregroundStyle(.secondary); Text(settings.bottomEdge.title(areas: areas)) }
                    GridRow { Text("Corners").foregroundStyle(.secondary); Text(settings.corners ? "Quarters" : "Off") }
                }
                .font(.caption)
            } else {
                Text("Snapping disabled").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func zone(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat, label: String) -> some View {
        Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: w, height: h).offset(x: x, y: y)
    }
    private func corner(_ s: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)).frame(width: s, height: s).offset(x: x, y: y)
    }
}
