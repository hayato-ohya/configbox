import XCTest
@testable import ConfigBox

final class ConfigDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        LossyDecoding.reset()
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func encode(_ c: Config) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(c)
    }

    func testSampleConfigSurvivesARoundTripUnchanged() throws {
        let first = try encode(.sample)
        LossyDecoding.reset()
        let again = try JSONDecoder().decode(Config.self, from: first)
        XCTAssertTrue(LossyDecoding.skipped.isEmpty)
        XCTAssertEqual(try encode(again), first)
    }

    func testEmptyObjectGivesDefaults() throws {
        let c = try decode("{}")
        XCTAssertTrue(c.triggers.isEmpty)
        XCTAssertTrue(c.general.keyboardEnabled)
        XCTAssertEqual(c.general.tapMaxMovement, 0.04)
        XCTAssertTrue(LossyDecoding.skipped.isEmpty)
    }

    func testMediaFunctionKeysSettingIsOffByDefaultAndDecodes() throws {
        XCTAssertFalse(try decode("{}").general.mediaKeysOnOtherKeyboards)
        XCTAssertTrue(try decode(#"{"general":{"mediaKeysOnOtherKeyboards":true}}"#).general.mediaKeysOnOtherKeyboards)
    }

    func testOnlyAppleAndBuiltInKeyboardsCountAsApple() {
        XCTAssertTrue(MediaFunctionKeys.isApple(DeviceRef(vendorId: 0x05AC, productId: 0x0342, name: "Magic Keyboard")))
        XCTAssertTrue(MediaFunctionKeys.isApple(DeviceRef(vendorId: 0x004C, productId: 0x0267, name: "Magic Keyboard")))
        XCTAssertTrue(MediaFunctionKeys.isApple(DeviceRef(vendorId: 0, productId: 0, name: "Apple Internal Keyboard / Trackpad")))
        XCTAssertFalse(MediaFunctionKeys.isApple(DeviceRef(vendorId: 0x046D, productId: 0xB35B, name: "MX Keys")))
    }

    func testEntriesOnlyNeedTheirEssentialKeys() throws {
        let c = try decode("""
        {"triggers":[{"kind":{"shortcut":{"_0":{"keyCode":123}}}}],
         "simpleModifications":[{"from":57,"to":53}],
         "complexRules":[{"from":57}],
         "keyActionRules":[{}],
         "chordRules":[{}],
         "snapAreas":[{"displayID":1,"trigger":{"x":0,"y":0,"w":0.5,"h":0.5}}],
         "knownKeyboards":[{"vendorId":1,"productId":2}]}
        """)
        XCTAssertTrue(LossyDecoding.skipped.isEmpty, "\(LossyDecoding.skipped)")
        XCTAssertEqual(c.triggers.first?.kind, .shortcut(KeyCombo(keyCode: 123)))
        XCTAssertEqual(c.triggers.first?.action, Action.none)
        XCTAssertEqual(c.triggers.first?.enabled, true)
        XCTAssertEqual(c.simpleModifications.count, 1)
        XCTAssertEqual(c.complexRules.first?.aloneTimeoutMs, 300)
        XCTAssertEqual(c.complexRules.first?.tapActions, [])
        XCTAssertEqual(c.keyActionRules.first?.repeats, false)
        XCTAssertEqual(c.chordRules.first?.thresholdMs, 60)
        XCTAssertEqual(c.snapAreas.first?.showWhileDragging, true)
        XCTAssertEqual(c.knownKeyboards.first?.name, "")
    }

    func testUnreadableEntriesAreSkippedAndReported() throws {
        let c = try decode("""
        {"triggers":[
           {"kind":{"shortcut":{"_0":{"keyCode":123}}}},
           {"kind":{"shortcut":{"_0":{"keyCode":124}}},"action":{"somethingFromANewerBuild":{}}},
           {"name":"no kind"},
           {"kind":{"gesture":{"_0":{"fingers":3,"kind":"tap"}}},"enabled":false}],
         "snapAreas":[{"displayID":"not a number"}]}
        """)
        XCTAssertEqual(c.triggers.count, 2)
        XCTAssertEqual(c.triggers.last?.kind, .gesture(Gesture(fingers: 3, kind: .tap)))
        XCTAssertEqual(c.triggers.last?.enabled, false)
        XCTAssertTrue(c.snapAreas.isEmpty)
        XCTAssertEqual(LossyDecoding.skipped.count, 3)
    }

    func testAnUnreadableSectionFallsBackToItsDefaultsOnly() throws {
        let c = try decode("""
        {"general":{"swipeThreshold":0.2},
         "switcher":"oops",
         "mouse":{"acceleration":"turbo","scrollSpeed":2}}
        """)
        XCTAssertEqual(c.general.swipeThreshold, 0.2)
        XCTAssertTrue(c.switcher.enabled)
        XCTAssertEqual(c.switcher.shortcut, KeyCombo(keyCode: 48, modifiers: [.option]))
        XCTAssertEqual(c.mouse.scrollSpeed, 2)
        XCTAssertEqual(c.mouse.acceleration, .system)
        XCTAssertEqual(LossyDecoding.skipped.count, 2)
    }

    func testJSONThatIsNotAConfigObjectStillFails() {
        XCTAssertThrowsError(try decode("[1, 2, 3]"))
        XCTAssertThrowsError(try decode("{\"triggers\": 5}"))
    }

    func testEdgeTargetKeepsItsTwoShapes() throws {
        let id = UUID()
        let json = "{\"snapping\":{\"topEdge\":\"half\",\"leftEdge\":{\"snapArea\":\"\(id.uuidString)\"},\"rightEdge\":\"unknown\"}}"
        let c = try decode(json)
        XCTAssertEqual(c.snapping.topEdge, .half)
        XCTAssertEqual(c.snapping.leftEdge, .snapArea(id))
        XCTAssertEqual(c.snapping.rightEdge, EdgeTarget.none)
        let again = try JSONDecoder().decode(Config.self, from: encode(c))
        XCTAssertEqual(again.snapping.leftEdge, .snapArea(id))
        XCTAssertEqual(again.snapping.topEdge, .half)
    }
}

final class BackForwardTests: XCTestCase {
    func testFinderGetsKeysByDefaultAndOtherAppsGetTheClick() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{\"mouse\":{\"scrollSpeed\":2}}".utf8))
        XCTAssertEqual(c.mouse.backForwardKeyApps, ["com.apple.finder"], "configs saved before the list existed get the default")
        XCTAssertTrue(c.mouse.sendsKeysForBackForward(in: "com.apple.finder"))
        XCTAssertFalse(c.mouse.sendsKeysForBackForward(in: "com.apple.Safari"))
        XCTAssertFalse(c.mouse.sendsKeysForBackForward(in: nil))
    }

    func testAnEmptyListIsKept() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{\"mouse\":{\"backForwardKeyApps\":[]}}".utf8))
        XCTAssertTrue(c.mouse.backForwardKeyApps.isEmpty)
        XCTAssertFalse(c.mouse.sendsKeysForBackForward(in: "com.apple.finder"))
    }
}
