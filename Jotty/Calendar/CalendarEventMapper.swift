import EventKit
import Foundation

/// The boundary that keeps EventKit types from leaking past the real `CalendarService`.
///
/// `EventKitCalendarService` is the only caller of the `EKEvent` overload; everything the
/// app and tests see is the `Sendable` `CalendarEvent` value type. The pure helpers
/// (`overlaps`, `makeEvent`, `transform`) carry all the logic and are unit-tested without
/// touching EventKit, so the test suite never constructs an event store (threat T-5-03).
enum CalendarEventMapper {

    /// Builds the app-facing value from primitive fields. The `EKEvent` overload forwards
    /// here so the field-copy + "(untitled)" defaulting is exercised by EventKit-free tests.
    static func makeEvent(
        id: String,
        title: String?,
        start: Date,
        end: Date,
        calendarTitle: String?
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title ?? "(untitled)",
            start: start,
            end: end,
            calendarTitle: calendarTitle)
    }

    /// Maps a single `EKEvent` to the app-facing value, defaulting a nil title.
    ///
    /// `EKEvent.eventIdentifier` and `EKEvent.calendar` are both implicitly-unwrapped
    /// optionals (`String!` / `EKCalendar!`): a detached/orphaned occurrence, an event still
    /// syncing, or a row whose calendar was deleted out from under the predicate can leave
    /// them nil. Force-unwrapping there would crash the menubar read + conflict gate and
    /// violate the "best-effort, never crashes" contract, so a nil identifier makes this
    /// return nil (the row is skipped via `compactMap` in `transform`) and a nil calendar
    /// degrades to a nil `calendarTitle` rather than trapping (T-5-03).
    static func map(_ event: EKEvent) -> CalendarEvent? {
        mapFields(
            identifier: event.eventIdentifier,
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            calendarTitle: event.calendar?.title)
    }

    /// The pure, EventKit-free core of `map(_:)`: takes the exact (possibly-nil) primitive
    /// fields the `EKEvent` overload forwards and returns nil when the identifier is missing.
    /// Tested directly without EventKit so the skip-on-nil-identifier behavior is covered
    /// even where constructing an `EKEvent` is undesirable.
    static func mapFields(
        identifier: String?,
        title: String?,
        start: Date,
        end: Date,
        calendarTitle: String?
    ) -> CalendarEvent? {
        guard let id = identifier else { return nil }
        return makeEvent(
            id: id,
            title: title,
            start: start,
            end: end,
            calendarTitle: calendarTitle)
    }

    /// Strict interval intersection: true only when the half-open ranges actually overlap;
    /// touching endpoints (`a.end == b.start`) and disjoint ranges return false. Pure Date
    /// math (RESEARCH Pitfall 4 - compare absolute instants, never wall-clock strings).
    static func overlaps(start: Date, end: Date, otherStart: Date, otherEnd: Date) -> Bool {
        start < otherEnd && end > otherStart
    }

    /// The `eventsInRange` transform: drop all-day rows, map the rest to `CalendarEvent`,
    /// and sort by start. Generic over the source row so it stays EventKit-free and testable.
    ///
    /// `map` returns an optional so un-mappable rows (e.g. a nil `eventIdentifier`) are
    /// dropped via `compactMap` instead of crashing the whole read (CR-01).
    static func transform<Row>(
        _ rows: [Row],
        isAllDay: (Row) -> Bool,
        map: (Row) -> CalendarEvent?
    ) -> [CalendarEvent] {
        rows
            .filter { !isAllDay($0) }
            .compactMap(map)
            .sorted { $0.start < $1.start }
    }
}
