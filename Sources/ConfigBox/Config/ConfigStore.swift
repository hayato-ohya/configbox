import Foundation
import Combine
import SwiftUI

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { if !suppressSave { scheduleSave() } }
    }

    let fileURL: URL
    private var saveWork: DispatchWorkItem?
    /// Set while loading a config.json that could not be read, so the sample shown instead does not
    /// overwrite the user's file until they actually edit something.
    private var suppressSave = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ConfigBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
        config = Config()
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            config = .sample
            saveNow()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            LossyDecoding.reset()
            var c = try JSONDecoder().decode(Config.self, from: data)
            if !LossyDecoding.skipped.isEmpty {
                // Some entries could not be read and are gone from memory: the next save drops them from the
                // file too, so keep a copy of it as it is now.
                let backup = backupURL("partial")
                let kept = (try? FileManager.default.copyItem(at: fileURL, to: backup)) != nil
                Log.error("Config loaded without \(LossyDecoding.skipped.count) unreadable entr\(LossyDecoding.skipped.count == 1 ? "y" : "ies")"
                          + (kept ? "; the file as it was is kept at \(backup.path)" : "; a copy of the file could not be kept")
                          + ": " + LossyDecoding.skipped.joined(separator: " | "))
            }
            Self.normalize(&c)
            config = c
        } catch {
            let backup = backupURL("broken")
            do {
                try FileManager.default.copyItem(at: fileURL, to: backup)
                Log.error("Config load failed: \(error). Kept a backup at \(backup.path); showing the sample until edited.")
            } catch let copyError {
                Log.error("Config load failed: \(error). Backup failed too: \(copyError); showing the sample until edited.")
            }
            // Don't write the sample over the unreadable file; the next real edit saves normally.
            saveWork?.cancel()
            saveWork = nil
            suppressSave = true
            config = .sample
            suppressSave = false
        }
    }

    /// `config.json.<kind>-<timestamp>` next to the config file.
    private func backupURL(_ kind: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return fileURL.deletingLastPathComponent().appendingPathComponent("config.json.\(kind)-\(f.string(from: Date()))")
    }

    /// Repairs entries saved by older builds (e.g. an implicit fn flag recorded with arrow keys).
    private static func normalize(_ c: inout Config) {
        for i in c.triggers.indices {
            if case .shortcut(var k) = c.triggers[i].kind, KeyCodes.impliesFn.contains(k.keyCode), k.modifiers.contains(.function) {
                k.modifiers.remove(.function)
                c.triggers[i].kind = .shortcut(k)
            }
        }
        if KeyCodes.impliesFn.contains(c.switcher.shortcut.keyCode) { c.switcher.shortcut.modifiers.remove(.function) }
        // ⇧ means "backwards" while switching, so a shortcut recorded with it could never open the switcher.
        c.switcher.shortcut.modifiers.remove(.shift)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveWork = nil; self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Writes a debounced save immediately (used on quit so recent edits are not lost).
    func flushPendingSave() {
        guard let w = saveWork, !w.isCancelled else { return }
        w.cancel()
        saveWork = nil
        saveNow()
    }

    func saveNow() {
        do {
            try exportConfig(to: fileURL)
        } catch {
            Log.error("Config save failed: \(error)")
        }
    }

    func exportConfig(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }

    static let preRestoreFileName = "config.before-restore.json"

    /// Reads a saved settings file. `Config` treats every key as optional, so any JSON object would
    /// decode to an empty config and wipe the rules; a file ConfigBox wrote always has `general`.
    static func decodeBackup(at url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["general"] is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        LossyDecoding.reset()
        let config = try JSONDecoder().decode(Config.self, from: data)
        if !LossyDecoding.skipped.isEmpty {
            Log.error("Restoring \(url.lastPathComponent) without \(LossyDecoding.skipped.count) unreadable entr\(LossyDecoding.skipped.count == 1 ? "y" : "ies"): "
                      + LossyDecoding.skipped.joined(separator: " | "))
        }
        return config
    }

    /// Replaces the settings, keeping a copy of the current ones first so the change can be undone.
    func replaceConfig(with new: Config) throws {
        try exportConfig(to: fileURL.deletingLastPathComponent().appendingPathComponent(Self.preRestoreFileName))
        var c = new
        Self.normalize(&c)
        config = c
        saveNow()
        // The LaunchAgent is otherwise only updated when its toggle or the mappings change.
        InputRouter.shared.apply(config: c)
        if c.general.keepHIDMappingsAtLogin { HIDUtil.writeLaunchAgent() } else { HIDUtil.removeLaunchAgent() }
    }

    /// Binding to one element of a config array, looked up by id on every access.
    /// Index-based bindings (`$store.config.items[i]`) crash when the element is removed while a
    /// view still holds the binding; this one keeps returning the last known value instead.
    /// Adds keyboards not seen before (connected ones and any named by a rule) to `knownKeyboards`.
    /// Writes only when something is new, so polling this does not churn saves or SwiftUI updates.
    func rememberKeyboards(_ connected: [DeviceRef]) {
        let fromRules = config.simpleModifications.compactMap(\.device) + config.complexRules.compactMap(\.device)
            + config.chordRules.compactMap(\.device) + config.keyActionRules.compactMap(\.device)
        var known = config.knownKeyboards
        for d in connected + fromRules where !known.contains(where: { $0.vendorId == d.vendorId && $0.productId == d.productId }) {
            known.append(d)
        }
        if known.count != config.knownKeyboards.count { config.knownKeyboards = known }
    }

    func binding<T: Identifiable & Equatable>(_ keyPath: WritableKeyPath<Config, [T]>, id: T.ID, fallback: T) -> Binding<T> {
        var last = fallback
        return Binding(
            get: { [weak self] in
                if let v = self?.config[keyPath: keyPath].first(where: { $0.id == id }) { last = v }
                return last
            },
            set: { [weak self] v in
                guard let self, let i = self.config[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
                if self.config[keyPath: keyPath][i] != v { self.config[keyPath: keyPath][i] = v }
            })
    }

    /// Reorders a subset of `triggers` (the rows currently shown in a filtered list) while leaving the
    /// positions of all other triggers untouched.
    func moveTriggers(visible: [UUID], from source: IndexSet, to destination: Int) {
        var order = visible
        order.move(fromOffsets: source, toOffset: destination)
        reorderTriggers(visibleOrder: order)
    }

    func moveTrigger(_ id: UUID, visible: [UUID], by delta: Int) {
        guard let i = visible.firstIndex(of: id) else { return }
        var order = visible
        let j = max(0, min(order.count - 1, delta == Int.min ? 0 : delta == Int.max ? order.count - 1 : i + delta))
        order.remove(at: i)
        order.insert(id, at: j)
        reorderTriggers(visibleOrder: order)
    }

    private func reorderTriggers(visibleOrder: [UUID]) {
        let set = Set(visibleOrder)
        let slots = config.triggers.indices.filter { set.contains(config.triggers[$0].id) }
        guard slots.count == visibleOrder.count else { return }
        let byID = Dictionary(uniqueKeysWithValues: config.triggers.filter { set.contains($0.id) }.map { ($0.id, $0) })
        var t = config.triggers
        for (slot, id) in zip(slots, visibleOrder) { if let item = byID[id] { t[slot] = item } }
        if t != config.triggers { config.triggers = t }
    }

    // Convenience mutators used by the UI
    func update(_ trigger: Trigger) {
        if let i = config.triggers.firstIndex(where: { $0.id == trigger.id }) { config.triggers[i] = trigger }
    }
    func remove(triggerIDs: Set<UUID>) { config.triggers.removeAll { triggerIDs.contains($0.id) } }
}
