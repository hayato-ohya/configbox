import Foundation
import CoreGraphics

/// Makes F1–F12 on non-Apple keyboards act like the media keys printed on a Mac keyboard
/// (brightness, Mission Control, playback, volume), with fn + F-key typing the plain F-key.
/// macOS gives this behaviour only to Apple keyboards; other keyboards always send plain F-keys.
final class MediaFunctionKeys {
    var enabled = false {
        didSet { KeyDeviceTracker.shared.setNeeded(enabled, by: "mediaFunctionKeys") }
    }
    /// fn as seen in flagsChanged events. F-key events carry the fn flag whether or not fn is held,
    /// so the flag on the key event itself says nothing.
    private(set) var fnHeld = false

    /// Mac key code → action, following the Apple keyboard layout.
    /// F5 / F6 (dictation, Do Not Disturb / keyboard light) have no public trigger and stay plain F-keys.
    static let actions: [UInt16: SystemAction] = [
        122: .brightnessDown,   // F1
        120: .brightnessUp,     // F2
        99: .missionControl,    // F3
        118: .launchpad,        // F4
        98: .previousTrack,     // F7
        100: .playPause,        // F8
        101: .nextTrack,        // F9
        109: .mute,             // F10
        103: .volumeDown,       // F11
        111: .volumeUp,         // F12
    ]

    func noteFlagsChanged(_ event: CGEvent) {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard code == 63 else { return }
        fnHeld = event.flags.contains(.maskSecondaryFn)
    }

    /// The action an F-key press should run instead of reaching apps, or nil to let it through.
    func action(for event: CGEvent) -> SystemAction? {
        guard enabled, !fnHeld else { return nil }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let action = Self.actions[code] else { return nil }
        // With ⌘ ⌃ ⌥ ⇧ held the key stays an F-key, so shortcuts such as ⌃F2 keep working.
        guard KeyCodes.modifiers(for: code, flags: event.flags).isEmpty else { return nil }
        if let dev = KeyDeviceTracker.shared.device(forKeyCode: code) {
            return Self.isApple(dev) ? nil : action
        }
        // Keyboard unknown (no Input Monitoring): an Apple keyboard sends a plain F-key without fn only
        // when "Use F1, F2, etc. keys as standard function keys" is on.
        return Self.appleKeysAreStandardFKeys ? nil : action
    }

    /// Apple (USB 0x05AC / Bluetooth 0x004C) and the built-in keyboard, which reports no vendor ID.
    static func isApple(_ d: DeviceRef) -> Bool {
        d.vendorId == 0x05AC || d.vendorId == 0x004C || d.vendorId == 0
    }

    private static var appleKeysAreStandardFKeys: Bool {
        UserDefaults(suiteName: UserDefaults.globalDomain)?.bool(forKey: "com.apple.keyboard.fnState") ?? false
    }
}
