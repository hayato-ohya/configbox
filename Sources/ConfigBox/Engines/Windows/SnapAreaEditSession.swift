import AppKit
import SwiftUI
import Combine

/// BetterTouchTool-style on-screen editing: every snap area becomes a real, movable and resizable
/// window. Moving or resizing one writes straight back to the configuration.
final class SnapAreaEditSession: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = SnapAreaEditSession()

    enum EditTarget: String, CaseIterable, Identifiable {
        case areas, frames
        var id: String { rawValue }
        var title: String { self == .areas ? L("Drop Areas") : L("Window Frames") }
    }

    @Published private(set) var isActive = false
    /// Which kind of window is brought to the front. Every window stays fully interactive; clicking one raises it.
    @Published var editTarget: EditTarget = .areas { didSet { applyInteractivity() } }
    private var windows: [UUID: AreaWindow] = [:]        // drop areas
    private var targetWindows: [UUID: AreaWindow] = [:]  // custom window frames
    private var toolbar: NSPanel?
    private var subscription: AnyCancellable?
    private var applyingFromWindow = false
    private let store = ConfigStore.shared
    private var snapshot: [SnapArea] = []
    private var keyMonitor: Any?

    // MARK: Session

    func begin() {
        guard !isActive else { NSApp.activate(ignoringOtherApps: true); return }
        isActive = true
        snapshot = store.config.snapAreas
        WindowSnapper.shared.editing = true
        // Esc anywhere in ConfigBox cancels the session; Return finishes it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isActive, !(e.window?.firstResponder is NSTextView) else { return e }
            if e.keyCode == 53 { self.cancel(); return nil }
            if e.keyCode == 48 && e.window is AreaWindow { self.editTarget = self.editTarget == .areas ? .frames : .areas; return nil }
            if (e.keyCode == 36 || e.keyCode == 76) && e.window is AreaWindow { self.end(); return nil }
            return e
        }
        subscription = store.$config
            .map(\.snapAreas)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
        showToolbar()
        sync()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Discards every change made since the session started (moves, resizes, settings, added or deleted areas).
    func cancel() {
        guard isActive else { return }
        let restored = snapshot
        end()
        store.config.snapAreas = restored
        Log.info("snap area editing cancelled; restored \(restored.count) area(s)")
    }

    func end() {
        guard isActive else { return }
        editTarget = .areas
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        subscription = nil
        for w in windows.values { w.orderOut(nil); w.contentView = nil }
        for w in targetWindows.values { w.orderOut(nil); w.contentView = nil }
        windows = [:]
        targetWindows = [:]
        toolbar?.orderOut(nil)
        toolbar = nil
        isActive = false
        WindowSnapper.shared.editing = false
        MainWindowController.shared.refreshActivationPolicy()
    }

    /// Creates a new area in the middle of the given display (40 % × 40 %) and starts editing.
    var hasChanges: Bool { isActive && store.config.snapAreas != snapshot }

    @discardableResult
    func addArea(on screen: NSScreen = .underMouse) -> SnapArea {
        let f = screen.visibleFrame
        let r = CGRect(x: f.midX - f.width * 0.2, y: f.midY - f.height * 0.2, width: f.width * 0.4, height: f.height * 0.4)
        let n = store.config.snapAreas.count + 1
        let area = SnapArea(name: L("Snap Area %lld", n), displayID: screen.displayID, displayName: screen.localizedName,
                            trigger: NRect(rect: r, in: screen.frame), colorIndex: (n - 1) % SnapArea.colors.count)
        if !isActive { begin() }          // take the snapshot before adding, so Esc removes the new area too
        store.config.snapAreas.append(area)
        DispatchQueue.main.async { [weak self] in self?.windows[area.id]?.makeKeyAndOrderFront(nil) }
        return area
    }

    func remove(_ id: UUID) {
        store.config.snapAreas.removeAll { $0.id == id }
    }

    func duplicate(_ id: UUID) {
        guard var a = store.config.snapAreas.first(where: { $0.id == id }) else { return }
        a.id = UUID()
        a.name += L(" copy")
        a.trigger.x = min(a.trigger.x + 0.03, 1 - a.trigger.w)
        a.trigger.y = max(a.trigger.y - 0.03, 0)
        store.config.snapAreas.append(a)
    }

    // MARK: Window sync

    private func sync() {
        guard isActive, !applyingFromWindow else { return }
        let areas = store.config.snapAreas
        let ids = Set(areas.map(\.id))

        for (id, w) in windows where !ids.contains(id) { w.orderOut(nil); w.contentView = nil; windows[id] = nil }
        for (id, w) in targetWindows where !ids.contains(id) || areas.first { $0.id == id }?.target == nil {
            w.orderOut(nil); w.contentView = nil; targetWindows[id] = nil
        }

        for a in areas {
            guard let screen = NSScreen.screen(withDisplayID: a.displayID) else { continue }
            place(window: &windows[a.id], area: a, isTarget: false, frame: a.triggerRect(on: screen))
            if a.target != nil {
                place(window: &targetWindows[a.id], area: a, isTarget: true, frame: a.targetRect(on: screen))
            }
        }
    }

    private func place(window: inout AreaWindow?, area: SnapArea, isTarget: Bool, frame: CGRect) {
        if window == nil {
            let w = AreaWindow(areaID: area.id, isTarget: isTarget)
            w.delegate = self
            w.contentView = NSHostingView(rootView: AreaWindowContent(areaID: area.id, isTarget: isTarget).environmentObject(store))
            w.setFrame(frame, display: false)
            w.setInteractive(true)
            w.orderFront(nil)
            window = w
            if !isTarget { w.orderFront(nil) } else { w.order(.below, relativeTo: windows[area.id]?.windowNumber ?? 0) }
        }
        guard let w = window else { return }
        w.apply(area: area)
        if !w.inLiveResize && !w.isDragging && !w.frame.integral.equalTo(frame.integral) {
            w.setFrame(frame, display: true)
        }
    }

    private func applyInteractivity() {
        let framesFront = editTarget == .frames
        for w in windows.values { w.setInteractive(true) }
        for w in targetWindows.values { w.setInteractive(true) }
        for w in (framesFront ? Array(targetWindows.values) : Array(windows.values)) { w.orderFront(nil) }
    }

    /// Switch to editing the attached window frame of one area (creating it if necessary).
    func editFrame(of id: UUID) {
        if let i = store.config.snapAreas.firstIndex(where: { $0.id == id }), store.config.snapAreas[i].target == nil {
            store.config.snapAreas[i].target = store.config.snapAreas[i].trigger
        }
        begin()
        editTarget = .frames
        DispatchQueue.main.async { [weak self] in self?.targetWindows[id]?.makeKeyAndOrderFront(nil) }
    }

    // MARK: Window delegate → model

    func windowDidMove(_ n: Notification) { commit(n.object as? AreaWindow) }
    func windowDidEndLiveResize(_ n: Notification) { commit(n.object as? AreaWindow) }
    func windowDidResize(_ n: Notification) { if let w = n.object as? AreaWindow, !w.inLiveResize { commit(w) } }

    private func commit(_ w: AreaWindow?) {
        guard let w, isActive, let idx = store.config.snapAreas.firstIndex(where: { $0.id == w.areaID }) else { return }
        guard let screen = w.screen ?? NSScreen.screens.max(by: { $0.frame.intersection(w.frame).area < $1.frame.intersection(w.frame).area }) else { return }
        applyingFromWindow = true
        defer { applyingFromWindow = false }
        var a = store.config.snapAreas[idx]
        let n = NRect(rect: w.frame, in: screen.frame)
        if w.isTarget {
            a.target = n
        } else {
            a.trigger = n
            if a.displayID != screen.displayID {
                a.displayID = screen.displayID
                a.displayName = screen.localizedName
                // Keep the custom target on the same display as the drop area.
                if let t = targetWindows[a.id], let ts = t.screen, ts != screen { a.target = NRect(rect: t.frame, in: screen.frame) }
            }
        }
        if a != store.config.snapAreas[idx] { store.config.snapAreas[idx] = a }
    }

    // MARK: Toolbar

    private func showToolbar() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 56), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: EditToolbarView().environmentObject(store))
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - 450, y: f.maxY - 80))
        p.orderFront(nil)
        toolbar = p
    }
}

// MARK: - Windows

final class AreaWindow: NSWindow {
    let areaID: UUID
    let isTarget: Bool
    var isDragging = false

    init(areaID: UUID, isTarget: Bool) {
        self.areaID = areaID
        self.isTarget = isTarget
        super.init(contentRect: .zero, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 80, height: 50)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func cancelOperation(_ sender: Any?) { SnapAreaEditSession.shared.cancel() }

    private(set) var isInteractive = true
    private var areaColor: NSColor = .systemBlue

    func setInteractive(_ on: Bool) {
        isInteractive = on
        isMovable = on
        level = .floating
        hasShadow = true
        refreshBackground()
    }

    func apply(area: SnapArea) {
        areaColor = area.nsColor
        title = isTarget ? L("Window frame: %@", area.name) : area.name
        refreshBackground()
    }

    private func refreshBackground() {
        let base: CGFloat = isTarget ? 0.18 : 0.42
        backgroundColor = areaColor.withAlphaComponent(isInteractive ? base : base * 0.35)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { isDragging = true; orderFront(nil) }
        if event.type == .leftMouseUp { isDragging = false; delegate?.windowDidMove?(Notification(name: NSWindow.didMoveNotification, object: self)) }
        super.sendEvent(event)
    }
}

// MARK: - SwiftUI content

struct AreaWindowContent: View {
    let areaID: UUID
    let isTarget: Bool
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var session = SnapAreaEditSession.shared
    @State private var showSettings = false

    private var active: Bool { true }

    var body: some View {
        if let area = store.config.snapAreas.first(where: { $0.id == areaID }) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: area.nsColor).opacity(active ? 1 : 0.5), style: StrokeStyle(lineWidth: active ? 3 : 2, dash: isTarget ? [10, 6] : []))
                    VStack(spacing: 6) {
                        Text(isTarget ? L("Window for: %@", area.name) : area.name)
                            .font(.system(size: geo.size.width < 220 ? 13 : 17, weight: .bold))
                            .foregroundStyle(.white.opacity(active ? 1 : 0.6)).shadow(radius: 2)
                            .lineLimit(1)
                        Text("\(Int(geo.size.width)) × \(Int(geo.size.height))")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(active ? 0.9 : 0.5))
                        if isTarget {
                            Text("Attached window frame").font(.caption2).foregroundStyle(.white.opacity(0.85))
                            if geo.size.height > 110 {
                                HStack(spacing: 8) {
                                    Button("Show Drop Area") { session.editTarget = .areas }
                                    Button("Detach", role: .destructive) {
                                        if let i = store.config.snapAreas.firstIndex(where: { $0.id == areaID }) { store.config.snapAreas[i].target = nil }
                                        session.editTarget = .areas
                                    }
                                }
                                .controlSize(.small).padding(.top, 4)
                            }
                        } else if geo.size.height > 110 {
                            HStack(spacing: 8) {
                                Button("Attach Window…") { WindowAttachSession.shared.begin(areaID: areaID) }
                                Button(area.target == nil ? "Add Window Frame" : "Show Window Frame") { session.editFrame(of: areaID) }
                                Button("Settings…") { showSettings = true }
                                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                                        SnapAreaForm(area: store.binding(\.snapAreas, id: areaID, fallback: area)).padding(16).frame(width: 420)
                                    }
                                Button(role: .destructive) { showSettings = false; SnapAreaEditSession.shared.remove(areaID) } label: { Image(systemName: "trash") }
                            }
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                }
                .padding(2)
            }
            .contextMenu {
                Button("Attach Window…") { WindowAttachSession.shared.begin(areaID: areaID) }
                Button("Settings…") { showSettings = true }
                Button("Duplicate") { SnapAreaEditSession.shared.duplicate(areaID) }
                Divider()
                Button("Delete", role: .destructive) { SnapAreaEditSession.shared.remove(areaID) }
            }
        }
    }
}

struct EditToolbarView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var session = SnapAreaEditSession.shared
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.dashed.and.paperclip").font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing Snap Areas").font(.headline)
                Text("Move / resize the colored windows; click one to bring it to the front (Tab swaps areas and frames). Esc cancels; Return or Done keeps the changes.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Picker("Front", selection: $session.editTarget) {
                ForEach(SnapAreaEditSession.EditTarget.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 270)
            .help("Bring drop areas or attached window frames to the front (Tab). Everything stays clickable.")
            Button { SnapAreaEditSession.shared.addArea(on: .underMouse) } label: { Label("Add", systemImage: "plus") }
            Button { MainWindowController.shared.show(.snapAreas) } label: { Label("Manage", systemImage: "list.bullet") }
            Button("Cancel") { SnapAreaEditSession.shared.cancel() }.keyboardShortcut(.cancelAction).help("Discard all changes made in this session (Esc)")
            Button("Done") { SnapAreaEditSession.shared.end() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(width: 900)
    }
}
