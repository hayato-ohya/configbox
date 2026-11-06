import Foundation
import CoreGraphics

/// Karabiner-style remapping.
/// - Simple modifications are delegated to hidutil (zero runtime cost).
/// - Complex rules (Mod-Tap keys / hyper keys) are implemented in the event tap.
final class KeyRemapper {
    private struct Hold {
        let rule: ComplexRule
        let down: CFAbsoluteTime
        var used = false
    }

    private var rules: [UInt16: ComplexRule] = [:]   // effective source keycode -> rule
    private var holds: [UInt16: Hold] = [:]
    /// Key macros keyed by effective source keycode (possibly a routed F-key).
    private(set) var keyActions: [UInt16: [KeyActionRule]] = [:]

    func apply(simple: [SimpleModification], complex: [ComplexRule], macros: [KeyActionRule] = []) {
        rules = [:]
        holds = [:]
        keyActions = [:]
        var hid: [HIDMapping] = []
        var perDevice: [DeviceRef: [HIDMapping]] = [:]

        for s in simple where s.enabled {
            if let f = KeyCodes.hidUsage(for: s.from), let t = KeyCodes.hidUsage(for: s.to) {
                if let dev = s.device { perDevice[dev, default: []].append(HIDMapping(src: f, dst: t)) }
                else { hid.append(HIDMapping(src: f, dst: t)) }
            }
        }
        // Keys the event tap can claim as private "routing" targets. A rule that must only react on one
        // keyboard (or that uses Caps Lock, which user space cannot intercept) gets its source key
        // rerouted to one of these at the HID level, on that keyboard only, and the tap handles the
        // routed key. Other keyboards keep the original key untouched.
        var routingPool: [UInt16] = [79, 80, 90, 105, 107, 113, 106, 64]   // F18 F19 F20 F13 F14 F15 F16 F17
        let used = Set(complex.filter(\.enabled).map(\.from)).union(macros.filter(\.enabled).map(\.from.keyCode))
        routingPool.removeAll { used.contains($0) }

        // Key macros limited to one keyboard (or on Caps Lock) use the same per-device routing trick.
        for m in macros where m.enabled && !m.from.isUnset {
            var src = m.from.keyCode
            if m.device != nil || src == KeyCodes.capsLock {
                guard let route = routingPool.first, let f = KeyCodes.hidUsage(for: src), let t = KeyCodes.hidUsage(for: route) else {
                    Log.error("No free routing key for macro '\(m.name)'"); continue
                }
                routingPool.removeFirst()
                if let dev = m.device { perDevice[dev, default: []].append(HIDMapping(src: f, dst: t)) }
                else { hid.append(HIDMapping(src: f, dst: t)) }
                src = route
            }
            keyActions[src, default: []].append(m)
        }

        for r in complex where r.enabled {
            var src = r.from
            let needsRoute = r.device != nil || src == KeyCodes.capsLock
            if needsRoute {
                guard let route = routingPool.first, let f = KeyCodes.hidUsage(for: r.from), let t = KeyCodes.hidUsage(for: route) else {
                    Log.error("No free routing key for rule '\(r.name)'"); continue
                }
                routingPool.removeFirst()
                if let dev = r.device { perDevice[dev, default: []].append(HIDMapping(src: f, dst: t)) }
                else { hid.append(HIDMapping(src: f, dst: t)) }
                src = route
            }
            rules[src] = r
        }
        HIDUtil.apply(global: hid, devices: perDevice)
    }

    var hasRules: Bool { !rules.isEmpty }

    /// Returns true when the event was consumed.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard hasRules else { return false }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let now = CFAbsoluteTimeGetCurrent()

        switch type {
        case .keyDown:
            if let rule = rules[code], !KeyCodes.isModifier(code) {
                if holds[code] == nil { holds[code] = Hold(rule: rule, down: now) }
                return true
            }
            if !holds.isEmpty {
                var flags = event.flags
                for k in holds.keys {
                    holds[k]?.used = true
                    flags.formUnion(holds[k]!.rule.heldModifiers.cgFlags)
                }
                event.flags = flags
            }
            return false

        case .keyUp:
            if let hold = holds.removeValue(forKey: code), !KeyCodes.isModifier(code) {
                fireAloneIfNeeded(hold, now: now)
                return true
            }
            if !holds.isEmpty {
                var flags = event.flags
                for h in holds.values { flags.formUnion(h.rule.heldModifiers.cgFlags) }
                event.flags = flags
            }
            return false

        case .flagsChanged:
            if let rule = rules[code], KeyCodes.isModifier(code) {
                let isDown = event.flags.contains(KeyCodes.modifierFlag(for: code))
                if isDown {
                    if holds[code] == nil { holds[code] = Hold(rule: rule, down: now) }
                } else if let hold = holds.removeValue(forKey: code) {
                    fireAloneIfNeeded(hold, now: now)
                }
                return false // let the real modifier flow through
            }
            if !holds.isEmpty {
                var flags = event.flags
                for h in holds.values { flags.formUnion(h.rule.heldModifiers.cgFlags) }
                event.flags = flags
            }
            return false

        default:
            return false
        }
    }

    private func fireAloneIfNeeded(_ hold: Hold, now: CFAbsoluteTime) {
        guard !hold.used else { return }
        guard (now - hold.down) * 1000 < Double(hold.rule.aloneTimeoutMs) else { return }
        if !hold.rule.tapActions.isEmpty {
            let actions = hold.rule.tapActions
            DispatchQueue.main.async { ActionRunner.runSequence(actions) }
        } else if let alone = hold.rule.aloneKey {
            KeySynth.tap(alone)
        }
    }
}
