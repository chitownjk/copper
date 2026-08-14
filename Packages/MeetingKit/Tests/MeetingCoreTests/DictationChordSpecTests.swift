import XCTest
@testable import MeetingCore

final class DictationChordSpecTests: XCTestCase {
    func testDefaultMatchesControlOptionAndFnAlone() {
        let spec = DictationChordSpec.default
        XCTAssertTrue(spec.matches(control: true, option: true, shift: false, command: false, fn: false))
        XCTAssertTrue(spec.matches(control: true, option: true, shift: false, command: false, fn: true))
        XCTAssertTrue(spec.matches(control: false, option: false, shift: false, command: false, fn: true))
    }

    func testDefaultRejectsCommandAndPartialModifiers() {
        let spec = DictationChordSpec.default
        XCTAssertFalse(spec.matches(control: true, option: true, shift: false, command: true, fn: false))
        XCTAssertFalse(spec.matches(control: true, option: false, shift: false, command: false, fn: false))
        XCTAssertFalse(spec.matches(control: false, option: true, shift: false, command: false, fn: false))
        XCTAssertFalse(spec.matches(control: true, option: true, shift: true, command: false, fn: false))
    }

    func testOptionPresetDoesNotFireOnControlOption() {
        let spec = DictationChordPreset.option.spec(alsoFnAlone: false)
        XCTAssertTrue(spec.matches(control: false, option: true, shift: false, command: false, fn: false))
        XCTAssertFalse(spec.matches(control: true, option: true, shift: false, command: false, fn: false))
        XCTAssertFalse(spec.matches(control: false, option: false, shift: false, command: false, fn: true))
    }

    func testFnOnlyIgnoresModifierChords() {
        let spec = DictationChordPreset.fnOnly.spec(alsoFnAlone: true)
        XCTAssertTrue(spec.matches(control: false, option: false, shift: false, command: false, fn: true))
        XCTAssertFalse(spec.matches(control: true, option: true, shift: false, command: false, fn: false))
        XCTAssertEqual(spec.displayName, "Fn")
    }

    func testDisplayNameListsFnWhenEnabled() {
        XCTAssertEqual(DictationChordPreset.controlOption.spec(alsoFnAlone: true).displayName, "Control-Option or Fn")
        XCTAssertEqual(DictationChordPreset.controlOption.spec(alsoFnAlone: false).displayName, "Control-Option")
    }
}
