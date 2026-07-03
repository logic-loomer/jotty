import XCTest
@testable import Jotty

/// CQ-04: pins `InboxRefreshPolicy`'s 5-minute floor (IN-03 / Pitfall 1 — the
/// opt-in periodic timer can never poll a third-party API more often than the
/// floor, even if a stale or hand-edited config asks for less).
final class InboxRefreshPolicyTests: XCTestCase {

    /// The floor pins at exactly 5 minutes: everything below clamps up to 5,
    /// everything at or above passes through unchanged.
    func testFloorPinsAtFiveMinutes() {
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(0), 5)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(4), 5)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(5), 5)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(60), 60)
    }

    /// A negative requested interval (e.g. a corrupted config value) still
    /// clamps up to the floor — never a zero/negative timer interval.
    func testNegativeInputClampsToFloor() {
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(-1), 5)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(Int.min), 5)
    }

    /// The policy constants themselves are pinned: a silent change to the floor
    /// or the first-enable default is a deliberate, test-visible decision.
    func testPolicyConstantsArePinned() {
        XCTAssertEqual(InboxRefreshPolicy.minIntervalMinutes, 5)
        XCTAssertEqual(InboxRefreshPolicy.defaultIntervalMinutes, 15)
    }
}
