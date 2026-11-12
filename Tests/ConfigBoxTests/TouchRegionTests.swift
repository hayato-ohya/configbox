import XCTest
import CBridge
@testable import ConfigBox

final class TouchRegionTests: XCTestCase {
    private func sample(_ x: CGFloat, _ y: CGFloat, landed: Double = 0, moved: Float = 0) -> TouchSample {
        TouchSample(start: CGPoint(x: x, y: y), position: CGPoint(x: x, y: y), landed: landed, moved: moved)
    }

    func testRegionGeometry() {
        let s = 0.15
        XCTAssertTrue(TouchRegion.topRight.contains(CGPoint(x: 0.95, y: 0.9), size: s))
        XCTAssertFalse(TouchRegion.topRight.contains(CGPoint(x: 0.95, y: 0.5), size: s))
        XCTAssertTrue(TouchRegion.bottomLeft.contains(CGPoint(x: 0, y: 0), size: s))     // the border counts
        XCTAssertTrue(TouchRegion.leftEdge.contains(CGPoint(x: 0.1, y: 0.5), size: s))
        XCTAssertFalse(TouchRegion.center.contains(CGPoint(x: 0.1, y: 0.5), size: s))
        XCTAssertTrue(TouchRegion.center.contains(CGPoint(x: 0.5, y: 0.5), size: s))
        // About square on the pad: deeper vertically by the aspect ratio.
        XCTAssertEqual(TouchRegion.topLeft.rect(size: s).height, CGFloat(s) * TouchRegion.aspect, accuracy: 0.0001)
    }

    func testRegionMatchingAndSpecificity() {
        let corner = Gesture(fingers: 2, kind: .tap, region: .topRight)
        let half = Gesture(fingers: 2, kind: .tap, region: .rightHalf)
        let anywhere = Gesture(fingers: 2, kind: .tap)
        let input = GestureInput(kind: .tap, touches: [sample(0.93, 0.9), sample(0.97, 0.9)])
        let c = GestureMatcher.score(corner, input, size: 0.15)
        let h = GestureMatcher.score(half, input, size: 0.15)
        let a = GestureMatcher.score(anywhere, input, size: 0.15)
        XCTAssertNotNil(c); XCTAssertNotNil(h); XCTAssertNotNil(a)
        XCTAssertGreaterThan(c!, h!); XCTAssertGreaterThan(h!, a!)
        XCTAssertNil(GestureMatcher.score(corner, GestureInput(kind: .tap, touches: [sample(0.5, 0.5), sample(0.6, 0.5)]), size: 0.15))
        XCTAssertNil(GestureMatcher.score(corner, GestureInput(kind: .click, touches: input.touches), size: 0.15))
        XCTAssertNotNil(GestureMatcher.score(Gesture(fingers: 1, kind: .tap, region: .topRight), GestureInput(kind: .tap, touches: [sample(0.95, 0.9)]), size: 0.15))
    }

    func testSwipeUsesStartPosition() {
        let g = Gesture(fingers: 2, kind: .swipeUp, region: .bottomEdge)
        var a = sample(0.4, 0.05), b = sample(0.5, 0.05)
        a.position = CGPoint(x: 0.4, y: 0.6); b.position = CGPoint(x: 0.5, y: 0.6)
        XCTAssertNotNil(GestureMatcher.score(g, GestureInput(kind: .swipeUp, touches: [a, b]), size: 0.15))
    }

    func testAnchoredClick() {
        let g = Gesture(fingers: 1, kind: .click, region: .rightHalf, anchor: .leftEdge)
        let rest = sample(0.05, 0.5, landed: 0)
        let press = sample(0.8, 0.5, landed: 1)
        XCTAssertNotNil(GestureMatcher.score(g, GestureInput(kind: .click, touches: [rest, press]), size: 0.15))
        // Both landed together: a two-finger click, not one next to a resting finger.
        XCTAssertNil(GestureMatcher.score(g, GestureInput(kind: .click, touches: [sample(0.05, 0.5, landed: 1), press]), size: 0.15))
        // A plain two-finger click trigger still matches the same fingers, but less specifically.
        let plain = Gesture(fingers: 2, kind: .click)
        let p = GestureMatcher.score(plain, GestureInput(kind: .click, touches: [rest, press]), size: 0.15)
        let s = GestureMatcher.score(g, GestureInput(kind: .click, touches: [rest, press]), size: 0.15)
        XCTAssertNotNil(p); XCTAssertGreaterThan(s!, p!)
        // An anchored trigger never matches a plain input of the acting fingers alone, and vice versa.
        XCTAssertNil(GestureMatcher.score(Gesture(fingers: 1, kind: .tap, anchor: .leftEdge), GestureInput(kind: .tap, touches: [press]), size: 0.15))
        XCTAssertNil(GestureMatcher.score(Gesture(fingers: 1, kind: .tap), GestureInput(kind: .tap, touches: [press], resting: [rest]), size: 0.15))
    }

    func testOldGesturesDecodeUnchanged() throws {
        let json = #"{"fingers":3,"kind":"tap"}"#.data(using: .utf8)!
        let g = try JSONDecoder().decode(Gesture.self, from: json)
        XCTAssertEqual(g, Gesture(fingers: 3, kind: .tap))
        let out = String(data: try JSONEncoder().encode(g), encoding: .utf8)!
        XCTAssertFalse(out.contains("region")); XCTAssertFalse(out.contains("anchor"))
    }
}

/// Feeds synthetic multitouch frames to the engine.
final class TrackpadRecognitionTests: XCTestCase {
    private let engine = TrackpadEngine.shared
    private var received: [GestureInput] = []

    override func setUp() {
        received = []
        engine.cooldown = 0
        engine.tapMaxDuration = 0.25
        engine.tapMaxMovement = 0.04
        engine.doubleTapInterval = 0.3
        engine.regionSize = 0.15
        engine.onGesture = { [weak self] in self?.received.append($0) }
    }

    private func frame(_ fingers: [(id: Int32, x: Float, y: Float)], at t: Double) {
        var touches = fingers.map { f -> MTTouch in
            var m = MTTouch()
            m.identifier = f.id
            m.state = 4
            m.size = 1
            m.normalized.pos = MTPoint(x: f.x, y: f.y)
            return m
        }
        touches.withUnsafeBufferPointer { engine.process($0, timestamp: t) }
    }

    private func drain(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOneFingerCornerTap() {
        engine.gestures = [Gesture(fingers: 1, kind: .tap, region: .topRight)]
        frame([(1, 0.95, 0.9)], at: 10.00)
        frame([(1, 0.95, 0.9)], at: 10.05)
        frame([], at: 10.10)
        drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.kind, .tap)
        XCTAssertEqual(received.first?.touches.count, 1)
        XCTAssertEqual(received.first?.touches.first?.position.x ?? 0, 0.95, accuracy: 0.001)
    }

    func testOneFingerTapsIgnoredWithoutTrigger() {
        engine.gestures = [Gesture(fingers: 3, kind: .tap)]
        frame([(1, 0.5, 0.5)], at: 20.00)
        frame([], at: 20.10)
        drain()
        XCTAssertTrue(received.isEmpty)
    }

    func testTapNextToRestingFinger() {
        engine.gestures = [Gesture(fingers: 1, kind: .tap, region: .rightHalf, anchor: .leftEdge)]
        frame([(1, 0.05, 0.5)], at: 30.00)                       // resting finger
        frame([(1, 0.05, 0.5)], at: 30.30)
        frame([(1, 0.05, 0.5), (2, 0.8, 0.5)], at: 30.40)        // tapping finger lands…
        frame([(1, 0.05, 0.5), (2, 0.8, 0.5)], at: 30.45)
        frame([(1, 0.05, 0.5)], at: 30.50)                       // …and lifts quickly
        drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.touches.count, 1)
        XCTAssertEqual(received.first?.resting.count, 1)
        frame([], at: 31.50)                                     // the resting finger lifts: no further tap
        drain()
        XCTAssertEqual(received.count, 1)
    }

    func testTwoFingersTogetherAreNoAnchoredTap() {
        engine.gestures = [Gesture(fingers: 1, kind: .tap, anchor: .leftEdge), Gesture(fingers: 2, kind: .tap)]
        frame([(1, 0.05, 0.5), (2, 0.8, 0.5)], at: 40.00)
        frame([(1, 0.05, 0.5)], at: 40.08)                       // lifted one by one
        frame([], at: 40.12)
        drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.touches.count, 2)
        XCTAssertTrue(received.first?.resting.isEmpty ?? false)
    }

    func testDoubleTapOnlyWaitsInItsRegion() {
        engine.gestures = [Gesture(fingers: 2, kind: .doubleTap, region: .topHalf), Gesture(fingers: 2, kind: .tap)]
        // Bottom half: no double tap possible there, so the tap fires at once.
        frame([(1, 0.4, 0.2), (2, 0.5, 0.2)], at: 50.00)
        frame([], at: 50.10)
        drain()
        XCTAssertEqual(received.map(\.kind), [.tap])
        // Top half: two taps make a double tap.
        received = []
        frame([(3, 0.4, 0.8), (4, 0.5, 0.8)], at: 51.00)
        frame([], at: 51.10)
        frame([(5, 0.4, 0.8), (6, 0.5, 0.8)], at: 51.20)
        frame([], at: 51.30)
        drain()
        XCTAssertEqual(received.map(\.kind), [.doubleTap])
        // Top half, single: waits, then fires the tap.
        received = []
        frame([(7, 0.4, 0.8), (8, 0.5, 0.8)], at: 52.00)
        frame([], at: 52.10)
        drain()
        XCTAssertTrue(received.isEmpty)
        drain(0.7)
        XCTAssertEqual(received.map(\.kind), [.tap])
    }

    func testPlainThreeFingerSwipeAndTapStillWork() {
        engine.gestures = [Gesture(fingers: 3, kind: .swipeLeft), Gesture(fingers: 3, kind: .tap), Gesture(fingers: 3, kind: .click)]
        engine.swipeThreshold = 0.1
        engine.axisRatio = 1.5
        frame([(1, 0.6, 0.5), (2, 0.65, 0.5), (3, 0.7, 0.5)], at: 70.00)
        frame([(1, 0.55, 0.5), (2, 0.60, 0.5), (3, 0.65, 0.5)], at: 70.05)
        frame([(1, 0.40, 0.5), (2, 0.45, 0.5), (3, 0.50, 0.5)], at: 70.10)
        frame([], at: 70.20)
        frame([(4, 0.4, 0.5), (5, 0.5, 0.5), (6, 0.6, 0.5)], at: 71.00)
        frame([], at: 71.10)
        drain()
        XCTAssertEqual(received.map(\.kind), [.swipeLeft, .tap])
        let size = 0.15
        XCTAssertNotNil(GestureMatcher.score(Gesture(fingers: 3, kind: .swipeLeft), received[0], size: size))
        XCTAssertNotNil(GestureMatcher.score(Gesture(fingers: 3, kind: .tap), received[1], size: size))
    }

    func testSwipeCarriesStartPositions() {
        engine.gestures = [Gesture(fingers: 2, kind: .swipeUp, region: .bottomEdge)]
        engine.swipeThreshold = 0.1
        engine.axisRatio = 1.5
        frame([(1, 0.4, 0.05), (2, 0.5, 0.05)], at: 60.00)
        frame([(1, 0.4, 0.10), (2, 0.5, 0.10)], at: 60.05)
        frame([(1, 0.4, 0.30), (2, 0.5, 0.30)], at: 60.10)
        frame([], at: 60.20)
        drain()
        XCTAssertEqual(received.first?.kind, .swipeUp)
        XCTAssertEqual(received.first?.touches.first?.start.y ?? 1, 0.05, accuracy: 0.001)
    }
}

final class GestureValidationTests: XCTestCase {
    func testOneFingerNeedsRegion() {
        var c = Config()
        let t = Trigger(kind: .gesture(Gesture(fingers: 1, kind: .tap)), action: .none)
        c.triggers = [t]
        XCTAssertFalse(ConfigValidation.issues(for: t, in: c).isEmpty)
        XCTAssertNil(GestureMatcher.score(Gesture(fingers: 1, kind: .tap),
                                          GestureInput(kind: .tap, touches: [TouchSample(start: .zero, position: .zero, landed: 0, moved: 0)]), size: 0.15))
        let ok = Trigger(kind: .gesture(Gesture(fingers: 1, kind: .tap, region: .topLeft)), action: .none)
        c.triggers = [ok]
        XCTAssertTrue(ConfigValidation.issues(for: ok, in: c).isEmpty)
    }
}
