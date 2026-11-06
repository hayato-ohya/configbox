import SwiftUI
import AppKit
import Combine

/// Karabiner-EventViewer equivalent.
struct EventViewerView: View {
    @ObservedObject private var monitor = EventMonitor.shared
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("Events").tag(0)
                Text("Frontmost App").tag(1)
                Text("Devices").tag(2)
                Text("Trackpad").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch page {
            case 0: EventsPage()
            case 1: FrontmostAppPage()
            case 2: DevicesPage()
            default: TrackpadPage()
            }
        }
        .onAppear { monitor.isActive = true }
        .onDisappear { monitor.isActive = false; monitor.trackpadViewerActive = false }
        .onChange(of: page) { _, p in monitor.trackpadViewerActive = (p == 3) }
    }
}

private struct EventsPage: View {
    @ObservedObject private var monitor = EventMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            // Every column is resizable (drag the header dividers); only sensible minimums are enforced.
            Table(monitor.records.reversed()) {
                TableColumn("Time") { Text(EventMonitor.format($0.time)).monospacedDigit() }.width(min: 60, ideal: 95, max: 200)
                TableColumn("Type", value: \.type).width(min: 50, ideal: 100, max: 220)
                TableColumn("Code") { r in Text(r.keyCode.map(String.init) ?? "").monospacedDigit() }.width(min: 36, ideal: 48, max: 120)
                TableColumn("Key", value: \.name).width(min: 50, ideal: 110, max: 400)
                TableColumn("Modifiers", value: \.modifiers).width(min: 40, ideal: 80, max: 200)
                TableColumn("Flags", value: \.flags).width(min: 50, ideal: 90, max: 200)
                TableColumn("App", value: \.app).width(min: 60, ideal: 180, max: 600)
                TableColumn("Handling", value: \.note).width(min: 80, ideal: 260)
            }
            .font(.system(.body, design: .monospaced))
            Divider()
            HStack {
                Toggle("Pause", isOn: $monitor.paused).toggleStyle(.checkbox)
                Toggle("Show key up", isOn: $monitor.showKeyUp).toggleStyle(.checkbox)
                Spacer()
                Text("\(monitor.records.count) events").font(.caption).foregroundStyle(.secondary)
                Button("Copy") {
                    let text = monitor.records.map { "\(EventMonitor.format($0.time))\t\($0.type)\t\($0.keyCode.map(String.init) ?? "")\t\($0.name)\t\($0.modifiers)\t\($0.flags)\t\($0.app)\t\($0.note)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear") { monitor.clear() }
            }
            .padding(8)
        }
    }
}

private struct FrontmostAppPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var app: NSRunningApplication?
    @State private var windowTitle = ""
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Frontmost Application") {
                LabeledContent("Name", value: app?.localizedName ?? "—")
                LabeledContent("Bundle Identifier") { Text(app?.bundleIdentifier ?? "—").textSelection(.enabled) }
                LabeledContent("Path") { Text(app?.bundleURL?.path ?? "—").textSelection(.enabled).lineLimit(2) }
                LabeledContent("PID", value: app.map { String($0.processIdentifier) } ?? "—")
                LabeledContent("Window Title") { Text(windowTitle).textSelection(.enabled).lineLimit(2) }
            }
            Section {
                Button("Add to App-Specific list") {
                    guard let a = app, let id = a.bundleIdentifier else { return }
                    if !store.config.apps.contains(where: { $0.bundleId == id }) {
                        store.config.apps.append(AppRef(bundleId: id, name: a.localizedName ?? id))
                    }
                }
                .disabled(app?.bundleIdentifier == nil)
            } footer: {
                Text("Switch to another app and come back: the values update every 0.5 s. Use the bundle identifier for app-specific triggers.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { app = front }
        if let a = app {
            let el = AXUIElementCreateApplication(a.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.2)
            if let w: AXUIElement = AX.attr(el, kAXFocusedWindowAttribute) {
                windowTitle = AX.attr(w, kAXTitleAttribute) ?? ""
            }
        }
    }
}

private struct DevicesPage: View {
    @State private var devices: [HIDDeviceInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            Table(devices) {
                TableColumn("Type") { Text($0.kind.rawValue) }.width(min: 60, ideal: 110, max: 220)
                TableColumn("Product", value: \.name).width(min: 80, ideal: 260)
                TableColumn("Manufacturer", value: \.manufacturer).width(min: 60, ideal: 140, max: 400)
                TableColumn("Vendor / Product ID") { Text($0.idString).monospacedDigit() }.width(min: 80, ideal: 150, max: 260)
                TableColumn("Transport", value: \.transport).width(min: 50, ideal: 90, max: 200)
                TableColumn("Built-in") { Text($0.builtIn ? "Yes" : "") }.width(min: 40, ideal: 60, max: 120)
            }
            Divider()
            HStack {
                Text("\(devices.count) devices").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { devices = HIDDevices.list() }
            }
            .padding(8)
        }
        .onAppear { devices = HIDDevices.list() }
    }
}

private struct TrackpadPage: View {
    @ObservedObject private var monitor = EventMonitor.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("\(monitor.fingerCount) finger\(monitor.fingerCount == 1 ? "" : "s")", systemImage: "hand.raised")
                Spacer()
                Text("Last gesture: ").foregroundStyle(.secondary) + Text(monitor.lastGesture).bold()
            }
            .font(.title3)
            .padding(.horizontal)

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.2)))
                    ForEach(monitor.touches) { t in
                        let d = max(18, t.size * 40)
                        Circle()
                            .fill(t.state == 4 || t.state == 3 ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.4))
                            .frame(width: d, height: d)
                            .overlay(Text("\(t.id)").font(.caption2).foregroundStyle(.white))
                            .position(x: t.x * w, y: (1 - t.y) * h)
                    }
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
            .padding(.horizontal)

            Text(TrackpadEngine.shared.isAvailable
                 ? "Live multitouch frames from the built-in or Magic Trackpad. Blue = touching, grey = hovering."
                 : "The multitouch framework is not available on this system.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical)
        .onAppear { monitor.trackpadViewerActive = true }
    }
}
