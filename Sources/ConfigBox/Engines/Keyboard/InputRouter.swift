import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Single event tap shared by the window switcher, the key remapper and shortcut triggers.
final class InputRouter {
    static let shared = InputRouter()

    let tap = EventTap()
    let remapper = KeyRemapper()
    let chords = ChordEngine()
    let mediaFKeys = MediaFunctionKeys()

    /// Set while the UI records a shortcut so the recorded keys are not intercepted.
    var recording = false
    private(set) var keyboardEnabled = true
    private var treatJISAsANSI = false
    private var shortcutTriggers: [Trigger] = []
    /// Keys whose press a macro or trigger took: their release is taken too, whatever modifiers are held
    /// by then, and no other release is, so apps never get half of a key press.
    private var swallowedKeys: Set<UInt16> = []

    private static let ansiKeyboardType: Int64 = 40

    private init() {}

    func start() {
        tap.handler = { [unowned self] type, event in self.handle(type, event) }
        if !tap.start() {
            // Retry until Accessibility is granted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
        }
    }

    func apply(config: Config) {
        keyboardEnabled = config.general.keyboardEnabled
        treatJISAsANSI = keyboardEnabled && config.general.treatJISAsANSI
        KeySynth.treatJISAsANSI = treatJISAsANSI
        mediaFKeys.enabled = keyboardEnabled && config.general.mediaKeysOnOtherKeyboards
        shortcutTriggers = config.triggers.filter { $0.enabled && $0.kind.isShortcut }
        swallowedKeys = []   // rules changed: a stray key up is harmless, a missing one is not
        // Keys the tap must keep seeing as themselves: never hand them out as routing keys.
        var reserved = Set(shortcutTriggers.compactMap { t -> UInt16? in
            if case .shortcut(let combo) = t.kind { return combo.keyCode } else { return nil }
        })
        if keyboardEnabled { reserved.formUnion(config.chordRules.filter(\.enabled).flatMap(\.keys)) }
        remapper.apply(simple: keyboardEnabled ? config.simpleModifications : [],
                       complex: keyboardEnabled ? config.complexRules : [],
                       macros: keyboardEnabled ? config.keyActionRules : [],
                       reserved: reserved)
        chords.apply(rules: keyboardEnabled ? config.chordRules : [])
        MouseEngine.shared.apply(triggers: config.general.mouseEnabled ? config.triggers : [])
        MouseEngine.shared.backForwardButtons = config.general.mouseEnabled && config.mouse.backForwardButtons
        MouseEngine.shared.backForwardKeyApps = config.general.mouseEnabled ? Set(config.mouse.backForwardKeyApps) : []
        ScrollProcessor.shared.settings = config.general.mouseEnabled ? config.mouse : MouseSettings()
        ScrollProcessor.shared.mouseEnabled = config.general.mouseEnabled
        ScrollProcessor.shared.trackpadReverse = config.general.trackpadEnabled && config.general.trackpadReverseScroll
        ScrollProcessor.shared.trackpadSpeed = config.general.trackpadEnabled ? config.general.trackpadScrollSpeed : 1.0
        PointerSettings.shared.apply(config.general.mouseEnabled ? config.mouse : MouseSettings())
        SwitcherController.shared.apply(settings: config.switcher)
        WindowSnapper.shared.settings = config.snapping
        WindowSnapper.shared.areas = config.snapAreas
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if KeySynth.isSynthetic(event) { return event }
        // Keys replayed by the chord engine already went through the switcher, the remapper and the
        // chord engine; they only still need macro / trigger matching.
        let isChordReplay = event.getIntegerValueField(.eventSourceUserData) == KeySynth.chordReplayMarker
        switch type {
        // A held Mod-Tap key acts as its modifiers for the mouse too. Pressing a button or scrolling uses
        // the key (no tap on release); momentum scrolling continues on its own, so it does not count.
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            remapper.applyHolds(toPointerEvent: event, marksUsed: true)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            remapper.applyHolds(toPointerEvent: event, marksUsed: false)
        case .scrollWheel:
            remapper.applyHolds(toPointerEvent: event, marksUsed: event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
        default:
            break
        }
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if !recording && TrackpadEngine.shared.handleClick(type, event) { return nil }
            if !recording && MouseEngine.shared.handle(type, event) { return nil }
            WindowSnapper.shared.handle(type, event)
            return event
        case .scrollWheel:
            if TrackpadEngine.shared.shouldSuppressScroll(event) { return nil }
            if !recording && MouseEngine.shared.handle(type, event) { return nil }
            return ScrollProcessor.shared.process(event)
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            if !recording && TrackpadEngine.shared.handleClick(type, event) { return nil }
            if !recording && MouseEngine.shared.handle(type, event) { return nil }
            return event
        default:
            break
        }
        let layoutNote = !isChordReplay && rewriteJISToANSI(type, event) ? "JIS → ANSI; " : ""
        if type == .flagsChanged { mediaFKeys.noteFlagsChanged(event) }
        if recording { return event }

        let monitor = EventMonitor.shared
        func done(_ out: CGEvent?, _ note: String) -> CGEvent? {
            if monitor.isActive { monitor.record(type: type, event: event, note: layoutNote + note) }
            return out
        }

        if !isChordReplay && SwitcherController.shared.handle(type, event) { return done(nil, "consumed: window switcher") }

        guard keyboardEnabled else { return done(event, "pass (keyboard engine off)") }
        let flagsBefore = event.flags
        if !isChordReplay {
            if remapper.handle(type, event) { return done(nil, "consumed: Mod-Tap key") }
            if chords.handle(type, event) { return done(nil, "held / consumed: simultaneous keys") }
        }
        let remapNote = event.flags != flagsBefore ? "modifiers added by Mod-Tap key; " : ""

        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, swallowedKeys.remove(code) != nil {
            return done(nil, remapNote + "consumed: release of a handled key")
        }

        if type == .keyDown, let macro = matchMacro(event) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { swallowedKeys.insert(code) }   // a repeat's first press went to the app, and so must its release
            if !isRepeat || macro.repeats {
                let actions = macro.actions
                DispatchQueue.main.async { ActionRunner.runSequence(actions) }
            }
            return done(nil, remapNote + "consumed: key macro “\(macro.name)”")
        }

        if type == .keyDown, let trigger = matchTrigger(event) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { swallowedKeys.insert(code) }
            if !isRepeat || trigger.action.repeatsWhileHeld {
                let action = trigger.action
                DispatchQueue.main.async { ActionRunner.run(action) }
            }
            return done(nil, remapNote + "consumed: trigger → \(trigger.action.display)")
        }
        if type == .keyDown, let action = mediaFKeys.action(for: event) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { swallowedKeys.insert(code) }
            if !isRepeat || action.repeatsWhileHeld {
                DispatchQueue.main.async { SystemActions.perform(action) }
            }
            return done(nil, remapNote + "consumed: F-key as media key → \(action.title)")
        }
        if type == .keyDown { swallowedKeys.remove(code) }   // this press reaches the app, so its release must too
        return done(event, remapNote + "pass")
    }

    /// Makes the receiving app pick the ANSI table of the input source for a key on a JIS keyboard.
    /// A HID remap cannot do this: on JIS, Shift+2 differs from ANSI while plain 2 does not.
    private func rewriteJISToANSI(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard treatJISAsANSI, type == .keyDown || type == .keyUp || type == .flagsChanged else { return false }
        let current = event.getIntegerValueField(.keyboardEventKeyboardType)
        guard KBGetLayoutType(Int16(truncatingIfNeeded: current)) == kKeyboardJIS else { return false }
        event.setIntegerValueField(.keyboardEventKeyboardType, value: Self.ansiKeyboardType)
        return true
    }

    private func matchMacro(_ event: CGEvent) -> KeyActionRule? {
        guard !remapper.keyActions.isEmpty else { return nil }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let candidates = remapper.keyActions[code] else { return nil }
        let mods = KeyCodes.modifiers(for: code, flags: event.flags)
        return candidates.first { m in
            guard m.from.modifiers == mods else { return false }
            guard remapper.trackedMacroIDs.contains(m.id), let dev = m.device else { return true }
            guard let d = KeyDeviceTracker.shared.device(forKeyCode: code) else { return false }
            return d.vendorId == dev.vendorId && d.productId == dev.productId
        }
    }

    private func matchTrigger(_ event: CGEvent) -> Trigger? {
        guard !shortcutTriggers.isEmpty else { return nil }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let mods = KeyCodes.modifiers(for: code, flags: event.flags)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var global: Trigger?
        for t in shortcutTriggers {
            guard case .shortcut(let combo) = t.kind, combo.keyCode == code, combo.modifiers == mods else { continue }
            if let app = t.appBundleId {
                if app == front { return t }
            } else if global == nil {
                global = t
            }
        }
        return global
    }
}

extension Action {
    var repeatsWhileHeld: Bool {
        switch self {
        case .system(let s): s.repeatsWhileHeld
        case .keyboardShortcut: true     // behaves like the key it stands for (arrows, delete, …)
        default: false
        }
    }
}
