import AppKit
import CoreGraphics

/// BetterTouchTool "Normal Mouse" triggers: button clicks with modifiers, modifier + scroll,
/// and button-hold gestures (press a button and move). Fed by the shared event tap.
final class MouseEngine {
    static let shared = MouseEngine()

    private(set) var triggers: [Trigger] = []
    /// Buttons 4 / 5 send ⌘[ / ⌘] (back / forward) when no trigger claims them.
    var backForwardButtons = false
    /// Apps that ignore buttons 4 / 5: there the buttons send ⌘[ / ⌘] even with the option above off.
    var backForwardKeyApps: Set<String> = []
    private var hasClick = false, hasScroll = false, hasGesture = false

    // Gesture / click state
    private var gestureButton: MouseButton?
    private var gestureStart = CGPoint.zero
    private var gestureFlags: CGEventFlags = []
    private var gestureMods: Modifiers = []
    private var swallowUpFor: MouseButton?
    private var lastScrollFire: CFAbsoluteTime = 0

    private init() {}

    func apply(triggers: [Trigger]) {
        self.triggers = triggers.filter { $0.enabled && $0.kind.isMouse }
        hasClick = false; hasScroll = false; hasGesture = false
        for t in self.triggers {
            guard case .mouse(let m) = t.kind else { continue }
            switch m {
            case .click: hasClick = true
            case .scroll: hasScroll = true
            case .gesture: hasGesture = true
            }
        }
    }

    var isEmpty: Bool { triggers.isEmpty && !backForwardButtons && backForwardKeyApps.isEmpty }

    // MARK: Event handling (returns true when consumed)

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard !isEmpty else { return false }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return buttonDown(event)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return gestureButton != nil && button(of: event) == gestureButton
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return buttonUp(event)
        case .scrollWheel:
            return scroll(event)
        default:
            return false
        }
    }

    private func button(of e: CGEvent) -> MouseButton? {
        MouseButton(rawValue: Int(e.getIntegerValueField(.mouseEventButtonNumber)))
    }

    private func match(_ pred: (MouseTrigger) -> Bool) -> Trigger? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var global: Trigger?
        for t in triggers {
            guard case .mouse(let m) = t.kind, pred(m) else { continue }
            if let app = t.appBundleId { if app == front { return t } } else if global == nil { global = t }
        }
        return global
    }

    private func buttonDown(_ e: CGEvent) -> Bool {
        guard let b = button(of: e) else { return false }
        let mods = Modifiers(cgFlags: e.flags)
        let clicks = Int(e.getIntegerValueField(.mouseEventClickState))

        // Gestures may use a bare right/middle/extra button: a press without movement is replayed as a click.
        if hasGesture, b != .left || !mods.isEmpty,
           match({ if case .gesture(let gb, _, let m) = $0 { return gb == b && m == mods } else { return false } }) != nil {
            gestureButton = b
            gestureStart = e.location
            gestureFlags = e.flags
            gestureMods = mods
            EventMonitor.shared.record(custom: "\(b.title) button down", note: "mouse gesture started")
            return true
        }
        if b.needsModifier && mods.isEmpty { return false }
        if hasClick, let t = match({ if case .click(let cb, let m, let c) = $0 { return cb == b && m == mods && c == max(1, min(clicks, 2)) } else { return false } }) {
            swallowUpFor = b
            run(t)
            return true
        }
        if mods.isEmpty, b == .button4 || b == .button5,
           backForwardButtons || backForwardKeyApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
            swallowUpFor = b
            KeySynth.navigate(forward: b == .button5, usesKeys: true)   // ⌘[ / ⌘]
            return true
        }
        // A double-click trigger without a single-click one: let the first click through, catch the second.
        return false
    }

    private func buttonUp(_ e: CGEvent) -> Bool {
        guard let b = button(of: e) else { return false }
        if gestureButton == b {
            gestureButton = nil
            let p = e.location
            let dx = p.x - gestureStart.x, dy = p.y - gestureStart.y
            if max(abs(dx), abs(dy)) >= 30 {
                let dir: Direction = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)   // CG y grows downward
                let mods = gestureMods
                if let t = match({ if case .gesture(let gb, let d, let m) = $0 { return gb == b && d == dir && m == mods } else { return false } }) {
                    EventMonitor.shared.record(custom: "\(b.title) button move \(dir.title)", note: "→ trigger")
                    run(t)
                } else {
                    EventMonitor.shared.record(custom: "\(b.title) button move \(dir.title)", note: "no trigger")
                }
            } else {
                // No movement: deliver the click the user actually made.
                replayClick(b, at: gestureStart, flags: gestureFlags)
            }
            return true
        }
        if swallowUpFor == b { swallowUpFor = nil; return true }
        return false
    }

    private func scroll(_ e: CGEvent) -> Bool {
        guard hasScroll else { return false }
        let mods = Modifiers(cgFlags: e.flags)
        guard !mods.isEmpty else { return false }
        guard match({ if case .scroll(_, let m) = $0 { return m == mods } else { return false } }) != nil else { return false }
        // Consume the whole modified scroll stream, but fire at most every 150 ms and never on momentum.
        if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
        let v = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let h = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        guard abs(v) + abs(h) > 0.5 else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrollFire > 0.15 else { return true }
        let dir: Direction = abs(v) >= abs(h) ? (v > 0 ? .up : .down) : (h > 0 ? .left : .right)
        if let t = match({ if case .scroll(let d, let m) = $0 { return d == dir && m == mods } else { return false } }) {
            lastScrollFire = now
            EventMonitor.shared.record(custom: "\(mods.symbols) scroll \(dir.title)", note: "→ trigger")
            run(t)
        }
        return true
    }

    private func run(_ t: Trigger) {
        let action = t.action
        DispatchQueue.main.async { ActionRunner.run(action) }
    }

    /// Re-posts a click that was held back while waiting for a gesture.
    private func replayClick(_ b: MouseButton, at p: CGPoint, flags: CGEventFlags) {
        let (down, up): (CGEventType, CGEventType)
        let cgButton: CGMouseButton
        switch b {
        case .left: (down, up, cgButton) = (.leftMouseDown, .leftMouseUp, .left)
        case .right: (down, up, cgButton) = (.rightMouseDown, .rightMouseUp, .right)
        default: (down, up, cgButton) = (.otherMouseDown, .otherMouseUp, .center)
        }
        for (type, isDown) in [(down, true), (up, false)] {
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { continue }
            ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b.rawValue))
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
            ev.flags = flags
            ev.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
            ev.post(tap: .cghidEventTap)
            _ = isDown
        }
    }
}
