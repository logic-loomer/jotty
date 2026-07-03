import XCTest
@testable import Jotty

/// `KeyCombo.modifiers(from:)` — the inverse of `nsModifierFlags`, needed by the
/// AppDelegate local key monitor (09-05) to build a `KeyCombo` from a live
/// `NSEvent` and match it against stored bindings.
final class KeyComboModifiersTests: XCTestCase {

    func testMapsSingleModifiers() {
        XCTAssertEqual(KeyCombo.modifiers(from: [.command]), [.cmd])
        XCTAssertEqual(KeyCombo.modifiers(from: [.shift]), [.shift])
        XCTAssertEqual(KeyCombo.modifiers(from: [.option]), [.opt])
        XCTAssertEqual(KeyCombo.modifiers(from: [.control]), [.ctrl])
    }

    func testMapsCombinedModifiers() {
        XCTAssertEqual(KeyCombo.modifiers(from: [.command, .shift]), [.cmd, .shift])
        XCTAssertEqual(KeyCombo.modifiers(from: [.command, .option, .control]),
                       [.cmd, .opt, .ctrl])
    }

    func testIgnoresNonModifierFlags() {
        // Caps Lock / fn / numeric-pad bits ride along on real NSEvents — they
        // must never leak into the combo (a stored ⌘K should match ⌘K typed
        // with Caps Lock on).
        XCTAssertEqual(KeyCombo.modifiers(from: [.command, .capsLock]), [.cmd])
        XCTAssertEqual(KeyCombo.modifiers(from: [.shift, .function, .numericPad]),
                       [.shift])
        XCTAssertEqual(KeyCombo.modifiers(from: [.capsLock]), [])
        XCTAssertEqual(KeyCombo.modifiers(from: []), [])
    }

    func testRoundTripsWithNSModifierFlagsForAllSixteenSubsets() {
        let all: [KeyCombo.Modifier] = [.cmd, .shift, .opt, .ctrl]
        for mask in 0..<16 {
            var subset: Set<KeyCombo.Modifier> = []
            for (bit, modifier) in all.enumerated() where mask & (1 << bit) != 0 {
                subset.insert(modifier)
            }
            let flags = KeyCombo(keyCode: 40, modifiers: subset).nsModifierFlags
            XCTAssertEqual(KeyCombo.modifiers(from: flags), subset,
                           "round-trip failed for subset \(subset)")
        }
    }
}
