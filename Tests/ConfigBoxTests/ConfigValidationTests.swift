import XCTest
@testable import ConfigBox

final class ConfigValidationTests: XCTestCase {
    private let keyboard = DeviceRef(vendorId: 1, productId: 2, name: "KB")

    private func issues(_ t: Trigger, _ c: Config) -> [String] { ConfigValidation.issues(for: t, in: c) }

    func testShortcutsThatCannotFireOrBlockAKey() {
        var c = Config()
        let commandAlone = Trigger(kind: .shortcut(KeyCombo(keyCode: 55)))
        let bareA = Trigger(kind: .shortcut(KeyCombo(keyCode: 0)))
        let shiftA = Trigger(kind: .shortcut(KeyCombo(keyCode: 0, modifiers: [.shift])))
        let bareF1 = Trigger(kind: .shortcut(KeyCombo(keyCode: 122)))
        let commandA = Trigger(kind: .shortcut(KeyCombo(keyCode: 0, modifiers: [.command])))
        let unset = Trigger(kind: .shortcut(.unset))
        let disabled = Trigger(enabled: false, kind: .shortcut(KeyCombo(keyCode: 0)))
        c.triggers = [commandAlone, bareA, shiftA, bareF1, commandA, unset, disabled]
        XCTAssertEqual(issues(commandAlone, c).count, 1)
        XCTAssertEqual(issues(bareA, c).count, 1)
        XCTAssertEqual(issues(shiftA, c).count, 1)
        XCTAssertTrue(issues(bareF1, c).isEmpty)
        XCTAssertTrue(issues(commandA, c).isEmpty)
        XCTAssertTrue(issues(unset, c).isEmpty)
        XCTAssertTrue(issues(disabled, c).isEmpty)
    }

    func testShortcutTakenByTheSwitcherOrAMacro() {
        var c = Config()
        let switcherBackwards = Trigger(kind: .shortcut(KeyCombo(keyCode: 48, modifiers: [.option, .shift])))
        let macroKey = Trigger(kind: .shortcut(KeyCombo(keyCode: 40, modifiers: [.command])))
        c.triggers = [switcherBackwards, macroKey]
        c.keyActionRules = [KeyActionRule(from: KeyCombo(keyCode: 40, modifiers: [.command]))]
        XCTAssertEqual(issues(switcherBackwards, c).count, 1)
        XCTAssertEqual(issues(macroKey, c).count, 1)

        c.switcher.enabled = false
        c.general.keyboardEnabled = false
        XCTAssertTrue(issues(switcherBackwards, c).isEmpty)
        XCTAssertTrue(issues(macroKey, c).isEmpty)
    }

    func testDuplicateTriggersCountPerApp() {
        var c = Config()
        let tap = TriggerKind.gesture(Gesture(fingers: 3, kind: .tap))
        let a = Trigger(kind: tap), b = Trigger(kind: tap)
        let otherApp = Trigger(kind: tap, appBundleId: "com.example.app")
        let off = Trigger(enabled: false, kind: tap)
        c.triggers = [a, b, otherApp, off]
        XCTAssertEqual(issues(a, c).count, 1)
        XCTAssertEqual(issues(b, c).count, 1)
        XCTAssertTrue(issues(otherApp, c).isEmpty)
        XCTAssertTrue(issues(off, c).isEmpty)
    }

    func testRulesOnTheSameKeyOfTheSameKeyboardConflict() {
        var c = Config()
        let simple = SimpleModification(from: 57, to: 53)
        let simpleOnKeyboard = SimpleModification(from: 57, to: 59, device: keyboard)
        let unrelated = SimpleModification(from: 0, to: 1)
        let modTap = ComplexRule(from: 57)
        let macro = KeyActionRule(from: KeyCombo(keyCode: 57))
        let macroOnKeyboard = KeyActionRule(from: KeyCombo(keyCode: 57), device: keyboard)
        c.simpleModifications = [simple, simpleOnKeyboard, unrelated]
        c.complexRules = [modTap]
        c.keyActionRules = [macro, macroOnKeyboard]

        XCTAssertEqual(ConfigValidation.issues(for: simple, in: c).count, 2)            // the Mod-Tap rule and the macro
        XCTAssertEqual(ConfigValidation.issues(for: simpleOnKeyboard, in: c).count, 1)  // the macro on that keyboard
        XCTAssertTrue(ConfigValidation.issues(for: unrelated, in: c).isEmpty)
        XCTAssertEqual(ConfigValidation.issues(for: modTap, in: c).count, 1)            // the simple modification
        XCTAssertEqual(ConfigValidation.issues(for: macro, in: c).count, 2)             // the simple modification and the Mod-Tap rule
        XCTAssertEqual(ConfigValidation.issues(for: macroOnKeyboard, in: c).count, 1)   // the simple modification on that keyboard
    }

    func testDuplicateRemapRules() {
        var c = Config()
        c.simpleModifications = [SimpleModification(from: 57, to: 53), SimpleModification(from: 57, to: 59)]
        c.complexRules = [ComplexRule(from: 49), ComplexRule(from: 49)]
        c.keyActionRules = [KeyActionRule(from: KeyCombo(keyCode: 40)), KeyActionRule(from: KeyCombo(keyCode: 40))]
        XCTAssertEqual(ConfigValidation.issues(for: c.simpleModifications[0], in: c).count, 1)
        XCTAssertEqual(ConfigValidation.issues(for: c.complexRules[1], in: c).count, 1)
        XCTAssertEqual(ConfigValidation.issues(for: c.keyActionRules[0], in: c).count, 1)

        c.simpleModifications[1].enabled = false
        XCTAssertTrue(ConfigValidation.issues(for: c.simpleModifications[0], in: c).isEmpty)
    }

    func testTheSampleConfigHasNoIssues() {
        let c = Config.sample
        XCTAssertTrue(c.triggers.allSatisfy { ConfigValidation.issues(for: $0, in: c).isEmpty })
        XCTAssertTrue(c.complexRules.allSatisfy { ConfigValidation.issues(for: $0, in: c).isEmpty })
    }
}
