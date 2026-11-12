import AppKit
import CoreGraphics
import CBridge

/// "Keep dragging after the press is released": a drag started by pressing the trackpad and moving goes on
/// when the pressure is let go, for as long as a finger stays on the trackpad. Lifting the finger drops.
///
/// The press itself is the real one, so macOS starts the drag as usual. What happens at the release depends
/// on who runs the drag:
/// - An app (text, files, sliders …): the mouse-up is held back and the finger's moves are turned into drags,
///   so the app never notices the release until the finger lifts.
/// - The window server (moving a window): it follows the hardware ahead of every event tap and ends its drag
///   at the real release whatever a tap does. So the window is moved through Accessibility from then on, and
///   window snapping is told about the moves and the final drop.
/// A click that did not move while pressed stays a click: moving the pointer after it does not drag.
final class DragHold {
    static let shared = DragHold()

    enum Disposition {
        case pass          // handle the event as usual
        case swallow       // keep it from the apps
        case skipSnapper   // let the apps have it, but window snapping must not see it
    }

    /// Main thread.
    var enabled = false {
        didSet {
            guard !enabled else { return }
            cancelPress()
            if isHolding { finish("turned off") }
        }
    }

    private enum Phase {
        case idle
        case pressed(start: CGPoint, moved: Bool)
        case holdingApp
        case holdingWindow
    }
    private var phase: Phase = .idle
    var isHolding: Bool {
        switch phase {
        case .holdingApp, .holdingWindow: true
        default: false
        }
    }

    private var tap: EventTap?
    private var watchdog: DispatchSourceTimer?
    private var fakeFingers: Int?
    private var follower: WindowFollower?
    private var moves = 0
    /// How far the pointer must travel while pressed for the drag to be kept after the release.
    private static let startDistance: CGFloat = 10
    private static let observerKey = "dragHold"

    private init() {}

    private var fingers: Int {
        if let fakeFingers { return fakeFingers }
        let engine = TrackpadEngine.shared
        return engine.isRunning ? engine.touchingFingers : 0
    }

    /// Test aid (`--debug-hooks`): pretend this many fingers rest on the trackpad; nil = the real count again.
    func debugFingers(_ n: Int?) {
        fakeFingers = n
        if n == 0, isHolding { finish("fingers lifted") }
    }

    /// The press was taken by a trigger: it is not a drag.
    func cancelPress() {
        if case .pressed = phase { phase = .idle }
    }

    /// Called from the shared event tap for every real left-button event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Disposition {
        switch type {
        case .leftMouseDown:
            switch phase {
            case .holdingApp:
                // Pressed again while the button is still held for the apps: they must get the release first,
                // so the press is replayed after it.
                finish("pressed again")
                postButton(.leftMouseDown, at: event.location, clickState: event.getIntegerValueField(.mouseEventClickState))
                phase = enabled ? .pressed(start: event.location, moved: false) : .idle
                return .swallow
            case .holdingWindow:
                finish("pressed again")
            default:
                break
            }
            phase = enabled ? .pressed(start: event.location, moved: false) : .idle
            return .pass

        case .leftMouseDragged:
            if case .pressed(let start, false) = phase {
                let loc = event.location
                if hypot(loc.x - start.x, loc.y - start.y) >= Self.startDistance { phase = .pressed(start: start, moved: true) }
            }
            return .pass

        case .leftMouseUp:
            guard case .pressed(_, true) = phase, enabled, fingers >= 1 else {
                cancelPress()
                return .pass
            }
            if let window = WindowSnapper.shared.currentDraggedWindow(),
               let follower = WindowFollower(window: window, cursor: event.location) {
                self.follower = follower
                phase = .holdingWindow
                begin()
                Log.info("Drag hold: keeps moving the window")
                return .skipSnapper   // the apps get the release (the window server's drag is over anyway)
            }
            phase = .holdingApp
            begin()
            Log.info("Drag hold: keeps the button down")
            return .swallow

        default:
            return .pass
        }
    }

    private func begin() {
        moves = 0
        // At the HID level the retyped moves reach the shared tap (and so every other feature) as drags.
        let mask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        var t = EventTap(mask: mask, location: .cghidEventTap)
        t.handler = { [unowned self] type, event in self.moved(type, event) }
        if !t.start() {
            t = EventTap(mask: mask)
            t.handler = { [unowned self] type, event in self.moved(type, event) }
            _ = t.start()
        }
        tap = t

        let engine = TrackpadEngine.shared
        engine.pauseGestures(Self.observerKey, true)
        engine.setFrameObserver(Self.observerKey) { [weak self] n, _ in
            guard n == 0 else { return }
            DispatchQueue.main.async {
                guard let self, self.fakeFingers == nil, self.isHolding else { return }
                self.finish("fingers lifted")
            }
        }
        // Frames can go missing (engine restarted, trackpad disconnected): never keep the button down for good.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.isHolding, self.fingers == 0 else { return }
            self.finish("no finger on the trackpad")
        }
        timer.resume()
        watchdog = timer
    }

    private func finish(_ why: String) {
        let ended = phase
        phase = .idle
        watchdog?.cancel()
        watchdog = nil
        let engine = TrackpadEngine.shared
        engine.setFrameObserver(Self.observerKey, nil)
        engine.pauseGestures(Self.observerKey, false)
        if let t = tap {
            tap = nil
            DispatchQueue.main.async { t.stop() }   // it may be the tap whose callback is running
        }
        let loc = CGEvent(source: nil)?.location ?? .zero
        switch ended {
        case .holdingApp:
            postButton(.leftMouseUp, at: loc, clickState: 1)
        case .holdingWindow:
            follower?.finish()
            follower = nil
            // The drop, for window snapping only: the apps had their mouse-up when the press was released.
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) {
                e.flags = CGEventSource.flagsState(.combinedSessionState)
                WindowSnapper.shared.handle(.leftMouseUp, e)
            }
        default:
            return
        }
        Log.info("Drag hold: dropped (\(why); \(moves) moves)")
    }

    /// The extra tap that exists while holding: every pointer move of the finger.
    private func moved(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .mouseMoved, !KeySynth.isSynthetic(event) else { return event }
        switch phase {
        case .holdingApp:
            moves += 1
            if tap?.location == .cghidEventTap {
                event.type = .leftMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                return event
            }
            // Session level: a retyped event would not reach the shared tap, so post a drag of our own.
            guard let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: event.location, mouseButton: .left) else { return event }
            e.setIntegerValueField(.mouseEventDeltaX, value: event.getIntegerValueField(.mouseEventDeltaX))
            e.setIntegerValueField(.mouseEventDeltaY, value: event.getIntegerValueField(.mouseEventDeltaY))
            post(e, clickState: 1)
            return nil

        case .holdingWindow:
            moves += 1
            follower?.move(to: event.location)
            WindowSnapper.shared.handle(.leftMouseDragged, event)   // it only reads the place and the modifiers
            return event

        default:
            return event
        }
    }

    private func postButton(_ type: CGEventType, at loc: CGPoint, clickState: Int64) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .left) else { return }
        post(e, clickState: clickState)
    }

    /// Tags the event, lets window snapping see it (the shared tap skips our own events) and posts it.
    private func post(_ e: CGEvent, clickState: Int64) {
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
        e.flags = CGEventSource.flagsState(.combinedSessionState)
        WindowSnapper.shared.handle(e.type, e)
        e.post(tap: .cghidEventTap)
    }
}
