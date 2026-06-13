import XCTest
@testable import Jotty

/// Prompt-free, EventKit-free tests for the pure pieces of the calendar boundary:
/// the overlap predicate, the all-day filter, and the value-construction path of the
/// mapper. EventKit (`EKEvent`/`EKEventStore`) never appears here, so no TCC prompt can
/// fire and the suite never touches the real calendar (threat T-5-03 / RESEARCH Pitfall 2).
///
/// The live `EKEvent -> CalendarEvent` path is covered by the human checkpoints in later
/// plans; here we exercise the same logic through `makeEvent(...)`, which takes the exact
/// primitive fields the EKEvent overload forwards.
final class CalendarEventMapperTests: XCTestCase {

    private func dateFor(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - overlaps(...) strict interval intersection

    func testOverlapsTrueWhenIntervalsIntersect() {
        let a = dateFor("2026-06-13T14:00:00+10:00")
        let b = dateFor("2026-06-13T15:00:00+10:00")
        // [14:30,15:30) intersects [14:00,15:00)
        XCTAssertTrue(CalendarEventMapper.overlaps(
            start: dateFor("2026-06-13T14:30:00+10:00"),
            end: dateFor("2026-06-13T15:30:00+10:00"),
            otherStart: a, otherEnd: b))
    }

    func testOverlapsTrueWhenOneContainsTheOther() {
        let outerStart = dateFor("2026-06-13T09:00:00+10:00")
        let outerEnd = dateFor("2026-06-13T12:00:00+10:00")
        // [10:00,11:00) fully inside [09:00,12:00)
        XCTAssertTrue(CalendarEventMapper.overlaps(
            start: dateFor("2026-06-13T10:00:00+10:00"),
            end: dateFor("2026-06-13T11:00:00+10:00"),
            otherStart: outerStart, otherEnd: outerEnd))
    }

    func testOverlapsFalseWhenIntervalsMerelyTouch() {
        let a = dateFor("2026-06-13T14:00:00+10:00")
        let b = dateFor("2026-06-13T15:00:00+10:00")
        // [15:00,16:00) starts exactly where [14:00,15:00) ends -> strict overlap is false.
        XCTAssertFalse(CalendarEventMapper.overlaps(
            start: dateFor("2026-06-13T15:00:00+10:00"),
            end: dateFor("2026-06-13T16:00:00+10:00"),
            otherStart: a, otherEnd: b))
        // Symmetric touching on the other side.
        XCTAssertFalse(CalendarEventMapper.overlaps(
            start: dateFor("2026-06-13T13:00:00+10:00"),
            end: dateFor("2026-06-13T14:00:00+10:00"),
            otherStart: a, otherEnd: b))
    }

    func testOverlapsFalseWhenDisjoint() {
        let a = dateFor("2026-06-13T14:00:00+10:00")
        let b = dateFor("2026-06-13T15:00:00+10:00")
        XCTAssertFalse(CalendarEventMapper.overlaps(
            start: dateFor("2026-06-13T16:00:00+10:00"),
            end: dateFor("2026-06-13T17:00:00+10:00"),
            otherStart: a, otherEnd: b))
    }

    // MARK: - makeEvent(...) value construction (same logic the EKEvent overload uses)

    func testMakeEventCopiesAllFields() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEventMapper.makeEvent(
            id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertEqual(event, CalendarEvent(
            id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work"))
    }

    func testMakeEventDefaultsNilTitleToUntitled() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEventMapper.makeEvent(
            id: "evt-2", title: nil, start: start, end: end, calendarTitle: nil)
        XCTAssertEqual(event.title, "(untitled)")
        XCTAssertNil(event.calendarTitle)
        XCTAssertEqual(event.id, "evt-2")
    }

    // MARK: - all-day filter + sort (the eventsInRange transform, EventKit-free)

    /// Minimal stand-in carrying just the fields the eventsInRange transform reads,
    /// so the filter+map+sort can be exercised without constructing an EKEvent.
    private struct Row {
        let id: String
        let title: String?
        let start: Date
        let end: Date
        let calendarTitle: String?
        let isAllDay: Bool
    }

    func testTransformFiltersAllDayAndSortsByStart() {
        let rows = [
            Row(id: "late", title: "Late", start: dateFor("2026-06-13T15:00:00+10:00"),
                end: dateFor("2026-06-13T16:00:00+10:00"), calendarTitle: "Work", isAllDay: false),
            Row(id: "allday", title: "Holiday", start: dateFor("2026-06-13T00:00:00+10:00"),
                end: dateFor("2026-06-14T00:00:00+10:00"), calendarTitle: "Personal", isAllDay: true),
            Row(id: "early", title: nil, start: dateFor("2026-06-13T09:00:00+10:00"),
                end: dateFor("2026-06-13T10:00:00+10:00"), calendarTitle: nil, isAllDay: false),
        ]

        let mapped = CalendarEventMapper.transform(
            rows,
            isAllDay: \.isAllDay,
            map: { CalendarEventMapper.makeEvent(id: $0.id, title: $0.title,
                                                 start: $0.start, end: $0.end,
                                                 calendarTitle: $0.calendarTitle) })

        // All-day excluded; remaining sorted by start (early before late).
        XCTAssertEqual(mapped.map(\.id), ["early", "late"])
        XCTAssertEqual(mapped[0].title, "(untitled)")
    }
}
