import Foundation
import CoreGraphics
import CBridge

/// Reads raw multitouch frames from the private MultitouchSupport framework and recognizes
/// N-finger taps, clicks and swipes. System gestures that macOS itself handles still happen; disable the
/// overlapping ones in System Settings > Trackpad if you remap them here.
final class TrackpadEngine {
    static let shared = TrackpadEngine()

    var onGesture: ((Gesture) -> Void)?
    /// Asked on the event tap (main thread) when the trackpad is pressed with N fingers: true = a trigger
    /// took the click, so the button events are swallowed.
    var onClick: ((Gesture) -> Bool)?
    /// Finger counts (≥ 2) for which a click trigger exists; other clicks are never looked at.
    var clickFingerCounts: Set<Int> = []
    var swipeThreshold: Float = 0.10
    var tapMaxDuration: Double = 0.25
    var suppressScroll = true
    var suppressTail: Double = 0.3
    var cooldown: Double = 0.15
    var axisRatio: Float = 1.5
    var maxTouchSize: Float = 0
    private var lastEmit: CFAbsoluteTime = 0
    private(set) var deviceCount = 0
    /// Finger counts (≥ 3) for which at least one gesture trigger exists. Like BetterTouchTool, scrolling is
    /// blocked from the moment that many fingers touch until all fingers are up again, so neither a late
    /// third finger nor lifting fingers one by one turns into a two-finger scroll.
    var configuredFingerCounts: Set<Int> = []

    // Scroll suppression after a fired swipe (read from the event tap on the main thread).
    private var suppressUntil: CFAbsoluteTime = 0       // atomic enough for our purposes (Double store)
    private var suppressingMomentum = false
    private var blockingSequence = false                 // this touch sequence reached a configured finger count

    private var devices: CFArray?
    private(set) var isRunning = false
    /// Set while the Event Viewer's trackpad page is open so touches are streamed even without gesture triggers.
    var viewerDemand = false

    // Gesture state (accessed on the multitouch callback thread only)
    private var maxFingers = 0
    private var startCentroid = MTPoint(x: 0, y: 0)
    private var startTime: Double = 0
    private var done = false
    private var touching = 0                             // fingers down in the latest frame (read on the main thread)
    private var clickedInSequence = false                // a click trigger fired: no tap / swipe for this touch sequence
    private var swallowUntilUp: CGEventType?             // main thread: mouse-up type that ends a taken click

    private init() {}

    var isAvailable: Bool { cb_mt_available() != 0 }

    func start() {
        guard !isRunning, isAvailable else { return }
        guard let list = cb_mt_create_device_list() else { return }
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            cb_mt_register(dev, TrackpadEngine.callback)
            cb_mt_start(dev)
        }
        devices = list
        deviceCount = count
        isRunning = true
        Log.info("Trackpad engine started with \(count) device(s)")
    }

    func stop() {
        guard isRunning, let list = devices else { return }
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            cb_mt_unregister(dev, TrackpadEngine.callback)
            cb_mt_stop(dev)
        }
        devices = nil
        isRunning = false
    }

    func restart() {
        stop()
        start()
    }

    private static let callback: MTContactCallback = { _, touches, count, timestamp, _ in
        guard let touches, count >= 0 else { return 0 }
        TrackpadEngine.shared.process(UnsafeBufferPointer(start: touches, count: Int(count)), timestamp: timestamp)
        return 0
    }

    private func process(_ touches: UnsafeBufferPointer<MTTouch>, timestamp: Double) {
        var n = 0
        var cx: Float = 0, cy: Float = 0
        for t in touches where t.state == 3 || t.state == 4 {
            if maxTouchSize > 0 && t.size > maxTouchSize { continue }   // palm / resting hand
            n += 1
            cx += t.normalized.pos.x
            cy += t.normalized.pos.y
        }
        touching = n
        if EventMonitor.shared.trackpadViewerActive {
            EventMonitor.shared.publish(touches: touches.filter { $0.state >= 2 && $0.state <= 5 }.map {
                TouchPoint(id: Int($0.identifier), x: CGFloat($0.normalized.pos.x), y: CGFloat($0.normalized.pos.y),
                           size: CGFloat($0.size), state: Int($0.state))
            })
        }

        if n == 0 {
            if maxFingers >= 2 && !done && !clickedInSequence {
                let dur = timestamp - startTime
                if dur < tapMaxDuration { emit(Gesture(fingers: maxFingers, kind: .tap)) }
            }
            if blockingSequence { suppressUntil = CFAbsoluteTimeGetCurrent() + suppressTail }   // tail covers the lift-off
            blockingSequence = false
            maxFingers = 0
            done = false
            clickedInSequence = false
            return
        }
        if suppressScroll && n >= 3 && configuredFingerCounts.contains(n) { blockingSequence = true }
        if blockingSequence { suppressUntil = CFAbsoluteTimeGetCurrent() + 0.5 }   // keep blocking while any finger is down

        let c = MTPoint(x: cx / Float(n), y: cy / Float(n))
        if maxFingers == 0 || n > maxFingers {
            // A new finger landed: (re)start measurement from here.
            maxFingers = n
            startCentroid = c
            startTime = timestamp
            done = false
            return
        }
        if n < maxFingers {
            // Lifting fingers one by one: not a swipe, and only a tap if all came off quickly (handled when n == 0).
            if timestamp - startTime >= tapMaxDuration { done = true }
            return
        }
        guard !done, !clickedInSequence, n >= 2 else { return }

        let dx = c.x - startCentroid.x, dy = c.y - startCentroid.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist > swipeThreshold {
            let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
            guard minor == 0 || major / minor >= axisRatio else { return }   // too diagonal: keep waiting
            let kind: GestureKind
            if abs(dx) > abs(dy) { kind = dx > 0 ? .swipeRight : .swipeLeft } else { kind = dy > 0 ? .swipeUp : .swipeDown }
            done = true
            emit(Gesture(fingers: n, kind: kind))
        } else if timestamp - startTime > tapMaxDuration && dist < 0.02 {
            // Held still for too long: neither a tap nor a swipe candidate anymore? Keep waiting for a swipe.
        }
    }

    /// Called from the event tap for every left / right button event: true = swallow it.
    /// A physical click (or a tap-to-click) made while N fingers rest on the trackpad becomes an N-finger click
    /// gesture when a trigger wants it; the matching drags and mouse-up are swallowed too.
    func handleClick(_ type: CGEventType, _ e: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            if swallowUntilUp != nil { return true }
            let n = touching
            guard isRunning, n >= 2, clickFingerCounts.contains(n), let onClick,
                  onClick(Gesture(fingers: n, kind: .click)) else { return false }
            clickedInSequence = true
            swallowUntilUp = type == .leftMouseDown ? .leftMouseUp : .rightMouseUp
            return true
        case .leftMouseDragged, .rightMouseDragged:
            return swallowUntilUp != nil
        case .leftMouseUp, .rightMouseUp:
            guard let up = swallowUntilUp else { return false }
            if up == type { swallowUntilUp = nil }
            return true
        default:
            return false
        }
    }

    /// Called from the event tap for every scroll event: true = swallow it.
    func shouldSuppressScroll(_ e: CGEvent) -> Bool {
        guard suppressScroll else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let momentum = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if now < suppressUntil {
            if momentum != 0 { suppressingMomentum = true }
            return true
        }
        if suppressingMomentum {
            if momentum == 0 { suppressingMomentum = false; return false }   // a new, real scroll started
            if momentum == 3 { suppressingMomentum = false }                 // kCGMomentumScrollPhaseEnd
            return true
        }
        return false
    }

    private func emit(_ g: Gesture) {
        guard let onGesture else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= cooldown else { return }
        lastEmit = now
        DispatchQueue.main.async { onGesture(g) }
    }
}
