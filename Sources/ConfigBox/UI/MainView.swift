import SwiftUI
import AppKit

enum UISection: String, CaseIterable, Identifiable {
    case trackpad, mouse, keyboard, remap, snapping, switcher, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard Shortcuts"
        case .remap: "Key Remapping"
        case .snapping: "Window Snapping"
        case .switcher: "Window Switcher"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .trackpad: "hand.draw"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .remap: "arrow.triangle.swap"
        case .snapping: "rectangle.split.2x1"
        case .switcher: "rectangle.3.group"
        case .settings: "gearshape"
        }
    }
}

final class UIState: ObservableObject {
    @Published var section: UISection = .trackpad
    @Published var selectedApp: String? = nil      // nil = all apps
    @Published var selectedTrigger: UUID? = nil
    @Published var mousePage = 0          // 0 = triggers, 1 = settings
    @Published var trackpadPage = 0       // 0 = triggers, 1 = settings
    @Published var remapCategory: RemapCategory = .simple
    @Published var selectedRemapID: UUID? = nil
}

struct MainView: View {
    @ObservedObject var state: UIState
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 70)
            Picker("", selection: $state.section) {
                ForEach(UISection.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 900)
            Spacer(minLength: 70)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .mouse:
            VStack(spacing: 0) {
                Picker("", selection: $state.mousePage) {
                    Text("Triggers").tag(0)
                    Text("Settings").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260).padding(.vertical, 8)
                Divider()
                if state.mousePage == 0 { triggerColumns } else { MouseSettingsView() }
            }
        case .trackpad:
            VStack(spacing: 0) {
                Picker("", selection: $state.trackpadPage) {
                    Text("Triggers").tag(0)
                    Text("Settings").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260).padding(.vertical, 8)
                Divider()
                if state.trackpadPage == 0 { triggerColumns } else { TrackpadSettingsView() }
            }
        case .keyboard:
            triggerColumns
        case .remap: RemapView(state: state)
        case .snapping: SnappingSettingsView()
        case .switcher: SwitcherSettingsView()
        case .settings: SettingsView()
        }
    }
}

extension MainView {
    var triggerColumns: some View {
        HSplitView {
            AppSidebar(selectedApp: $state.selectedApp)
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 280, maxHeight: .infinity)
            TriggerListView(state: state)
                .frame(minWidth: 300, idealWidth: 380, maxHeight: .infinity)
            TriggerEditorContainer(state: state)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for bundleId: String) -> NSImage {
        if let c = cache[bundleId] { return c }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleId] = img
        return img
    }

    static func runningApps() -> [AppRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { AppRef(bundleId: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayNameShort(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    static func displayName(for idOrPath: String) -> String {
        let url = idOrPath.hasPrefix("/") ? URL(fileURLWithPath: idOrPath) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: idOrPath)
        guard let url else { return "Not found: \(idOrPath)" }
        return FileManager.default.displayName(atPath: url.path) + "  —  " + url.path
    }

    /// Apps in /Applications (incl. subfolders one level deep) and /System/Applications.
    static func installedApps() -> [AppRef] {
        var out: [String: AppRef] = [:]
        let fm = FileManager.default
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let path = (dir as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    if let b = Bundle(path: path), let id = b.bundleIdentifier {
                        let name = (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? (b.infoDictionary?["CFBundleName"] as? String) ?? String(item.dropLast(4))
                        out[id] = AppRef(bundleId: id, name: name)
                    }
                } else if dir == "/Applications", let sub = try? fm.contentsOfDirectory(atPath: path) {
                    for s in sub where s.hasSuffix(".app") {
                        let p = (path as NSString).appendingPathComponent(s)
                        if let b = Bundle(path: p), let id = b.bundleIdentifier {
                            out[id] = AppRef(bundleId: id, name: (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? String(s.dropLast(4)))
                        }
                    }
                }
            }
        }
        return out.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func chooseApp() -> AppRef? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        let name = (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? (b.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return AppRef(bundleId: id, name: name)
    }
}
