import XCTest
@testable import Jotty

/// WR-06: the record-a-combo control must reject a combo that is unsafe/unusable for the
/// action being bound — specifically a modifier-less (bare) key for the GLOBAL hotkey,
/// which `HotkeyManager.register` would grab system-wide and hijack everywhere. App-scoped
/// actions may keep bare keys (e.g. Esc to cancel). This exercises the pure validity rule
/// `RecorderView.isAcceptable` that the AppKit `keyDown` capture path gates on.
final class RecordComboValidationTests: XCTestCase {

    func testBareKeyRejectedWhenBareNotAllowed() {
        // 'A' (keyCode 0) with no modifiers, for the global action -> rejected.
        let bare = KeyCombo(keyCode: 0, modifiers: [])
        XCTAssertFalse(RecorderView.isAcceptable(bare, allowsBareKey: false),
                       "a modifier-less global combo must be rejected (system-wide grab risk)")
    }

    func testModifierCombosAcceptedForGlobalAction() {
        // Same key, but with a modifier -> acceptable even when bare keys are disallowed.
        let cmdA = KeyCombo(keyCode: 0, modifiers: [.cmd])
        XCTAssertTrue(RecorderView.isAcceptable(cmdA, allowsBareKey: false))
        let cmdShiftN = KeyCombo(keyCode: 45, modifiers: [.cmd, .shift])
        XCTAssertTrue(RecorderView.isAcceptable(cmdShiftN, allowsBareKey: false))
    }

    func testBareKeyAcceptedForAppScopedAction() {
        // App-scoped actions (submit/cancel/sendToClaude) may bind a bare key (e.g. Esc).
        let bareEsc = KeyCombo(keyCode: 53, modifiers: [])
        XCTAssertTrue(RecorderView.isAcceptable(bareEsc, allowsBareKey: true),
                      "bare keys are fine for app-scoped actions")
    }

    func testModifierComboAcceptedForAppScopedAction() {
        let cmdReturn = KeyCombo(keyCode: 36, modifiers: [.cmd])
        XCTAssertTrue(RecorderView.isAcceptable(cmdReturn, allowsBareKey: true))
    }
}
