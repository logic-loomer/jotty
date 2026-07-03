import AppKit
import XCTest
@testable import Jotty

/// Phase 9 review WR-03: the palette's window-scoped key monitor must pass
/// Return/↑↓/Esc through while an input-method composition is in progress —
/// marked text means the input method owns those keys (confirm/navigate/cancel).
/// This exercises the pure bypass rule; the live monitor feeds it
/// `NSTextInputContext.current?.client`. The end-to-end candidate-window
/// interaction is not headless-testable and stays HUMAN-UAT.
@MainActor
final class CommandBarIMEGuardTests: XCTestCase {

    func testDefersWhileMarkedTextIsActive() {
        let client = StubTextInputClient(marked: true)
        XCTAssertTrue(CommandBarIMEGuard.shouldDeferToInputMethod(client: client),
                      "an in-progress composition owns Return/↑↓/Esc")
    }

    func testHandlesNormallyWithoutMarkedText() {
        let client = StubTextInputClient(marked: false)
        XCTAssertFalse(CommandBarIMEGuard.shouldDeferToInputMethod(client: client),
                       "no composition → the palette handles its keys")
    }

    func testHandlesNormallyWithNoInputClient() {
        XCTAssertFalse(CommandBarIMEGuard.shouldDeferToInputMethod(client: nil),
                       "no input context (nothing focused) → the palette handles its keys")
    }
}

/// Minimal NSTextInputClient stub: only `hasMarkedText()` matters to the guard.
private final class StubTextInputClient: NSObject, NSTextInputClient {
    private let marked: Bool
    init(marked: Bool) { self.marked = marked }

    func hasMarkedText() -> Bool { marked }

    // Protocol boilerplate — never called by the guard.
    func insertText(_ string: Any, replacementRange: NSRange) {}
    func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
