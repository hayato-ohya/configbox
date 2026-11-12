import Foundation
import AppKit

/// Reads which built-in macOS trackpad gestures are enabled, to warn about overlaps with ConfigBox triggers.
enum SystemGestures {
    struct Conflict: Identifiable {
        let gesture: Gesture
        let systemFeature: String
        var id: String { gesture.display }
    }

    private static func int(_ key: String) -> Int? {
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            if let v = UserDefaults(suiteName: domain)?.object(forKey: key) as? Int { return v }
        }
        return nil
    }

    /// System features claimed for a given finger count / direction (nil = none).
    static func systemFeature(for g: Gesture) -> String? {
        // A tap or click next to a resting finger is taken from macOS whenever it matches (a two-finger click
        // that becomes a secondary click included), so nothing runs twice.
        if g.anchor != nil && g.kind.isStationary { return nil }
        // Trackpad*Swipe values: 0 off, 1 swipe between pages (3h), 2 Mission Control / Spaces / App Exposé
        let three = (int("TrackpadThreeFingerHorizSwipeGesture") ?? 0, int("TrackpadThreeFingerVertSwipeGesture") ?? 0)
        let four = (int("TrackpadFourFingerHorizSwipeGesture") ?? 2, int("TrackpadFourFingerVertSwipeGesture") ?? 2)
        let threeTap = int("TrackpadThreeFingerTapGesture") ?? 0
        let threeDrag = int("TrackpadThreeFingerDrag") ?? 0
        switch (g.totalFingers, g.kind) {
        case (3, .tap), (3, .doubleTap): return threeTap != 0 ? L("Look up / data detectors (three-finger tap)") : nil
        case (3, .swipeLeft), (3, .swipeRight):
            if threeDrag != 0 { return L("Three-finger drag") }
            return three.0 == 0 ? nil : (three.0 == 1 ? L("Swipe between pages") : L("Swipe between full-screen apps / Spaces"))
        case (3, .swipeUp), (3, .swipeDown):
            if threeDrag != 0 { return L("Three-finger drag") }
            return three.1 == 0 ? nil : L("Mission Control / App Exposé")
        case (4, .swipeLeft), (4, .swipeRight): return four.0 == 0 ? nil : L("Swipe between full-screen apps / Spaces")
        case (4, .swipeUp), (4, .swipeDown): return four.1 == 0 ? nil : L("Mission Control / App Exposé")
        case (2, _): return L("Two-finger scrolling / secondary click")
        default: return nil
        }
    }

    static func conflicts(in triggers: [Trigger]) -> [Conflict] {
        var seen = Set<String>()
        var out: [Conflict] = []
        for t in triggers where t.enabled {
            guard case .gesture(let g) = t.kind, let f = systemFeature(for: g), seen.insert(g.display).inserted else { continue }
            out.append(Conflict(gesture: g, systemFeature: f))
        }
        return out
    }

    static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures") {
            NSWorkspace.shared.open(url)
        }
    }
}
