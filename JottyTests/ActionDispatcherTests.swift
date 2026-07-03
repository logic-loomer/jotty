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
}
