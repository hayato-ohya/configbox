import AppKit
import CoreGraphics

/// Posts synthetic input events. Every event is tagged so our own tap ignores it.
enum KeySynth {
    static let marker: Int64 = 0x4346_4258 // "CFBX"

    static func isSynthetic(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func tap(_ combo: KeyCombo) {
        post(combo, down: true)
        post(combo, down: false)
    }

    static func post(_ combo: KeyCombo, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: down) else { return }
        e.flags = combo.modifiers.cgFlags
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (any script) via Unicode key events, 20 characters per event.
    static func type(_ text: String) {
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 20, chars.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
            i += 20
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
