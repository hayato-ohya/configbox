import SwiftUI
import AppKit

struct AppSidebar: View {
    @EnvironmentObject var store: ConfigStore
    @Binding var selectedApp: String?
    @State private var selection: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Label("All Apps", systemImage: "square.grid.2x2").tag("")
                Section("App Specific") {
                    ForEach(store.config.apps) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: AppIcons.icon(for: app.bundleId)).resizable().frame(width: 18, height: 18)
                            Text(app.name).lineLimit(1)
                        }
                        .tag(app.bundleId)
                    }
                    .onMove { from, to in store.config.apps.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, new in selectedApp = new.isEmpty ? nil : new }
            .onAppear { selection = selectedApp ?? "" }

            Divider()
            HStack(spacing: 4) {
                Menu {
                    ForEach(AppIcons.runningApps()) { app in
                        Button(app.name) { add(app) }
                    }
                    Divider()
                    Button("Choose Application…") { if let app = AppIcons.chooseApp() { add(app) } }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)

                IconButton(systemName: "minus", help: "Remove selected") { remove() }
                    .disabled(selection.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func add(_ app: AppRef) {
        if !store.config.apps.contains(where: { $0.bundleId == app.bundleId }) {
            store.config.apps.append(app)
        }
        selection = app.bundleId
    }

    private func remove() {
        guard !selection.isEmpty else { return }
        let id = selection
        let count = store.config.triggers.filter { $0.appBundleId == id }.count
        if count > 0 {
            // The app's triggers go with it and there is no undo: ask first.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Remove “%@” from the app list?", store.config.apps.first { $0.bundleId == id }?.name ?? id)
            alert.informativeText = L("Its %lld trigger(s) are deleted too. This cannot be undone.", count)
            alert.addButton(withTitle: L("Remove"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.config.apps.removeAll { $0.bundleId == id }
        store.config.triggers.removeAll { $0.appBundleId == id }
        selection = ""
    }
}
