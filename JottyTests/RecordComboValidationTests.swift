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

/// Phase 9 review WR-02: app-level actions fire through the AppDelegate local
/// monitor, which requires ⌘/⌃/⌥ — the recorder must enforce the SAME rule or a
/// bare/⇧-only combo records as a displayed-but-permanently-dead binding.
@MainActor
final class RecordComboCommandModifierTests: XCTestCase {

    func testBareKeyRejectedForAppLevelAction() {
        // F5 (keyCode 96), no modifiers: the recorder used to accept this for
        // e.g. openTodayFile even though the monitor would never fire it.
        let bareF5 = KeyCombo(keyCode: 96, modifiers: [])
        XCTAssertFalse(RecorderView.isAcceptable(bareF5, allowsBareKey: true,
                                                 requiresCommandLikeModifier: true),
                       "a bare key can never fire through the local monitor")
    }

    func testShiftOnlyComboRejectedForAppLevelAction() {
        let shiftF5 = KeyCombo(keyCode: 96, modifiers: [.shift])
        XCTAssertFalse(RecorderView.isAcceptable(shiftF5, allowsBareKey: true,
                                                 requiresCommandLikeModifier: true),
                       "⇧ alone is not a command-like modifier — the monitor ignores it")
    }

    func testCommandLikeModifiersAcceptedForAppLevelAction() {
        for modifier: KeyCombo.Modifier in [.cmd, .ctrl, .opt] {
            let combo = KeyCombo(keyCode: 17, modifiers: [modifier])
            XCTAssertTrue(RecorderView.isAcceptable(combo, allowsBareKey: true,
                                                    requiresCommandLikeModifier: true),
                          "\(modifier) satisfies the monitor's guard")
        }
        let shiftCmd = KeyCombo(keyCode: 17, modifiers: [.shift, .cmd])
        XCTAssertTrue(RecorderView.isAcceptable(shiftCmd, allowsBareKey: true,
                                                requiresCommandLikeModifier: true))
    }

    func testBareKeysStillFineForCaptureScopedActions() {
        // Esc-to-cancel etc. keep recording bare keys — the flag defaults false.
        let bareEsc = KeyCombo(keyCode: 53, modifiers: [])
        XCTAssertTrue(RecorderView.isAcceptable(bareEsc, allowsBareKey: true))
    }

    func testTabEnforcementSetMatchesMonitorRoutingSet() {
        XCTAssertEqual(KeybindingsTab.requiresCommandModifierActions,
                       ActionDispatcher.appLevelActions,
                       "recorder validation and monitor routing must gate the SAME actions")
    }
}
