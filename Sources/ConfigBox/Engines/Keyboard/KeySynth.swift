import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Posts synthetic input events. Every event is tagged so our own tap ignores it.
enum KeySynth {
    static let marker: Int64 = 0x4346_4258 // "CFBX"
    /// Key events replayed by the chord engine: skip the remapper/chord engine but still run macros and triggers.
    static let chordReplayMarker: Int64 = 0x4346_4243 // "CFBC"

    static func isSynthetic(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Mirrors the "Type on JIS keyboards as ANSI" setting. The tap skips our own events, so the keys sent
    /// here get the same treatment directly; otherwise a sent ⇧2 would not match a typed one.
    static var treatJISAsANSI = false
    private static let ansiKeyboardType: Int64 = 40

    /// `ansi`: the key code is meant as a key of the ANSI layout whatever keyboard is in use
    /// (33 is [ on ANSI but @ on JIS), so the event is marked as coming from an ANSI keyboard.
    static func tap(_ combo: KeyCombo, ansi: Bool = false) {
        post(combo, down: true, ansi: ansi)
        post(combo, down: false, ansi: ansi)
    }

    static func post(_ combo: KeyCombo, down: Bool, ansi: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: down) else { return }
        // A new event carries the type of the keyboard used last, which decides how apps read the key code.
        let type = e.getIntegerValueField(.keyboardEventKeyboardType)
        if ansi || (treatJISAsANSI && KBGetLayoutType(Int16(truncatingIfNeeded: type)) == kKeyboardJIS) {
            e.setIntegerValueField(.keyboardEventKeyboardType, value: ansiKeyboardType)
        }
        e.flags = combo.modifiers.cgFlags
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (any script) via Unicode key events, at most 20 UTF-16 units per event,
    /// never splitting a character (surrogate pair / grapheme cluster).
    static func type(_ text: String) {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for ch in text {
            let units = Array(String(ch).utf16)
            if !current.isEmpty && current.count + units.count > 20 { chunks.append(current); current = [] }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        for chunk in chunks {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // NX_KEYTYPE_* constants from IOKit/hidsystem/ev_keymap.h
    enum MediaKey: Int32 {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case play = 16, next = 17, previous = 18
    }

    static func mediaKey(_ key: MediaKey) {
        for down in [true, false] {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = (Int(key.rawValue) << 16) | ((down ? 0xa : 0xb) << 8)
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                              modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8, data1: data1, data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Back / forward for the frontmost app: ⌘[ / ⌘] where `usesKeys` says the app ignores the mouse's
    /// back / forward buttons (Finder and most AppKit apps), otherwise a click of button 4 / 5.
    static func navigate(forward: Bool, usesKeys: Bool) {
        if usesKeys {
            tap(KeyCombo(keyCode: forward ? 30 : 33, modifiers: [.command]), ansi: true)   // ⌘] / ⌘[
        } else {
            mouseButtonClick(forward ? 4 : 3)
        }
    }

    /// Clicks an extra mouse button (3 = back, 4 = forward …) at the current pointer position.
    static func mouseButtonClick(_ button: Int) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        for (type, _) in [(CGEventType.otherMouseDown, true), (.otherMouseUp, false)] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func middleClick() {
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: loc, mouseButton: .center),
              let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: loc, mouseButton: .center) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: marker)
        up.setIntegerValueField(.eventSourceUserData, value: marker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
