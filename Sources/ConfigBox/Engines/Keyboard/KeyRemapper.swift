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
    /// Keyboard-limited macros that got no routing key: matched on their own key code, with the keyboard
    /// checked at match time through KeyDeviceTracker (needs Input Monitoring).
    private(set) var trackedMacroIDs: Set<UUID> = []

    /// `reserved`: key codes the tap must still see as themselves (shortcut triggers, chord keys),
    /// so they are never used as routing keys.
    func apply(simple: [SimpleModification], complex: [ComplexRule], macros: [KeyActionRule] = [], reserved: Set<UInt16> = []) {
        rules = [:]
        holds = [:]
        keyActions = [:]
        trackedMacroIDs = []
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
        // macOS delivers no key event for F21–F24, so they cannot be used here.
        var routingPool: [UInt16] = [79, 80, 90, 105, 107, 113, 106, 64, 81, 95]   // F18 F19 F20 F13 F14 F15 F16 F17 Keypad= Keypad,
        unroutable = []
        let used = Set(complex.filter(\.enabled).map(\.from))
            .union(macros.filter(\.enabled).map(\.from.keyCode))
            .union(simple.filter(\.enabled).map(\.to))
            .union(reserved)
        routingPool.removeAll { used.contains($0) }

        // One route per (source key, keyboard), shared by every rule on that key: hidutil honours
        // only one mapping per source.
        struct RouteKey: Hashable { let src: UInt16; let device: DeviceRef? }
        var routes: [RouteKey: UInt16] = [:]
        func route(_ src: UInt16, _ device: DeviceRef?) -> UInt16? {
            let key = RouteKey(src: src, device: device)
            if let r = routes[key] { return r }
            guard let r = routingPool.first, let f = KeyCodes.hidUsage(for: src), let t = KeyCodes.hidUsage(for: r) else { return nil }
            routingPool.removeFirst()
            if let dev = device { perDevice[dev, default: []].append(HIDMapping(src: f, dst: t)) }
            else { hid.append(HIDMapping(src: f, dst: t)) }
            routes[key] = r
            return r
        }

        // Key macros limited to one keyboard (or on Caps Lock) use the same per-device routing trick.
        defer { KeyDeviceTracker.shared.setNeeded(!trackedMacroIDs.isEmpty, by: "macros") }
        for m in macros where m.enabled && !m.from.isUnset {
            var src = m.from.keyCode
            if m.device != nil || src == KeyCodes.capsLock || KeyCodes.hidOnly.contains(src) {
                guard let r = route(src, m.device) else {
                    if m.device != nil && src != KeyCodes.capsLock && !KeyCodes.hidOnly.contains(src) {
                        // Out of routing keys, but an ordinary key can still be told apart by its keyboard.
                        Log.info("No free routing key for macro '\(m.name)': checking its keyboard at match time instead")
                        trackedMacroIDs.insert(m.id)
                        keyActions[src, default: []].insert(m, at: 0)   // ahead of all-keyboard macros on the key
                        continue
                    }
                    Log.error("No free routing key for macro '\(m.name)'"); unroutable.append(m.name); continue
                }
                src = r
            }
            keyActions[src, default: []].append(m)
        }

        for r in complex where r.enabled {
            var src = r.from
            let needsRoute = r.device != nil || src == KeyCodes.capsLock || KeyCodes.hidOnly.contains(src)
            if needsRoute {
                guard let rt = route(r.from, r.device) else {
                    Log.error("No free routing key for rule '\(r.name)'"); unroutable.append(r.name); continue
                }
                src = rt
            }
            rules[src] = r
        }
        HIDUtil.apply(global: hid, devices: perDevice)
    }

    var hasRules: Bool { !rules.isEmpty }
    /// Rules that could not be installed because every routing key is taken.
    private(set) var unroutable: [String] = []

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
                // Use the left/right device bit so the other side's key of the same modifier does not
                // mask this key's release; fall back to the shared flag when no device bits are set.
                let raw = event.flags.rawValue
                let isDown = raw & 0x207F != 0 ? raw & KeyCodes.deviceFlagMask(for: code) != 0
                                               : event.flags.contains(KeyCodes.modifierFlag(for: code))
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

    /// Mouse buttons and scrolling while a Mod-Tap key is held use it as a modifier (e.g. ⌃-click):
    /// the event gets the held modifiers. With `marksUsed` the alone key no longer fires on release.
    func applyHolds(toPointerEvent event: CGEvent, marksUsed: Bool) {
        guard !holds.isEmpty else { return }
        var flags = event.flags
        for k in holds.keys {
            if marksUsed { holds[k]?.used = true }
            flags.formUnion(holds[k]!.rule.heldModifiers.cgFlags)
        }
        event.flags = flags
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
