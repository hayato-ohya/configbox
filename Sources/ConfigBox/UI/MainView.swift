import SwiftUI
import AppKit

enum UISection: String, CaseIterable, Identifiable {
    case trackpad, mouse, keyboard, remap, snapping, switcher, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trackpad: L("Trackpad")
        case .mouse: L("Mouse")
        case .keyboard: L("Keyboard Shortcuts")
        case .remap: L("Key Remapping")
        case .snapping: L("Window Snapping")
        case .switcher: L("Window Switcher")
        case .settings: L("Settings")
        }
    }
    /// Short enough for all tabs to share one width, even in the narrowest window.
    var tabTitle: String {
        switch self {
        case .trackpad: L("Trackpad")
        case .mouse: L("Mouse")
        case .keyboard: L("Shortcuts")
        case .remap: L("Remapping")
        case .snapping: L("Snapping")
        case .switcher: L("Switcher")
        case .settings: L("Settings")
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

/// Top-level tabs. SwiftUI's segmented picker sizes segments by label, so this uses AppKit's equal distribution.
struct SectionTabs: NSViewRepresentable {
    @Binding var selection: UISection

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let sections = UISection.allCases
        let control = NSSegmentedControl(labels: sections.map(\.tabTitle), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (i, s) in sections.enumerated() { control.setToolTip(s.title, forSegment: i) }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = UISection.allCases.firstIndex(of: selection) ?? -1
    }

    final class Coordinator: NSObject {
        var parent: SectionTabs
        init(_ parent: SectionTabs) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            parent.selection = UISection.allCases[sender.selectedSegment]
        }
    }
}

final class UIState: ObservableObject {
    // A selection only makes sense in the list it was made in: leaving that list clears it, so the editor
    // and the − button never act on a row that is no longer on screen.
    @Published var section: UISection = .trackpad { didSet { if section != oldValue { selectedTrigger = nil } } }
    @Published var selectedApp: String? = nil {    // nil = all apps
        didSet { if selectedApp != oldValue { selectedTrigger = nil } }
    }
    @Published var selectedTrigger: UUID? = nil
    @Published var mousePage = 0          // 0 = triggers, 1 = settings
    @Published var trackpadPage = 0       // 0 = triggers, 1 = settings
    @Published var remapCategory: RemapCategory = .simple { didSet { if remapCategory != oldValue { selectedRemapID = nil } } }
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
        .frame(minWidth: 960, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 70)
            SectionTabs(selection: $state.section)
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
                .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)   // fits the key editor on one row
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
        guard let url else { return L("Not found: %@", idOrPath) }
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

extension View {
    /// Section footer text in a grouped Form: macOS right-aligns wrapped footer lines by default; keep them left-aligned.
    func formFooter() -> some View {
        multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
