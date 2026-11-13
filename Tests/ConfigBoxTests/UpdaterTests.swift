import XCTest
@testable import ConfigBox

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("0.4.1", than: "0.4.0"))
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.9"), "parts compare as numbers, not text")
        XCTAssertTrue(Updater.isNewer("v1.0", than: "0.99.99"))
        XCTAssertTrue(Updater.isNewer("0.4.0.1", than: "0.4.0"))
        XCTAssertFalse(Updater.isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(Updater.isNewer("0.4", than: "0.4.0"), "a missing part counts as 0")
        XCTAssertFalse(Updater.isNewer("0.3.10", than: "0.4.0"))
        XCTAssertFalse(Updater.isNewer("0.4.0-beta", than: "0.4.0"))
    }
}
