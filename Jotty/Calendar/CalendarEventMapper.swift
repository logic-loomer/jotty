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
        // TODO(RED): implement in GREEN.
        fatalError("unimplemented")
    }

    /// Maps a single `EKEvent` to the app-facing value, defaulting a nil title.
    static func map(_ event: EKEvent) -> CalendarEvent {
        makeEvent(
            id: event.eventIdentifier,
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            calendarTitle: event.calendar.title)
    }

    /// Strict interval intersection: true only when the half-open ranges actually overlap;
    /// touching endpoints (`a.end == b.start`) and disjoint ranges return false. Pure Date
    /// math (RESEARCH Pitfall 4 - compare absolute instants, never wall-clock strings).
    static func overlaps(start: Date, end: Date, otherStart: Date, otherEnd: Date) -> Bool {
        // TODO(RED): implement in GREEN.
        fatalError("unimplemented")
    }

    /// The `eventsInRange` transform: drop all-day rows, map the rest to `CalendarEvent`,
    /// and sort by start. Generic over the source row so it stays EventKit-free and testable.
    static func transform<Row>(
        _ rows: [Row],
        isAllDay: (Row) -> Bool,
        map: (Row) -> CalendarEvent
    ) -> [CalendarEvent] {
        // TODO(RED): implement in GREEN.
        fatalError("unimplemented")
    }
}
