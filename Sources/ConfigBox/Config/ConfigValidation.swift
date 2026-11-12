import Foundation

/// Finds entries that are saved fine but cannot work as written: shortcuts that never fire, and rules
/// that compete for the same key. The UI shows the returned sentences next to the entry; nothing is
/// changed or blocked. Disabled entries are never reported and never count as a competitor.
enum ConfigValidation {
    private static func sameKeyboard(_ a: DeviceRef?, _ b: DeviceRef?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.vendorId == b.vendorId && a.productId == b.productId
        default: false
        }
    }

    private static func label(_ name: String, fallback: String) -> String { name.isEmpty ? fallback : name }

    // MARK: Triggers

    static func issues(for t: Trigger, in c: Config) -> [String] {
        guard t.enabled else { return [] }
        var out: [String] = []
        if case .shortcut(let combo) = t.kind {
            guard !combo.isUnset else { return [] }
            if KeyCodes.isModifier(combo.keyCode) {
                out.append(L("A modifier key on its own cannot be a shortcut, so this trigger never runs. Use it together with another key, or make it a Mod-Tap key in Key Remapping."))
            } else if combo.modifiers.subtracting(.shift).isEmpty && !KeyCodes.impliesFn.contains(combo.keyCode) {
                out.append(L("This shortcut has no ⌘, ⌥, ⌃ or fn, so the key can no longer be typed while the trigger is on."))
            }
            let sc = c.switcher.shortcut
            if c.switcher.enabled, !sc.modifiers.isEmpty, sc.keyCode == combo.keyCode, combo.modifiers.subtracting(.shift) == sc.modifiers {
                out.append(L("The window switcher uses this shortcut and takes it first, so this trigger never runs."))
            }
            if c.general.keyboardEnabled, let m = c.keyActionRules.first(where: { $0.enabled && $0.from == combo }) {
                out.append(L("The Key → Actions rule “%@” uses the same key and runs instead of this trigger.", label(m.name, fallback: m.from.display)))
            }
        }
        if case .gesture(let g) = t.kind, g.fingers == 1 {
            if !g.kind.isStationary {
                out.append(L("One-finger swipes move the pointer, so this trigger never runs. Use two or more fingers."))
            } else if g.region == nil && g.anchor == nil {
                out.append(L("A one-finger gesture needs a region or a resting finger; anywhere on the trackpad it would be every ordinary tap or click, so this trigger never runs."))
            }
        }
        if case .gesture(let g) = t.kind, let r = g.region, r == g.anchor {
            out.append(L("The resting finger and the other fingers use the same region. This works, but both must fit into it."))
        }
        if c.triggers.contains(where: { $0.id != t.id && $0.enabled && $0.kind == t.kind && $0.appBundleId == t.appBundleId }) {
            out.append(L("Another trigger in this list uses the same input. Only the first of them runs."))
        }
        return out
    }

    // MARK: Key remapping

    static func issues(for m: SimpleModification, in c: Config) -> [String] {
        guard m.enabled else { return [] }
        var out: [String] = []
        if c.simpleModifications.contains(where: { $0.id != m.id && $0.enabled && $0.from == m.from && sameKeyboard($0.device, m.device) }) {
            out.append(L("Another simple modification remaps the same key on the same keyboard. Only one of them applies."))
        }
        for r in c.complexRules where r.enabled && r.from == m.from && sameKeyboard(r.device, m.device) {
            out.append(L("“%@” uses the same key on the same keyboard. The two conflict, and only one of them works.", label(r.name, fallback: KeyCodes.name(for: r.from))))
        }
        for r in c.keyActionRules where r.enabled && !r.from.isUnset && r.from.keyCode == m.from && sameKeyboard(r.device, m.device) {
            out.append(L("“%@” uses the same key on the same keyboard. The two conflict, and only one of them works.", label(r.name, fallback: r.from.display)))
        }
        return out
    }

    static func issues(for r: KeyActionRule, in c: Config) -> [String] {
        guard r.enabled, !r.from.isUnset else { return [] }
        var out: [String] = []
        if let m = c.simpleModifications.first(where: { $0.enabled && $0.from == r.from.keyCode && sameKeyboard($0.device, r.device) }) {
            out.append(L("“%@” uses the same key on the same keyboard. The two conflict, and only one of them works.",
                         "\(KeyCodes.name(for: m.from)) → \(KeyCodes.name(for: m.to))"))
        }
        if let t = c.complexRules.first(where: { $0.enabled && $0.from == r.from.keyCode && sameKeyboard($0.device, r.device) }) {
            out.append(L("The Mod-Tap rule “%@” takes this key first, so this rule never runs.", label(t.name, fallback: KeyCodes.name(for: t.from))))
        }
        if c.keyActionRules.contains(where: { $0.id != r.id && $0.enabled && $0.from == r.from && sameKeyboard($0.device, r.device) }) {
            out.append(L("Another Key → Actions rule uses the same key on the same keyboard. Only the first of them runs."))
        }
        return out
    }

    static func issues(for r: ComplexRule, in c: Config) -> [String] {
        guard r.enabled else { return [] }
        var out: [String] = []
        if let m = c.simpleModifications.first(where: { $0.enabled && $0.from == r.from && sameKeyboard($0.device, r.device) }) {
            out.append(L("“%@” uses the same key on the same keyboard. The two conflict, and only one of them works.",
                         "\(KeyCodes.name(for: m.from)) → \(KeyCodes.name(for: m.to))"))
        }
        if c.complexRules.contains(where: { $0.id != r.id && $0.enabled && $0.from == r.from && sameKeyboard($0.device, r.device) }) {
            out.append(L("Another Mod-Tap rule uses the same key on the same keyboard. Only one of them applies."))
        }
        return out
    }
}
