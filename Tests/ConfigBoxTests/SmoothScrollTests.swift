import XCTest
@testable import ConfigBox

final class SmoothScrollTests: XCTestCase {
    /// Runs the scroll to its end and returns every event it would send.
    private func drain(_ s: inout SmoothScroll, limit: Int = 2000) -> [SmoothScroll.Step] {
        var steps: [SmoothScroll.Step] = []
        var ticks = 0
        while s.isActive && ticks < limit {
            if let step = s.step() { steps.append(step) }
            ticks += 1
        }
        XCTAssertLessThan(ticks, limit, "the scroll never finished")
        return steps
    }

    func testOneNotchDeliversExactlyItsDistanceAsOneGesture() {
        var s = SmoothScroll()
        s.add(v: 40, h: 0)
        let steps = drain(&s)
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dv) }, 40)
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dh) }, 0)
        XCTAssertEqual(steps.first?.phase, .began)
        XCTAssertEqual(steps.last?.phase, .ended)
        XCTAssertTrue(steps.dropFirst().dropLast().allSatisfy { $0.phase == .changed })
        XCTAssertNil(s.step(), "nothing is sent after the gesture ended")
    }

    func testStepsEaseOut() {
        var s = SmoothScroll()
        s.add(v: 400, h: 0)
        let moves = drain(&s).map { Int($0.dv) }.filter { $0 != 0 }
        XCTAssertEqual(moves, moves.sorted(by: >), "each step is no larger than the one before")
        XCTAssertGreaterThan(moves.count, 5)
    }

    func testNotchesDuringAScrollExtendTheSameGesture() {
        var s = SmoothScroll()
        s.add(v: 40, h: 0)
        var steps = (0..<3).compactMap { _ in s.step() }
        s.add(v: 40, h: 0)
        steps += drain(&s)
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dv) }, 80)
        XCTAssertEqual(steps.filter { $0.phase == .began }.count, 1)
        XCTAssertEqual(steps.filter { $0.phase == .ended }.count, 1)
    }

    func testFractionsAreCarriedNotLost() {
        var s = SmoothScroll()
        s.add(v: 12.5, h: -7.25)
        let steps = drain(&s)
        XCTAssertEqual(Double(steps.reduce(0) { $0 + Int($1.dv) }), 12.5, accuracy: 0.5)
        XCTAssertEqual(Double(steps.reduce(0) { $0 + Int($1.dh) }), -7.25, accuracy: 0.5)
    }

    func testReversingDropsWhatWasLeftOfTheOldDirection() {
        var s = SmoothScroll()
        s.add(v: 40, h: 0)
        _ = s.step(); _ = s.step()
        s.add(v: -40, h: 0)
        let after = drain(&s)
        XCTAssertTrue(after.allSatisfy { $0.dv <= 0 })
        XCTAssertEqual(after.reduce(0) { $0 + Int($1.dv) }, -40)
    }

    func testANewScrollAfterTheEndBeginsAgain() {
        var s = SmoothScroll()
        s.add(v: 40, h: 0)
        _ = drain(&s)
        s.add(v: 0, h: 40)
        let steps = drain(&s)
        XCTAssertEqual(steps.first?.phase, .began)
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dh) }, 40)
    }

    func testLessThanAPixelSendsNothing() {
        var s = SmoothScroll()
        s.add(v: 0.3, h: 0)
        XCTAssertTrue(drain(&s).isEmpty)
        XCTAssertFalse(s.isActive)
    }
}
