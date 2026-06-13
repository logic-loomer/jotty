import XCTest
@testable import Jotty

/// SC3 (Full Settings): pure keybinding conflict detection. No disk, no AppKit.
final class KeybindingConflictsTests: XCTestCase {

    private func combo(_ keyCode: UInt16, _ mods: Set<KeyCombo.Modifier> = []) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: mods)
    }

    func testNoConflictsWhenAllCombosDistinct() {
        let bindings: [Action: KeyCombo] = [
            .globalToggleCapture: combo(45, [.cmd]),
            .captureSubmit:       combo(36, [.cmd]),
            .captureCancel:       combo(53, []),
        ]
        XCTAssertEqual(conflicts(in: bindings), [])
    }

    func testEmptyBindingsHaveNoConflicts() {
        XCTAssertEqual(conflicts(in: [:]), [])
    }

    func testTwoActionsSharingAComboProduceOneConflict() {
        let shared = combo(36, [.cmd])
        let bindings: [Action: KeyCombo] = [
            .captureSubmit: shared,
            .sendToClaude:  shared,
            .captureCancel: combo(53, []),
        ]
        let result = conflicts(in: bindings)
        XCTAssertEqual(result.count, 1)
        let only = try? XCTUnwrap(result.first)
        XCTAssertEqual(only?.combo, shared)
        // Actions sorted by rawValue: "capture.submit" < "send.toClaude".
        XCTAssertEqual(only?.actions, [.captureSubmit, .sendToClaude])
    }

    func testActionsInConflictAreSortedByRawValue() {
        let shared = combo(45, [.cmd, .shift])
        // Insert in reverse-sorted order; result must still be sorted by rawValue.
        let bindings: [Action: KeyCombo] = [
            .sendToClaude:        shared, // "send.toClaude"
            .globalToggleCapture: shared, // "global.toggleCapture"
            .captureCancel:       shared, // "capture.cancel"
        ]
        let result = conflicts(in: bindings)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.actions,
                       [.captureCancel, .globalToggleCapture, .sendToClaude])
    }
}
