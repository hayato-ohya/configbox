import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Single event tap shared by the window switcher, the key remapper and shortcut triggers.
final class InputRouter {
    static let shared = InputRouter()

    let tap = EventTap()
    let remapper = KeyRemapper()
    let chords = ChordEngine()

    /// Set while the UI records a shortcut so the recorded keys are not intercepted.
    var recording = false
    private(set) var keyboardEnabled = true
    private var treatJISAsANSI = false
    private var shortcutTriggers: [Trigger] = []

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
        remapper.apply(simple: keyboardEnabled ? config.simpleModifications : [],
                       complex: keyboardEnabled ? config.complexRules : [],
                       macros: keyboardEnabled ? config.keyActionRules : [])
        chords.apply(rules: keyboardEnabled ? config.chordRules : [])
        shortcutTriggers = config.triggers.filter { $0.enabled && $0.kind.isShortcut }
        MouseEngine.shared.apply(triggers: config.general.mouseEnabled ? config.triggers : [])
        MouseEngine.shared.backForwardButtons = config.general.mouseEnabled && config.mouse.backForwardButtons
        ScrollProcessor.shared.settings = config.general.mouseEnabled ? config.mouse : MouseSettings()
        ScrollProcessor.shared.trackpadReverse = config.general.trackpadEnabled && config.general.trackpadReverseScroll
        ScrollProcessor.shared.trackpadSpeed = config.general.trackpadEnabled ? config.general.trackpadScrollSpeed : 1.0
        PointerSettings.shared.apply(config.general.mouseEnabled ? config.mouse : MouseSettings())
        SwitcherController.shared.apply(settings: config.switcher)
        WindowSnapper.shared.settings = config.snapping
        WindowSnapper.shared.areas = config.snapAreas
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if KeySynth.isSynthetic(event) { return event }
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
        let layoutNote = rewriteJISToANSI(type, event) ? "JIS → ANSI; " : ""
        if recording { return event }

        let monitor = EventMonitor.shared
        func done(_ out: CGEvent?, _ note: String) -> CGEvent? {
            if monitor.isActive { monitor.record(type: type, event: event, note: layoutNote + note) }
            return out
        }

        if SwitcherController.shared.handle(type, event) { return done(nil, "consumed: window switcher") }

        guard keyboardEnabled else { return done(event, "pass (keyboard engine off)") }
        let flagsBefore = event.flags
        if remapper.handle(type, event) { return done(nil, "consumed: Mod-Tap key") }
        if chords.handle(type, event) { return done(nil, "held / consumed: simultaneous keys") }
        let remapNote = event.flags != flagsBefore ? "modifiers added by Mod-Tap key; " : ""

        if type == .keyDown || type == .keyUp, let macro = matchMacro(event) {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat || macro.repeats {
                    let actions = macro.actions
                    DispatchQueue.main.async { ActionRunner.runSequence(actions) }
                }
            }
            return done(nil, remapNote + "consumed: key macro “\(macro.name)”")
        }

        if type == .keyDown, let trigger = matchTrigger(event) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat || trigger.action.repeatsWhileHeld {
                let action = trigger.action
                DispatchQueue.main.async { ActionRunner.run(action) }
            }
            return done(nil, remapNote + "consumed: trigger → \(trigger.action.display)")
        }
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
        return candidates.first { $0.from.modifiers == mods }
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
