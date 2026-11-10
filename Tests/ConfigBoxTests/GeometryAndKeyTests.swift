import XCTest
@testable import ConfigBox

final class GeometryAndKeyTests: XCTestCase {
    private let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)

    func testTilingRects() {
        func rect(_ a: WindowAction) -> CGRect { WindowManager.rect(for: a, in: visible, current: nil) }
        XCTAssertEqual(rect(.leftHalf), CGRect(x: 100, y: 50, width: 500, height: 800))
        XCTAssertEqual(rect(.rightHalf), CGRect(x: 600, y: 50, width: 500, height: 800))
        XCTAssertEqual(rect(.topHalf), CGRect(x: 100, y: 450, width: 1000, height: 400))      // AppKit: y grows upward
        XCTAssertEqual(rect(.bottomRight), CGRect(x: 600, y: 50, width: 500, height: 400))
        XCTAssertEqual(rect(.maximize), visible)
        XCTAssertEqual(rect(.leftThird).union(rect(.centerThird)).union(rect(.rightThird)).integral, visible)
    }

    func testCenterKeepsTheWindowSize() {
        let r = WindowManager.rect(for: .center, in: visible, current: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(r, CGRect(x: 500, y: 400, width: 200, height: 100))
    }

    func testNormalizedRectRoundTrip() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let rect = CGRect(x: -1500, y: 400, width: 640, height: 360)
        let back = NRect(rect: rect, in: screen).rect(in: screen)
        XCTAssertEqual(back.minX, rect.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, rect.minY, accuracy: 0.001)
        XCTAssertEqual(back.width, rect.width, accuracy: 0.001)
        XCTAssertEqual(back.height, rect.height, accuracy: 0.001)
    }

    func testImplicitFnFlagIsIgnoredOnKeysThatAlwaysCarryIt() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskControl]
        XCTAssertEqual(KeyCodes.modifiers(for: 123, flags: flags), [.control])           // ←
        XCTAssertEqual(KeyCodes.modifiers(for: 0, flags: flags), [.control, .function])  // A
    }

    func testModifiersConvertToEventFlagsAndBack() {
        for m in [Modifiers.control, .option, .shift, .command, .function, [.control, .command], []] as [Modifiers] {
            XCTAssertEqual(Modifiers(cgFlags: m.cgFlags), m)
        }
    }

    func testKeyTableIsConsistent() {
        XCTAssertEqual(Set(KeyCodes.all.map(\.code)).count, KeyCodes.all.count, "duplicate key code")
        XCTAssertEqual(KeyCodes.hidUsage(for: KeyCodes.capsLock), 0x7_0000_0039)
        XCTAssertEqual(KeyCodes.name(forHID: 0x7_0000_0039), "Caps Lock")
        XCTAssertTrue(KeyCodes.hidOnly.allSatisfy { KeyCodes.hidUsage(for: $0) != nil })
    }
}
