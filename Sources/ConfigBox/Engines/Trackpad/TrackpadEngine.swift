import Foundation
import CoreGraphics
import CBridge

/// Reads raw multitouch frames from the private MultitouchSupport framework and recognizes
/// N-finger taps, clicks and swipes, with where each finger was (for region and resting-finger triggers). System gestures that macOS itself handles still happen; disable the
/// overlapping ones in System Settings > Trackpad if you remap them here.
final class TrackpadEngine {
    static let shared = TrackpadEngine()

    /// Settings written on the main thread (AppDelegate) and read every frame on the multitouch callback
    /// thread; all access goes through `lock`. `process()` takes one snapshot per frame.
    private struct Settings {
        var onGesture: ((GestureInput) -> Void)?
        /// Every enabled gesture trigger: decides which taps are worth looking at (one finger, a finger
        /// resting elsewhere) and when a single tap must wait for a possible double tap.
        var gestures: [Gesture] = []
        var regionSize: Double = TouchRegion.defaultSize
        var swipeThreshold: Float = 0.10
        var tapMaxDuration: Double = 0.25
        var tapMaxMovement: Float = 0.04
        var suppressScroll = true
        var suppressTail: Double = 0.3
        var cooldown: Double = 0.15
        var axisRatio: Float = 1.5
        var maxTouchSize: Float = 0
        var configuredFingerCounts: Set<Int> = []
        var doubleTapInterval: Double = 0.5
        var frameObservers: [String: (Int, MTPoint) -> Void] = [:]
        var gesturePausers: Set<String> = []
        var gesturesPaused: Bool { !gesturePausers.isEmpty }
    }
    private let lock = NSLock()
    private var settings = Settings()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func read<T>(_ kp: KeyPath<Settings, T>) -> T { locked { settings[keyPath: kp] } }
    private func write<T>(_ kp: WritableKeyPath<Settings, T>, _ v: T) { locked { settings[keyPath: kp] = v } }

    var onGesture: ((GestureInput) -> Void)? { get { read(\.onGesture) } set { write(\.onGesture, newValue) } }
    var gestures: [Gesture] { get { read(\.gestures) } set { write(\.gestures, newValue) } }
    var regionSize: Double { get { read(\.regionSize) } set { write(\.regionSize, newValue) } }
    /// Asked on the event tap (main thread) when the trackpad is pressed: true = a trigger took the click,
    /// so the button events are swallowed.
    var onClick: ((GestureInput) -> Bool)?
    /// Fingers on the pad (a resting one included) for which a click trigger exists; other clicks are never
    /// looked at.
    var clickFingerCounts: Set<Int> = []
    /// The same for double-click triggers (main thread, like `clickFingerCounts`).
    var doubleClickFingerCounts: Set<Int> = []
    /// Longest gap between the end of the first tap and the start of the second (the system double-click speed).
    var doubleTapInterval: Double { get { read(\.doubleTapInterval) } set { write(\.doubleTapInterval, newValue) } }
    /// Registers (or with nil removes) a listener for every frame's finger count and centroid (normalized,
    /// y up). It runs on the multitouch thread. Used by the drag features while they hold the button.
    func setFrameObserver(_ key: String, _ observer: ((Int, MTPoint) -> Void)?) {
        locked { settings.frameObservers[key] = observer }
    }
    /// While anyone pauses gestures (a drag is being held), touches only move the pointer: no tap / swipe
    /// fires for any touch sequence that was under way during that time.
    func pauseGestures(_ key: String, _ paused: Bool) {
        locked { if paused { settings.gesturePausers.insert(key) } else { settings.gesturePausers.remove(key) } }
    }
    var swipeThreshold: Float { get { read(\.swipeThreshold) } set { write(\.swipeThreshold, newValue) } }
    var tapMaxDuration: Double { get { read(\.tapMaxDuration) } set { write(\.tapMaxDuration, newValue) } }
    /// How far the fingers may drift during a tap (normalized units); a quick flick beyond it is no tap.
    var tapMaxMovement: Float { get { read(\.tapMaxMovement) } set { write(\.tapMaxMovement, newValue) } }
    var suppressScroll: Bool { get { read(\.suppressScroll) } set { write(\.suppressScroll, newValue) } }
    var suppressTail: Double { get { read(\.suppressTail) } set { write(\.suppressTail, newValue) } }
    var cooldown: Double { get { read(\.cooldown) } set { write(\.cooldown, newValue) } }
    var axisRatio: Float { get { read(\.axisRatio) } set { write(\.axisRatio, newValue) } }
    var maxTouchSize: Float { get { read(\.maxTouchSize) } set { write(\.maxTouchSize, newValue) } }
    private var _lastEmit: CFAbsoluteTime = 0             // guarded by `lock`
    /// A tap that may still become the first half of a double tap (guarded by `lock`).
    private var _pendingTap: (touches: [TouchSample], end: Double, generation: Int)?
    private var _tapGeneration = 0
    private(set) var deviceCount = 0
    /// Finger counts (≥ 3) for which at least one gesture trigger exists. Like BetterTouchTool, scrolling is
    /// blocked from the moment that many fingers touch until all fingers are up again, so neither a late
    /// third finger nor lifting fingers one by one turns into a two-finger scroll.
    var configuredFingerCounts: Set<Int> {
        get { read(\.configuredFingerCounts) } set { write(\.configuredFingerCounts, newValue) }
    }

    // State shared between the multitouch callback thread and the event tap (main thread); guarded by `lock`.
    private var _suppressUntil: CFAbsoluteTime = 0
    private var _touching = 0
    private var _clickedInSequence = false
    private var _currentTouches: [TouchSample] = []
    private var _lastFrame: CFAbsoluteTime = 0
    private var _framesSinceStart = 0
    private var startedAt: CFAbsoluteTime = 0             // main thread
    private var lastRecovery: CFAbsoluteTime = 0          // main thread
    private var fruitlessRecoveries = 0                   // main thread: restarts after which no touch came
    /// The fingers of the last finished touch sequence, and when it ended (for tap-to-click).
    private var _lastLift: (touches: [TouchSample], time: CFAbsoluteTime) = ([], 0)
    /// Scroll suppression after a fired swipe (read from the event tap on the main thread).
    private var suppressUntil: CFAbsoluteTime { get { locked { _suppressUntil } } set { locked { _suppressUntil = newValue } } }
    /// Fingers down in the latest frame (read on the main thread).
    private var touching: Int { get { locked { _touching } } set { locked { _touching = newValue } } }
    var touchingFingers: Int { touching }
    /// A click happened during this touch sequence: no tap / swipe for it.
    private var clickedInSequence: Bool {
        get { locked { _clickedInSequence } } set { locked { _clickedInSequence = newValue } }
    }

    // Scroll suppression state used on the main thread only.
    private var suppressingMomentum = false
    private var blockingSequence = false                 // this touch sequence reached a configured finger count

    private var devices: CFArray?
    private(set) var isRunning = false
    /// Set while the Event Viewer's trackpad page is open so touches are streamed even without gesture triggers.
    var viewerDemand = false

    // Gesture state (accessed on the multitouch callback thread only)
    private var maxFingers = 0
    private var startCentroid = MTPoint(x: 0, y: 0)
    private var startTime: Double = 0                    // last time a finger landed (swipe measurement)
    private var sequenceStart: Double = 0                // first finger of this touch sequence landed
    private var done = false
    private var maxMove: Float = 0                       // farthest the fingers travelled since the last landing
    private var swallowUntilUp: CGEventType?             // main thread: mouse-up type that ends a taken click
    private var tracks: [Int32: TouchSample] = [:]       // fingers down now, by identifier
    private var sequenceTouches: [Int32: TouchSample] = [:]   // every finger of this touch sequence
    private var recentLifts: [(sample: TouchSample, lift: Double)] = []   // for taps next to a resting finger

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
        startedAt = CFAbsoluteTimeGetCurrent()
        locked { _framesSinceStart = 0 }
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

    /// Internal (not private) so tests can feed frames.
    func process(_ touches: UnsafeBufferPointer<MTTouch>, timestamp: Double) {
        let cfg = locked { settings }   // one consistent snapshot per frame
        var n = 0
        var cx: Float = 0, cy: Float = 0
        var seen: [Int32: TouchSample] = [:]
        for t in touches where t.state == 3 || t.state == 4 {
            if cfg.maxTouchSize > 0 && t.size > cfg.maxTouchSize { continue }   // palm / resting hand
            n += 1
            cx += t.normalized.pos.x
            cy += t.normalized.pos.y
            let p = CGPoint(x: CGFloat(t.normalized.pos.x), y: CGFloat(t.normalized.pos.y))
            if var s = tracks[t.identifier] {
                s.position = p
                s.moved = max(s.moved, Float(hypot(p.x - s.start.x, p.y - s.start.y)))
                seen[t.identifier] = s
            } else {
                seen[t.identifier] = TouchSample(start: p, position: p, landed: timestamp, moved: 0)
            }
        }
        var liftedNow = false
        for (id, s) in tracks where seen[id] == nil {
            recentLifts.append((s, timestamp))
            sequenceTouches[id] = s
            liftedNow = true
        }
        for (id, s) in seen { sequenceTouches[id] = s }
        tracks = seen
        let current = Array(seen.values)
        let first = locked { () -> Bool in
            _touching = n
            _currentTouches = current
            _lastFrame = CFAbsoluteTimeGetCurrent()
            _framesSinceStart += 1
            return _framesSinceStart == 1
        }
        if first { Log.info("Trackpad engine: receiving touches") }
        if !cfg.frameObservers.isEmpty {
            let centroid = n > 0 ? MTPoint(x: cx / Float(n), y: cy / Float(n)) : MTPoint(x: 0, y: 0)
            for observer in cfg.frameObservers.values { observer(n, centroid) }
        }
        if EventMonitor.shared.trackpadViewerActive {
            EventMonitor.shared.publish(touches: touches.filter { $0.state >= 2 && $0.state <= 5 }.map {
                TouchPoint(id: Int($0.identifier), x: CGFloat($0.normalized.pos.x), y: CGFloat($0.normalized.pos.y),
                           size: CGFloat($0.size), state: Int($0.state))
            })
        }

        if n == 0 {
            let fingersOfSequence = Array(sequenceTouches.values)
            locked { _lastLift = (fingersOfSequence, CFAbsoluteTimeGetCurrent()) }
            let oneFingerTaps = cfg.gestures.contains { $0.fingers == 1 && $0.anchor == nil && ($0.kind == .tap || $0.kind == .doubleTap) }
            if (maxFingers >= 2 || (maxFingers == 1 && oneFingerTaps)) && !done && !clickedInSequence {
                // Measured from the last landing and from the first finger of the sequence, so a finger brushing
                // in at the end of a long scroll is not a tap.
                // A quick flick that stays below the swipe threshold moved too far to be a tap.
                if timestamp - startTime < cfg.tapMaxDuration && timestamp - sequenceStart < cfg.tapMaxDuration
                    && maxMove <= cfg.tapMaxMovement {
                    tapped(fingersOfSequence, start: sequenceStart, end: timestamp, cfg)
                }
            }
            if blockingSequence { suppressUntil = CFAbsoluteTimeGetCurrent() + cfg.suppressTail }   // tail covers the lift-off
            blockingSequence = false
            maxFingers = 0
            done = false
            clickedInSequence = false
            sequenceTouches = [:]
            recentLifts = []
            return
        }
        if liftedNow { anchoredTap(at: timestamp, cfg) }
        if cfg.gesturesPaused { done = true }
        if cfg.suppressScroll && n >= 3 && cfg.configuredFingerCounts.contains(n) { blockingSequence = true }
        if blockingSequence { suppressUntil = CFAbsoluteTimeGetCurrent() + 0.5 }   // keep blocking while any finger is down

        let c = MTPoint(x: cx / Float(n), y: cy / Float(n))
        if maxFingers == 0 || n > maxFingers {
            // A new finger landed: (re)start measurement from here.
            if maxFingers == 0 { sequenceStart = timestamp }
            maxFingers = n
            startCentroid = c
            startTime = timestamp
            maxMove = 0
            done = cfg.gesturesPaused
            return
        }
        if n < maxFingers {
            // Lifting fingers one by one: not a swipe, and only a tap if all came off quickly (handled when n == 0).
            if timestamp - startTime >= cfg.tapMaxDuration { done = true }
            return
        }
        let dx = c.x - startCentroid.x, dy = c.y - startCentroid.y
        let dist = (dx * dx + dy * dy).squareRoot()
        maxMove = max(maxMove, dist)
        guard !done, !clickedInSequence, n >= 2 else { return }

        if dist > cfg.swipeThreshold {
            let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
            guard minor == 0 || major / minor >= cfg.axisRatio else { return }   // too diagonal: keep waiting
            let kind: GestureKind
            if abs(dx) > abs(dy) { kind = dx > 0 ? .swipeRight : .swipeLeft } else { kind = dy > 0 ? .swipeUp : .swipeDown }
            done = true
            emit(GestureInput(kind: kind, touches: current), cfg)
        }
    }

    /// Some fingers just tapped while others stay down: a tap next to a resting finger when every finger left
    /// down was already resting (down well before the tapping ones landed and not moving).
    private func anchoredTap(at timestamp: Double, _ cfg: Settings) {
        guard !cfg.gesturesPaused, !clickedInSequence,
              cfg.gestures.contains(where: { $0.anchor != nil && $0.kind == .tap }) else { return }
        recentLifts.removeAll { timestamp - $0.lift > cfg.tapMaxDuration }
        let group = recentLifts.map(\.sample)
        guard let firstLanding = group.map(\.landed).min(), !tracks.isEmpty else { return }
        let quick = recentLifts.allSatisfy { $0.lift - $0.sample.landed < cfg.tapMaxDuration && $0.sample.moved <= cfg.tapMaxMovement }
        let resting = Array(tracks.values)
        let still = resting.allSatisfy { $0.moved <= GestureMatcher.restMovement && $0.landed <= firstLanding - GestureMatcher.restLead }
        guard quick && still else { return }
        recentLifts = []
        done = true   // the rest of this sequence is no swipe or plain tap
        emit(GestureInput(kind: .tap, touches: group, resting: resting), cfg)
    }

    /// A finished tap. When a double-tap trigger could match it, a second tap starting within the double-click
    /// interval makes a double tap; otherwise the single tap fires once that chance has passed (interval + max
    /// tap duration after the first tap ended, so a second tap in progress can still finish).
    private func tapped(_ touches: [TouchSample], start: Double, end: Double, _ cfg: Settings) {
        let tap = GestureInput(kind: .tap, touches: touches)
        let double = GestureInput(kind: .doubleTap, touches: touches)
        let first: [TouchSample]? = locked {
            guard let p = _pendingTap, p.touches.count == touches.count, start - p.end <= cfg.doubleTapInterval else { return nil }
            _pendingTap = nil
            _tapGeneration += 1
            return p.touches
        }
        if let first {
            if GestureMatcher.anyMatch(cfg.gestures, double, size: cfg.regionSize) {
                emit(double, cfg)
                return
            }
            // The second tap was somewhere else: the first one counts on its own.
            emit(GestureInput(kind: .tap, touches: first), cfg)
        }
        guard GestureMatcher.anyMatch(cfg.gestures, double, size: cfg.regionSize) else {
            emit(tap, cfg)
            return
        }
        let generation: Int = locked {
            _tapGeneration += 1
            _pendingTap = (touches, end, _tapGeneration)
            return _tapGeneration
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.doubleTapInterval + cfg.tapMaxDuration) { [self] in
            let single = locked { () -> Bool in
                guard let p = _pendingTap, p.generation == generation else { return false }
                _pendingTap = nil
                return true
            }
            if single { emit(tap, cfg) }
        }
    }

    /// The fingers on the pad now plus those of a touch sequence that ended a moment ago: a tap-to-click
    /// arrives about when the fingers lift.
    private func recentTouches() -> [TouchSample] {
        locked {
            let current = _currentTouches
            guard CFAbsoluteTimeGetCurrent() - _lastLift.time < 0.5 else { return current }
            return current + _lastLift.touches.filter { lifted in !current.contains { $0.landed == lifted.landed && $0.start == lifted.start } }
        }
    }

    /// Called from the event tap for every left / right button event: true = swallow it.
    /// A physical click (or a tap-to-click) made while N fingers rest on the trackpad becomes an N-finger click
    /// gesture when a trigger wants it; the matching drags and mouse-up are swallowed too.
    func handleClick(_ type: CGEventType, _ e: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let up: CGEventType = type == .leftMouseDown ? .leftMouseUp : .rightMouseUp
            if let pending = swallowUntilUp {
                // Still waiting for the mouse-up of a taken click. If this is another press of the same button,
                // or that button is no longer down, the mouse-up was lost: stop swallowing and handle this click.
                let button: CGMouseButton = pending == .leftMouseUp ? .left : .right
                if pending != up && CGEventSource.buttonState(.combinedSessionState, button: button) { return true }
                swallowUntilUp = nil
            }
            let n = touching
            guard isRunning else { return false }
            // A physical click (pressure > 0) ends any tap for this touch sequence, even when no click trigger
            // takes it. Tap-to-click reports zero pressure, so the tap gesture still wins there.
            let physical = e.getDoubleValueField(.mouseEventPressure) > 0
            if physical { clickedInSequence = true }
            if !physical, tapTakesClick() {
                // A tap trigger runs for this tap (from the multitouch frames); its tap-to-click must not click too.
                swallowUntilUp = up
                return true
            }
            guard n >= 1 else { return false }
            // The system counts the clicks (same timing and distance rules as any double-click). Without a
            // click trigger the first click of a double click goes through as an ordinary click.
            let isDouble = e.getIntegerValueField(.mouseEventClickState) == 2 && doubleClickFingerCounts.contains(n)
            let touches = locked { _currentTouches }
            guard isDouble || clickFingerCounts.contains(n), let onClick,
                  onClick(GestureInput(kind: isDouble ? .doubleClick : .click, touches: touches)) else { return false }
            clickedInSequence = true
            swallowUntilUp = up
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

    /// Whether the fingers of a tap-to-click make a tap some trigger takes (only triggers limited to a region
    /// or with a resting finger: a plain N-finger tap trigger has always let tap-to-click through).
    private func tapTakesClick() -> Bool {
        let cfg = locked { settings }
        let special = cfg.gestures.filter { ($0.region != nil || $0.anchor != nil) && ($0.kind == .tap || $0.kind == .doubleTap) }
        guard !special.isEmpty else { return false }
        let touches = recentTouches()
        guard !touches.isEmpty else { return false }
        for kind in [GestureKind.tap, .doubleTap] {
            if GestureMatcher.anyMatch(special, GestureInput(kind: kind, touches: touches), size: cfg.regionSize) { return true }
            // Only some of them may have tapped: try each sub-group that contains the newest finger.
            let newest = touches.max { $0.landed < $1.landed }!
            let rest = touches.filter { $0 != newest }
            if GestureMatcher.anyMatch(special, GestureInput(kind: kind, touches: [newest], resting: rest), size: cfg.regionSize)
                || GestureMatcher.anyMatch(special, GestureInput(kind: kind, touches: [newest]), size: cfg.regionSize) { return true }
        }
        return false
    }

    /// A trackpad scroll while no touch frame has come in for a while: the devices were registered before the
    /// driver was ready (seen right after login) or have been replaced. Registering them again fixes it.
    private func recoverIfDeaf(_ e: CGEvent) {
        guard isRunning, e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
              e.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let (lastFrame, frames) = locked { (_lastFrame, _framesSinceStart) }
        if frames > 0 { fruitlessRecoveries = 0 }
        // Smooth-scrolling mice send continuous scrolls too: give up once restarts bring no touches.
        guard fruitlessRecoveries < 2, now - startedAt > 2, now - lastRecovery > 10, now - lastFrame > 1 else { return }
        lastRecovery = now
        if frames == 0 { fruitlessRecoveries += 1 }
        Log.info("Trackpad engine: the trackpad scrolls but no touches arrive; restarting the engine")
        restart()
    }

    /// Called from the event tap for every scroll event: true = swallow it.
    func shouldSuppressScroll(_ e: CGEvent) -> Bool {
        recoverIfDeaf(e)
        // Several fingers moving during a Drag action move the pointer, not the page.
        if (DragLock.shared.isActive || DragHold.shared.isHolding) && e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return true }
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

    private func emit(_ g: GestureInput, _ cfg: Settings) {
        guard let onGesture = cfg.onGesture else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let ready = locked { () -> Bool in
            guard now - _lastEmit >= cfg.cooldown else { return false }
            _lastEmit = now
            return true
        }
        guard ready else { return }
        DispatchQueue.main.async { onGesture(g) }
    }
}
