import AppKit
import UniformTypeIdentifiers

/// The Save / Restore Settings commands: file panels, confirmation and error reporting.
enum ConfigBackup {
    static func save(_ store: ConfigStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ConfigBox-\(today()).json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportConfig(to: url)
        } catch {
            Log.error("Settings save failed: \(error)")
            showError(L("Could not save the settings."), error.localizedDescription)
        }
    }

    static func restore(_ store: ConfigStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let config: Config
        do {
            config = try ConfigStore.decodeBackup(at: url)
        } catch {
            Log.error("Settings restore rejected \(url.lastPathComponent): \(error)")
            showError(L("Could not restore the settings."), L("“%@” is not a ConfigBox settings file.", url.lastPathComponent))
            return
        }
        guard confirm(file: url.lastPathComponent, config: config) else { return }
        do {
            try store.replaceConfig(with: config)
        } catch {
            Log.error("Settings restore failed: \(error)")
            showError(L("Could not restore the settings."), error.localizedDescription)
        }
    }

    static func resetToSample(_ store: ConfigStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Reset all settings to the sample configuration?")
        alert.informativeText = L("Your current settings are replaced. A copy of them is kept as %@.", ConfigStore.preRestoreFileName)
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.replaceConfig(with: .sample)
        } catch {
            Log.error("Settings reset failed: \(error)")
            showError(L("Could not reset the settings."), error.localizedDescription)
        }
    }

    private static func confirm(file: String, config: Config) -> Bool {
        var details = L("Your current settings are replaced. A copy of them is kept as %@.", ConfigStore.preRestoreFileName)
        let scripts = config.scriptActionCount
        if scripts > 0 {
            details += "\n\n" + L("This file contains %lld shell or AppleScript action(s). They run with your permissions when triggered, so restore it only if you trust its source.", scripts)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Restore settings from “%@”?", file)
        alert.informativeText = details
        alert.addButton(withTitle: L("Restore"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showError(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
