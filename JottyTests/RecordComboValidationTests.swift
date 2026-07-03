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

/// Phase 9 review WR-01 follow-up (iteration 3): the app-wide "recording" suppression
/// signal must end WITH the recording interaction. resignFirstResponder alone leaked
/// the signal when the recorder's window lost key status mid-recording (menubar
/// popover / ⌘K panel) or was closed (cached SettingsWindowController) — suppression
/// then persisted app-wide, muting every bound app-level combo indefinitely.
@MainActor
final class RecordComboSessionEndTests: XCTestCase {

    /// A recorder installed in a real (never-shown) NSWindow — makeFirstResponder
    /// works on ordered-out windows, so these stay headless.
    private func makeRecorderInWindow() -> (RecorderView, NSWindow) {
        let view = RecorderView(current: nil, allowsBareKey: true, onCapture: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return (view, window)
    }

    func testWindowResignKeyEndsSession() {
        let baseline = RecorderView.activeRecorderCount
        let (view, window) = makeRecorderInWindow()
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline + 1,
                       "becoming first responder starts a session")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification,
                                        object: window)

        XCTAssertEqual(RecorderView.activeRecorderCount, baseline,
                       "losing key status must end the session and release suppression")
        XCTAssertFalse(window.firstResponder === view,
                       "the recorder must visually leave Recording… (drop first responder)")
    }

    func testWindowWillCloseEndsSession() {
        let baseline = RecorderView.activeRecorderCount
        let (view, window) = makeRecorderInWindow()
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification,
                                        object: window)

        XCTAssertEqual(RecorderView.activeRecorderCount, baseline,
                       "closing the window mid-recording must release suppression")
    }

    func testLeavingWindowEndsSession() {
        let baseline = RecorderView.activeRecorderCount
        let (view, window) = makeRecorderInWindow()
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline + 1)

        view.removeFromSuperview() // drives viewWillMove(toWindow: nil)

        XCTAssertEqual(RecorderView.activeRecorderCount, baseline,
                       "detaching from the window must release suppression")
    }

    func testRepeatedEndCallsAreIdempotentAndNeverUnderflow() {
        let baseline = RecorderView.activeRecorderCount
        let (view, window) = makeRecorderInWindow()
        XCTAssertTrue(window.makeFirstResponder(view))

        view.endRecording()
        view.endRecording()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification,
                                        object: window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification,
                                        object: window)

        XCTAssertEqual(RecorderView.activeRecorderCount, baseline,
                       "double-fire of the end paths must never underflow the count")
        XCTAssertFalse(RecorderView.activeRecorderCount > baseline)
    }

    func testSessionCanRestartAfterInterruptedEnd() {
        let baseline = RecorderView.activeRecorderCount
        let (view, window) = makeRecorderInWindow()
        XCTAssertTrue(window.makeFirstResponder(view))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification,
                                        object: window)
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline)

        // The end path dropped first responder, so a fresh click can restart.
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline + 1,
                       "an interrupted session must be restartable")
        window.makeFirstResponder(nil)
        XCTAssertEqual(RecorderView.activeRecorderCount, baseline)
    }
}
