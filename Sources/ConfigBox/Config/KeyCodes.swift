import Foundation
import CoreGraphics

/// Mac virtual key codes, display names (US layout), and HID usages for `hidutil`.
enum KeyCodes {
    struct Key: Identifiable, Hashable {
        let code: UInt16
        let name: String
        let hid: UInt64          // full value for hidutil (page << 32 | usage); 0 = unmapped
        var id: UInt16 { code }
    }

    static let capsLock: UInt16 = 57
    static let f18: UInt16 = 79
    static let muhenkan: UInt16 = 0x100
    static let henkan: UInt16 = 0x101
    static let katakanaHiragana: UInt16 = 0x102
    /// Keys that exist only as HID usages: they can be remapped from, but never appear in a CGEvent,
    /// so they cannot be sent, and the event tap can only see them through a routing key.
    static let hidOnly: Set<UInt16> = [muhenkan, henkan, katakanaHiragana]

    private static func k(_ code: UInt16, _ name: String, _ usage: UInt64) -> Key {
        Key(code: code, name: name, hid: usage == 0 ? 0 : 0x7_0000_0000 | usage)
    }

    static let all: [Key] = [
        // Letters
        k(0, "A", 0x04), k(11, "B", 0x05), k(8, "C", 0x06), k(2, "D", 0x07), k(14, "E", 0x08), k(3, "F", 0x09),
        k(5, "G", 0x0A), k(4, "H", 0x0B), k(34, "I", 0x0C), k(38, "J", 0x0D), k(40, "K", 0x0E), k(37, "L", 0x0F),
        k(46, "M", 0x10), k(45, "N", 0x11), k(31, "O", 0x12), k(35, "P", 0x13), k(12, "Q", 0x14), k(15, "R", 0x15),
        k(1, "S", 0x16), k(17, "T", 0x17), k(32, "U", 0x18), k(9, "V", 0x19), k(13, "W", 0x1A), k(7, "X", 0x1B),
        k(16, "Y", 0x1C), k(6, "Z", 0x1D),
        // Numbers
        k(18, "1", 0x1E), k(19, "2", 0x1F), k(20, "3", 0x20), k(21, "4", 0x21), k(23, "5", 0x22),
        k(22, "6", 0x23), k(26, "7", 0x24), k(28, "8", 0x25), k(25, "9", 0x26), k(29, "0", 0x27),
        // Punctuation
        k(50, "` / 半角全角 (Windows)", 0x35), k(27, "-", 0x2D), k(24, "=", 0x2E), k(33, "[", 0x2F), k(30, "]", 0x30), k(42, "\\", 0x31),
        k(41, ";", 0x33), k(39, "'", 0x34), k(43, ",", 0x36), k(47, ".", 0x37), k(44, "/", 0x38), k(10, "§", 0x64),
        // Control keys
        k(36, "Return", 0x28), k(48, "Tab", 0x2B), k(49, "Space", 0x2C), k(51, "Delete", 0x2A), k(117, "Fwd Delete", 0x4C),
        k(53, "Escape", 0x29), k(57, "Caps Lock", 0x39), k(114, "Help / Insert (PC)", 0x49), k(110, "Menu (PC Application key)", 0x65),
        k(115, "Home", 0x4A), k(119, "End", 0x4D), k(116, "Page Up", 0x4B), k(121, "Page Down", 0x4E),
        k(123, "←", 0x50), k(124, "→", 0x4F), k(125, "↓", 0x51), k(126, "↑", 0x52),
        // Modifiers
        k(55, "Left ⌘ / Win", 0xE3), k(54, "Right ⌘ / Win", 0xE7), k(56, "Left ⇧", 0xE1), k(60, "Right ⇧", 0xE5),
        k(58, "Left ⌥ / Alt", 0xE2), k(61, "Right ⌥ / Alt", 0xE6), k(59, "Left ⌃", 0xE0), k(62, "Right ⌃", 0xE4),
        Key(code: 63, name: "fn", hid: 0xFF_0000_0003),
        // Function keys
        k(122, "F1", 0x3A), k(120, "F2", 0x3B), k(99, "F3", 0x3C), k(118, "F4", 0x3D), k(96, "F5", 0x3E), k(97, "F6", 0x3F),
        k(98, "F7", 0x40), k(100, "F8", 0x41), k(101, "F9", 0x42), k(109, "F10", 0x43), k(103, "F11", 0x44), k(111, "F12", 0x45),
        k(105, "F13 / Print Screen (PC)", 0x68), k(107, "F14 / Scroll Lock (PC)", 0x69), k(113, "F15 / Pause (PC)", 0x6A), k(106, "F16", 0x6B), k(64, "F17", 0x6C),
        k(79, "F18", 0x6D), k(80, "F19", 0x6E), k(90, "F20", 0x6F),
        // Keypad
        k(82, "Keypad 0", 0x62), k(83, "Keypad 1", 0x59), k(84, "Keypad 2", 0x5A), k(85, "Keypad 3", 0x5B), k(86, "Keypad 4", 0x5C),
        k(87, "Keypad 5", 0x5D), k(88, "Keypad 6", 0x5E), k(89, "Keypad 7", 0x5F), k(91, "Keypad 8", 0x60), k(92, "Keypad 9", 0x61),
        k(65, "Keypad .", 0x63), k(67, "Keypad *", 0x55), k(69, "Keypad +", 0x57), k(71, "Keypad Clear / Num Lock (PC)", 0x53),
        k(75, "Keypad /", 0x54), k(76, "Keypad Enter", 0x58), k(78, "Keypad -", 0x56), k(81, "Keypad =", 0x67),
        // JIS
        k(93, "¥ (JIS)", 0x89), k(94, "_ (JIS)", 0x87), k(95, "Keypad , (JIS)", 0x85), k(102, "英数 (JIS)", 0x91), k(104, "かな (JIS)", 0x90),
        // Windows JIS keys. macOS assigns them no virtual key code, so these codes are private to ConfigBox.
        k(muhenkan, "無変換 (Windows)", 0x8B), k(henkan, "変換 (Windows)", 0x8A), k(katakanaHiragana, "カタカナ/ひらがな (Windows)", 0x88),
    ]

    static let byCode: [UInt16: Key] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    static func name(for code: UInt16) -> String { byCode[code]?.name ?? "Key \(code)" }
    static let byHID: [UInt64: Key] = Dictionary(all.filter { $0.hid != 0 }.map { ($0.hid, $0) }, uniquingKeysWith: { a, _ in a })
    static func name(forHID usage: UInt64) -> String {
        byHID[usage]?.name ?? String(format: "0x%llX", usage)
    }
    static func hidUsage(for code: UInt16) -> UInt64? {
        guard let k = byCode[code], k.hid != 0 else { return nil }
        return k.hid
    }

    /// Keys for which macOS sets the fn (secondary function) flag on its own, so the flag carries no
    /// information about whether the user is holding fn: arrows, navigation keys, F-keys, forward delete.
    static let impliesFn: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121, 117, 114,
                                         122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                         105, 107, 113, 106, 64, 79, 80, 90]

    /// Modifiers of a key event with the implicit fn flag removed where it is meaningless.
    static func modifiers(for code: UInt16, flags: CGEventFlags) -> Modifiers {
        var m = Modifiers(cgFlags: flags)
        if impliesFn.contains(code) { m.remove(.function) }
        return m
    }

    static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    static func isModifier(_ code: UInt16) -> Bool { modifierCodes.contains(code) }

    static func modifierFlag(for code: UInt16) -> CGEventFlags {
        switch code {
        case 54, 55: .maskCommand
        case 56, 60: .maskShift
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 63: .maskSecondaryFn
        case 57: .maskAlphaShift
        default: []
        }
    }

    /// Keys sensible as a remap source/destination, sorted for UI pickers.
    static let pickable: [Key] = all.filter { !hidOnly.contains($0.code) }
    /// Same, for the key being remapped: also offers keys that exist only at the HID level.
    static let pickableSources: [Key] = all
}
