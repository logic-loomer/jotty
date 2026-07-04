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
        XCTAssertEqual(InboxRefreshPolicy.maxIntervalMinutes, 1440)
    }

    /// IN-05: the ceiling pins at 24h (1440 min). An absurd hand-edited value
    /// clamps DOWN so the `* 60` seconds conversion in scheduleInboxTimer can
    /// never overflow Int and trap.
    func testCeilingPinsAtMaxMinutes() {
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(1440), 1440)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(1441), 1440)
        XCTAssertEqual(InboxRefreshPolicy.flooredMinutes(Int.max), 1440)
    }

    /// The clamped value survives the `* 60` seconds conversion without trapping,
    /// even for the most extreme corrupt input.
    func testClampedValueTimesSixtyNeverOverflows() {
        let seconds = InboxRefreshPolicy.flooredMinutes(Int.max) * 60
        XCTAssertEqual(seconds, 1440 * 60)
    }
}
