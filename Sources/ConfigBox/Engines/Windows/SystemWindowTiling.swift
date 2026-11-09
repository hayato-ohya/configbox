import AppKit

/// Reads whether macOS's own drag-to-tile options (System Settings › Desktop & Dock › Windows, macOS 15+)
/// are on, to warn about overlaps with ConfigBox's edge snapping. When both act on the same drop, macOS
/// treats the window as tiled and puts it back to its previous size the next time it is dragged.
enum SystemWindowTiling {
    struct Conflict: Equatable {
        var sideEdges = false   // "Drag windows to left or right edge of screen to tile"
        var menuBar = false     // "Drag windows to menu bar to fill screen"
        var isEmpty: Bool { !sideEdges && !menuBar }
    }

    /// The macOS options that are on and overlap with an edge ConfigBox snaps at (nil = none).
    static func conflict(with snapping: SnappingSettings) -> Conflict? {
        guard snapping.enabled, #available(macOS 15, *) else { return nil }
        // macOS only tiles while "Displays have separate Spaces" is on.
        if (UserDefaults(suiteName: "com.apple.spaces")?.object(forKey: "spans-displays") as? Bool) == true { return nil }
        // A key that was never changed in System Settings is absent, and the options are on by default.
        let prefs = UserDefaults(suiteName: "com.apple.WindowManager")
        func isOn(_ key: String) -> Bool { prefs?.object(forKey: key) as? Bool ?? true }

        var c = Conflict()
        if snapping.leftEdge != .none || snapping.rightEdge != .none || snapping.corners {
            c.sideEdges = isOn("EnableTilingByEdgeDrag")
        }
        if #available(macOS 15.1, *), snapping.topEdge != .none || snapping.corners {
            c.menuBar = isOn("EnableTopTilingByEdgeDrag")
        }
        return c.isEmpty ? nil : c
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
