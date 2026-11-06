import SwiftUI

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
        store.config.apps.removeAll { $0.bundleId == id }
        store.config.triggers.removeAll { $0.appBundleId == id }
        selection = ""
    }
}
