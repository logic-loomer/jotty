import XCTest
@testable import Jotty

/// Phase 9 plan 01 / SC4: the app-level `ActionDispatcher` — the dispatch leg
/// review IN-01 said must exist BEFORE any new Action case is added. The palette's
/// Enter-on-settings-action routes ONLY through `dispatch(_:)` (09-04); AppDelegate
/// registers all handlers at launch (09-05). Tests use EXISTING Action cases so this
/// plan adds no enum cases (Pitfall 6: cases land together with their routing).
@MainActor
final class ActionDispatcherTests: XCTestCase {

    func testDispatchRunsRegisteredHandlerAndReturnsTrue() {
        let dispatcher = ActionDispatcher()
        var fired = false
        dispatcher.register(.sendToClaude) { fired = true }

        let handled = dispatcher.dispatch(.sendToClaude)

        XCTAssertTrue(handled, "dispatch must return true when a handler ran")
        XCTAssertTrue(fired, "the registered handler must run")
    }

    func testDispatchWithoutHandlerReturnsFalseAndFiresNothing() {
        let dispatcher = ActionDispatcher()
        var fired = false
        dispatcher.register(.sendToClaude) { fired = true }

        let handled = dispatcher.dispatch(.captureCancel)   // never registered

        XCTAssertFalse(handled, "dispatch of an unregistered action must return false")
        XCTAssertFalse(fired, "no other handler may fire")
    }

    func testReRegisteringReplacesTheHandler() {
        let dispatcher = ActionDispatcher()
        var firstFired = false
        var secondFired = false
        dispatcher.register(.sendToClaude) { firstFired = true }
        dispatcher.register(.sendToClaude) { secondFired = true }

        let handled = dispatcher.dispatch(.sendToClaude)

        XCTAssertTrue(handled)
        XCTAssertFalse(firstFired, "the replaced handler must NOT fire")
        XCTAssertTrue(secondFired, "the replacement handler must fire")
    }

    func testHasHandlerReflectsRegistration() {
        let dispatcher = ActionDispatcher()
        XCTAssertFalse(dispatcher.hasHandler(for: .sendToClaude))

        dispatcher.register(.sendToClaude) {}

        XCTAssertTrue(dispatcher.hasHandler(for: .sendToClaude))
        XCTAssertFalse(dispatcher.hasHandler(for: .captureSubmit),
                       "an unregistered action reports no handler")
    }

    // MARK: - Local monitor routing (review WR-01 / IN-07)

    /// ⌘T — a combo an app-level action could plausibly hold.
    private let cmdT = KeyCombo(keyCode: 17, modifiers: [.cmd])

    func testMonitorRoutingIgnoresBoundComboWhileRecording() {
        let bindings: [Action: KeyCombo] = [.openTodayFile: cmdT]

        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: cmdT, bindings: bindings, isRecordingCombo: true),
                       [],
                       "WR-01: a recording session must receive the keyDown — never dispatch")
        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: cmdT, bindings: bindings, isRecordingCombo: false),
                       [.openTodayFile],
                       "outside recording, the bound app-level action fires as before")
    }

    func testMonitorRoutingRequiresCommandLikeModifier() {
        let bareT = KeyCombo(keyCode: 17, modifiers: [])
        let shiftT = KeyCombo(keyCode: 17, modifiers: [.shift])
        let bindings: [Action: KeyCombo] = [.openTodayFile: bareT,
                                            .replayOnboarding: shiftT]

        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: bareT, bindings: bindings, isRecordingCombo: false), [],
                       "plain typing is never intercepted")
        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: shiftT, bindings: bindings, isRecordingCombo: false), [],
                       "bare-shift keys are never intercepted")
    }

    func testMonitorRoutingExcludesNonAppLevelActions() {
        let bindings: [Action: KeyCombo] = [.globalToggleCapture: cmdT,
                                            .captureSubmit: cmdT]

        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: cmdT, bindings: bindings, isRecordingCombo: false), [],
                       "Carbon globals and SwiftUI-handled combos never route here")
    }

    func testMonitorRoutingConflictOrderIsDeterministic() {
        // IN-07: two app-level actions on ONE combo (the conflicts UI warns but
        // does not block) must resolve in a pinned order, not hash order.
        let bindings: [Action: KeyCombo] = [.replayOnboarding: cmdT,
                                            .openTodayFile: cmdT]

        let expected = [Action.openTodayFile, .replayOnboarding]
            .sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(ActionDispatcher.appLevelActions(
                           matching: cmdT, bindings: bindings, isRecordingCombo: false),
                       expected)
    }
}

/// WR-01's recording signal: the AppDelegate monitor reads
/// `RecorderView.isRecordingActive`, which must track first-responder state.
@MainActor
final class RecorderRecordingSignalTests: XCTestCase {

    func testRecordingSignalTracksFirstResponderLifecycle() {
        XCTAssertFalse(RecorderView.isRecordingActive, "quiescent before any recording")
        let recorder = RecorderView(current: nil, allowsBareKey: true, onCapture: { _ in })

        _ = recorder.becomeFirstResponder()
        XCTAssertTrue(RecorderView.isRecordingActive, "recording flips the signal on")

        _ = recorder.resignFirstResponder()
        XCTAssertFalse(RecorderView.isRecordingActive, "resigning flips it back off")
    }

    func testRepeatedBecomeResignNeverUnderflows() {
        let recorder = RecorderView(current: nil, allowsBareKey: true, onCapture: { _ in })
        _ = recorder.resignFirstResponder()   // resign without ever recording
        XCTAssertFalse(RecorderView.isRecordingActive)

        _ = recorder.becomeFirstResponder()
        _ = recorder.becomeFirstResponder()   // double-become counts once
        XCTAssertTrue(RecorderView.isRecordingActive)
        _ = recorder.resignFirstResponder()
        XCTAssertFalse(RecorderView.isRecordingActive,
                       "one resign after a double-become fully clears the signal")
    }
}
