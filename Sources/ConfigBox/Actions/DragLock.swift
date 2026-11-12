import Foundation
import CoreGraphics
import CBridge

/// The "Drag" system action: presses the left button at the pointer and holds it, like clicking the trackpad
/// and moving the finger without letting go.
///
/// - Fingers still on the trackpad when it runs (a swipe or rest trigger): moving them drags, lifting them lets go.
/// - No fingers down (a tap trigger): the next touch drags and lifting it lets go; nothing touches within
///   `waitTimeout`, the button is let go.
/// One finger moves the pointer the usual way (its moves become drags); with two or more fingers ConfigBox moves
/// the pointer itself from the touch centroid, since macOS does not. Running the action again, or a click, also
/// lets go.
///
/// Pointer moves only turn into drags through a tap of their own that exists just while the button is held,
/// so the shared event tap never has to look at every mouse move.
final class DragLock {
    static let shared = DragLock()

    /// Main thread. Multiplier for pointer movement driven by several fingers.
    var pointerSpeed: Double = 1.0
    private(set) var isActive = false
    /// Set when a click ended the drag: that click's own mouse-up and drags are taken too.
    private var swallowingClick = false
    private var tap: EventTap?
    /// Set when the press landed on a window's title bar: no button is held then, the window is moved
    /// directly (the window server would not carry on a drag held by a synthetic button).
    private var follower: WindowFollower?
    private var startedEngine = false

    // Touch tracking while active (main thread).
    private var sawTouch = false
    private var lastFingers = 0
    private var lastCentroid = MTPoint(x: 0, y: 0)
    private var waitTimer: DispatchWorkItem?
    private var frames = 0, maxFingers = 0
    private var moved: Double = 0
    private static let waitTimeout: TimeInterval = 5
    /// Points per full trackpad width / height at speed 1 (the pad is about 1.6 times wider than tall).
    private static let scale = (x: 1600.0, y: 1000.0)

    /// Touch / gesture events (NSEvent rotate, begin / end gesture, gesture, magnify, swipe, smart magnify,
    /// pressure) the trackpad sends as soon as fingers touch it. The window server ends a window drag on them,
    /// so they are held back while the button is down.
    private static let gestureTypes: [CGEventMask] = [18, 19, 20, 29, 30, 31, 32, 34]
    private var seen: [UInt32: Int] = [:]

    private init() {}

    func toggle() {
        if isActive { release() } else { press() }
    }

    private func press() {
        stopTap()   // left over if the mouse-up of the click that ended the last drag never came
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            Self.gestureTypes.reduce(0) { $0 | (1 << $1) }
        // At the HID level the moves are turned into drags before the window server sees them; it would end a
        // window drag on a hardware move with the button up. The session level is only a fallback.
        var t = EventTap(mask: mask, location: .cghidEventTap)
        t.handler = { [unowned self] type, event in self.handle(type, event) }
        if !t.start() {
            Log.info("Drag: HID-level tap unavailable; using the session level")
            t = EventTap(mask: mask)
            t.handler = { [unowned self] type, event in self.handle(type, event) }
            guard t.start() else { return }
        }
        tap = t
        isActive = true
        swallowingClick = false

        let engine = TrackpadEngine.shared
        startedEngine = !engine.isRunning && engine.isAvailable
        if startedEngine { engine.start() }
        sawTouch = engine.isRunning && engine.touchingFingers > 0
        lastFingers = 0
        frames = 0; maxFingers = 0; moved = 0; seen = [:]
        engine.pauseGestures("dragLock", true)
        engine.setFrameObserver("dragLock") { [weak self] n, c in DispatchQueue.main.async { self?.frame(fingers: n, centroid: c) } }
        if !sawTouch {
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.sawTouch else { return }
                Log.info("Drag: no touch within \(Int(Self.waitTimeout)) s")
                self.release("no touch")
            }
            waitTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitTimeout, execute: timer)
        }

        let loc = CGEvent(source: nil)?.location ?? .zero
        follower = WindowFollower.windowDragTarget(at: loc).flatMap { WindowFollower(window: $0, cursor: loc) }
        if let follower {
            follower.raise()
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: loc, mouseButton: .left) {
                WindowSnapper.shared.handle(.leftMouseDown, e)
            }
        } else {
            postButton(.leftMouseDown)
        }
        Log.info("Drag: pressed (\(follower != nil ? "window" : "button"); \(sawTouch ? "\(engine.touchingFingers) finger(s) down" : "waiting for a touch"); engine \(engine.isRunning ? "running" : "not running"))")
    }

    private func release(_ why: String = "run again") {
        guard isActive else { return }
        isActive = false
        waitTimer?.cancel()
        waitTimer = nil
        let engine = TrackpadEngine.shared
        engine.setFrameObserver("dragLock", nil)
        engine.pauseGestures("dragLock", false)
        if startedEngine {
            startedEngine = false
            NotificationCenter.default.post(name: .configBoxReconcile, object: nil)   // stops it again if unused
        }
        if follower != nil {
            follower?.finish()
            follower = nil
            // The drop, for window snapping only: no button was held.
            let loc = CGEvent(source: nil)?.location ?? .zero
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) {
                e.flags = CGEventSource.flagsState(.combinedSessionState)
                WindowSnapper.shared.handle(.leftMouseUp, e)
            }
        } else {
            postButton(.leftMouseUp)
        }
        if !swallowingClick { stopTap() }
        Log.info("Drag: released (\(why); \(frames) touch frames, up to \(maxFingers) finger(s), moved \(Int(moved)) pt by ConfigBox; events \(seen.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")))")
    }

    /// Deferred: the tap may be the one whose callback is running.
    private func stopTap() {
        guard let t = tap else { return }
        tap = nil
        DispatchQueue.main.async { t.stop() }
    }

    private func frame(fingers n: Int, centroid c: MTPoint) {
        guard isActive else { return }
        if n == 0 {
            if sawTouch { release("fingers lifted") }   // all fingers lifted: let go
            lastFingers = 0
            return
        }
        frames += 1
        maxFingers = max(maxFingers, n)
        if !sawTouch {
            sawTouch = true
            waitTimer?.cancel()
            waitTimer = nil
        }
        // A finger landing or lifting shifts the centroid: measure from here.
        guard n == lastFingers else {
            lastFingers = n
            lastCentroid = c
            return
        }
        let dx = Double(c.x - lastCentroid.x), dy = Double(c.y - lastCentroid.y)
        lastCentroid = c
        guard n >= 2 else { return }   // one finger: macOS moves the pointer and the tap turns its moves into drags
        movePointer(dx: dx * Self.scale.x * pointerSpeed, dy: -dy * Self.scale.y * pointerSpeed)
    }

    private func movePointer(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let from = CGEvent(source: nil)?.location ?? .zero
        let to = Self.clamp(CGPoint(x: from.x + dx, y: from.y + dy), from: from)
        if follower != nil {
            // Only the pointer moves (a plain move of our own); the window is taken along directly.
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left) {
                e.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
                e.flags = CGEventSource.flagsState(.combinedSessionState)
                e.post(tap: .cghidEventTap)
                follow(to: to, e)
            }
        } else {
            postDragged(to: to, dx: to.x - from.x, dy: to.y - from.y)
        }
        moved += hypot(to.x - from.x, to.y - from.y)
    }

    private func follow(to loc: CGPoint, _ event: CGEvent) {
        follower?.move(to: loc)
        WindowSnapper.shared.handle(.leftMouseDragged, event)   // it only reads the place and the modifiers
    }

    /// A drag event posted at the HID level, where the window server sees it like a real one (session-level
    /// rewrites reach apps but do not reliably move windows). Posting it also moves the cursor.
    private func postDragged(to: CGPoint, dx: Double, dy: Double) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        post(e)
    }

    /// Tags the event, lets window snapping see it (the shared tap skips our own events) and posts it.
    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
        e.flags = CGEventSource.flagsState(.combinedSessionState)   // snap areas may require a modifier
        WindowSnapper.shared.handle(e.type, e)
        e.post(tap: .cghidEventTap)
    }

    /// Keeps the pointer on a display: a point off every screen stays at the edge of the one it left.
    private static func clamp(_ p: CGPoint, from: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(p) }) { return p }
        guard let b = bounds.first(where: { $0.contains(from) }) ?? bounds.first else { return from }
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if KeySynth.isSynthetic(event) { return event }
        if isActive || swallowingClick { seen[type.rawValue, default: 0] += 1 }
        if isActive && Self.gestureTypes.contains(CGEventMask(type.rawValue)) { return nil }
        switch type {
        case .mouseMoved where isActive:
            if follower != nil {
                follow(to: event.location, event)
                return event
            }
            // The button is held only synthetically, so the hardware still reports plain moves (with its own
            // button state): hold each back and post a drag of our own at the same place instead.
            postDragged(to: event.location,
                        dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                        dy: Double(event.getIntegerValueField(.mouseEventDeltaY)))
            return nil
        case .leftMouseDown where isActive:
            // A click (or tap-to-click) drops what is being dragged; the click itself goes nowhere.
            swallowingClick = true
            release("click")
            return nil
        case .leftMouseDragged where swallowingClick:
            event.type = .mouseMoved
            return event
        case .leftMouseUp where swallowingClick:
            swallowingClick = false
            stopTap()
            return nil
        default:
            return event
        }
    }

    private func postButton(_ type: CGEventType) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .left) else { return }
        post(e)
    }
}
