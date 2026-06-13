import XCTest
@testable import Jotty

final class CalendarServiceTests: XCTestCase {

    // MARK: - Test helpers (mirrors existing JottyTests tz-pinned idiom)

    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    /// Builds an absolute Date for a fixed Australia/Sydney wall-clock instant.
    private func dateFor(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - CalendarEvent value semantics

    func testCalendarEventEquatableByAllFields() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let a = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        let b = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertEqual(a, b)
    }

    func testCalendarEventInequalWhenAnyFieldDiffers() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let base = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-2", title: "Standup", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Retro", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: end, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: start, end: start, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: nil))
    }

    func testCalendarEventIdentifiableUsesId() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(id: "evt-42", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertEqual(event.id, "evt-42")
    }

    func testCalendarTitleIsOptional() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(id: "evt-1", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertNil(event.calendarTitle)
    }

    // MARK: - calshow URL builder (RESEARCH Pitfall 5)

    func testCalshowURLSchemeIsCalshow() {
        let start = dateFor("2026-06-13T15:00:00+10:00")
        let url = CalendarURL.show(for: start)
        XCTAssertEqual(url?.scheme, "calshow")
    }

    func testCalshowURLEncodesTimeIntervalSinceReferenceDate() {
        let start = dateFor("2026-06-13T15:00:00+10:00")
        let expected = "calshow:\(start.timeIntervalSinceReferenceDate)"
        let url = CalendarURL.show(for: start)
        XCTAssertEqual(url?.absoluteString, expected)
    }

    func testCalshowURLPathEqualsTimeIntervalString() {
        // For an opaque (no //) URL, the part after the scheme is the resourceSpecifier / path.
        let start = dateFor("2026-06-13T15:00:00+10:00")
        let secsString = "\(start.timeIntervalSinceReferenceDate)"
        let url = CalendarURL.show(for: start)
        XCTAssertEqual(url?.absoluteString, "calshow:\(secsString)")
        // resourceSpecifier carries the payload for scheme-only opaque URLs.
        XCTAssertEqual(url?.resourceSpecifier, secsString)
    }
}
