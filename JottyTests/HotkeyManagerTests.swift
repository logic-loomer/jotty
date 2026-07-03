import XCTest
@testable import Jotty

/// Phase 9 plan 01 (CMDB-01 precondition, RESEARCH Pitfall 1): the HotkeyManager
/// multi-id refactor. The old Carbon callback ignored `EventHotKeyID`, so a second
/// registered hotkey would fire EVERY handler — ⌘N would toggle the command bar.
/// These tests seed the `handlers` map directly and drive `handleHotkey(id:)`,
/// proving each id routes to ONLY its own handler.
///
/// NEVER call `register()` here: it would register REAL system-wide hotkeys from
/// the test host. The Carbon leg (RegisterEventHotKey + GetEventParameter) stays
/// human-verified at the 09-05 checkpoint per RESEARCH Validation.
@MainActor
final class HotkeyManagerTests: XCTestCase {

    // MARK: - Per-id dispatch (the Pitfall-1 regression guard)

    func testHandleHotkeyFiresOnlyTheMatchingHandler() {
        let mgr = HotkeyManager()
        var counter1 = 0
        var counter2 = 0
        mgr.handlers[1] = { counter1 += 1 }
        mgr.handlers[2] = { counter2 += 1 }

        mgr.handleHotkey(id: 1)

        XCTAssertEqual(counter1, 1, "handler for id 1 must fire exactly once")
        XCTAssertEqual(counter2, 0, "handler for id 2 must NOT fire for id 1 — the Pitfall-1 defect")
    }

    func testHandleHotkeyForSecondIdFiresOnlySecondHandler() {
        let mgr = HotkeyManager()
        var counter1 = 0
        var counter2 = 0
        mgr.handlers[1] = { counter1 += 1 }
        mgr.handlers[2] = { counter2 += 1 }

        mgr.handleHotkey(id: 2)

        XCTAssertEqual(counter1, 0)
        XCTAssertEqual(counter2, 1)
    }

    func testHandleHotkeyWithUnknownIdIsSafeNoOp() {
        let mgr = HotkeyManager()
        var counter1 = 0
        var counter2 = 0
        mgr.handlers[1] = { counter1 += 1 }
        mgr.handlers[2] = { counter2 += 1 }

        mgr.handleHotkey(id: 99)   // no such handler — must not crash

        XCTAssertEqual(counter1, 0)
        XCTAssertEqual(counter2, 0)
    }

    func testRemovedHandlerNoLongerFires() {
        let mgr = HotkeyManager()
        var counter = 0
        mgr.handlers[1] = { counter += 1 }
        mgr.handleHotkey(id: 1)
        XCTAssertEqual(counter, 1)

        mgr.handlers[1] = nil
        mgr.handleHotkey(id: 1)
        XCTAssertEqual(counter, 1, "a removed handler must not fire again")
    }

    // MARK: - Stable Carbon ids

    func testIDRawValuesAreStable() {
        // These raw values are baked into registered Carbon EventHotKeyIDs.
        // A rename must never renumber them.
        XCTAssertEqual(HotkeyManager.ID.capture.rawValue, 1)
        XCTAssertEqual(HotkeyManager.ID.commandBar.rawValue, 2)
    }
}
