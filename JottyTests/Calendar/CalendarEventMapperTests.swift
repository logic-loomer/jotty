import XCTest
import EventKit
@testable import Jotty

/// Prompt-free, framework-free tests for the pure pieces of the calendar boundary:
/// the overlap predicate, the all-day filter, and the value-construction path of the
/// mapper. The platform calendar framework and its event-store type never appear here,
/// so no TCC prompt can fire and the suite never touches the real calendar
/// (threat T-5-03 / RESEARCH Pitfall 2).
///
/// The live platform-event -> CalendarEvent path is covered by the human checkpoints in
/// later plans; here we exercise the same logic through `makeEvent(...)`, which takes the
/// exact primitive fields the platform-event overload forwards.
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

    // MARK: - CR-01: tolerant mapping (nil identifier / nil calendar must not crash)

    /// A nil identifier yields nil (the row is skipped) instead of trapping. Pure path,
    /// no EventKit — exercises the exact branch the EKEvent overload forwards into.
    func testMapFieldsReturnsNilForNilIdentifier() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        XCTAssertNil(CalendarEventMapper.mapFields(
            identifier: nil, title: "Orphaned occurrence",
            start: start, end: end, calendarTitle: "Work"))
    }

    /// A present identifier with a nil calendar title still maps (calendar absence degrades
    /// to nil calendarTitle, never a crash).
    func testMapFieldsMapsWhenIdentifierPresentEvenIfCalendarTitleNil() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let mapped = CalendarEventMapper.mapFields(
            identifier: "evt-3", title: "Standup",
            start: start, end: end, calendarTitle: nil)
        XCTAssertEqual(mapped?.id, "evt-3")
        XCTAssertEqual(mapped?.title, "Standup")
        XCTAssertNil(mapped?.calendarTitle)
    }

    /// CR-01 regression on a REAL `EKEvent`: an unsaved event has a nil `eventIdentifier`
    /// (and, here, a nil `calendar`). Constructing/inspecting an unsaved event against an
    /// in-memory `EKEventStore` needs NO TCC permission, so this fires no prompt. The mapper
    /// must return nil (skip) rather than force-unwrap and crash the read path.
    func testMapReturnsNilForUnsavedEventWithNilIdentifierNoCrash() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Unsaved (no identifier yet)"
        event.startDate = dateFor("2026-06-13T09:00:00+10:00")
        event.endDate = dateFor("2026-06-13T10:00:00+10:00")
        // Unsaved EKEvent: eventIdentifier is nil and calendar is nil. Must not trap.
        XCTAssertNil(CalendarEventMapper.map(event))
    }

    /// `transform` drops un-mappable (nil-identifier) rows via compactMap instead of crashing,
    /// keeping the mappable ones sorted by start.
    func testTransformSkipsRowsWithNilIdentifier() {
        let rows = [
            Row(id: nil, title: "Orphan", start: dateFor("2026-06-13T08:00:00+10:00"),
                end: dateFor("2026-06-13T09:00:00+10:00"), calendarTitle: "Work", isAllDay: false),
            Row(id: "ok", title: "Real", start: dateFor("2026-06-13T10:00:00+10:00"),
                end: dateFor("2026-06-13T11:00:00+10:00"), calendarTitle: "Work", isAllDay: false),
        ]
        let mapped = CalendarEventMapper.transform(
            rows,
            isAllDay: \.isAllDay,
            map: { CalendarEventMapper.mapFields(identifier: $0.id, title: $0.title,
                                                 start: $0.start, end: $0.end,
                                                 calendarTitle: $0.calendarTitle) })
        XCTAssertEqual(mapped.map(\.id), ["ok"])
    }

    // MARK: - all-day filter + sort (the eventsInRange transform, EventKit-free)

    /// Minimal stand-in carrying just the fields the eventsInRange transform reads,
    /// so the filter+map+sort can be exercised without constructing an EKEvent.
    private struct Row {
        let id: String?
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
            map: { CalendarEventMapper.mapFields(identifier: $0.id, title: $0.title,
                                                 start: $0.start, end: $0.end,
                                                 calendarTitle: $0.calendarTitle) })

        // All-day excluded; remaining sorted by start (early before late).
        XCTAssertEqual(mapped.map(\.id), ["early", "late"])
        XCTAssertEqual(mapped[0].title, "(untitled)")
    }
}
