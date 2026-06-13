import Foundation

/// A calendar event as seen by the app, view models, and tests.
///
/// This is the only event type that crosses the `CalendarService` seam; the real
/// EventKit value never leaves the real implementation (plan 05-03). Being `Sendable` lets it
/// flow freely across Swift 6 isolation boundaries; being `Identifiable` (by `id`) makes it
/// drop straight into SwiftUI lists for the menubar calendar section.
struct CalendarEvent: Equatable, Sendable, Identifiable {
    /// Stable calendar identifier (the EventKit event identifier), the link written to markdown.
    let id: String
    var title: String
    var start: Date
    var end: Date
    /// Owning calendar's title, for the menubar row + conflict copy. `nil` if unknown.
    var calendarTitle: String?
}

/// Current calendar permission state, mirrored from the OS TCC grant.
///
/// `writeOnly` and `restricted`/`denied` all collapse to `.denied` at the seam because
/// Phase 5's read-back features need full access; anything short of full read+write is a
/// degraded path for this app.
enum CalendarAccess: Sendable {
    case authorized
    case denied
    case notDetermined
}

/// Errors surfaced by a `CalendarService`.
enum CalendarError: Error, Equatable {
    /// Full calendar access has not been granted.
    case accessDenied
    /// A linked event id no longer exists in the store; caller should recreate (SC3).
    case eventNotFound
    /// Any other failure, carrying the underlying description.
    case underlying(message: String)
}

/// The single seam through which the app and tests touch the calendar.
///
/// The real implementation (plan 05-03) owns one long-lived EventKit store; tests inject
/// `FakeCalendarService`, so the suite never constructs an EventKit store and never triggers a
/// TCC prompt. The protocol is `Sendable` so it can be injected as a dependency under Swift 6.
protocol CalendarService: Sendable {
    /// Cheap, synchronous permission status read (does not prompt).
    func access() -> CalendarAccess
    /// Lazily prompts for full access on first calendar-touching action.
    func requestAccess() async -> CalendarAccess
    /// Creates an event and returns its stable `eventIdentifier`.
    func createEvent(title: String, start: Date, end: Date) async throws -> String
    /// Updates an existing event in place; throws `.eventNotFound` if the id is gone.
    func updateEvent(id: String, title: String, start: Date, end: Date) async throws
    /// Removes an event by id.
    func deleteEvent(id: String) async throws
    /// Returns timed events intersecting `[start, end]`, sorted by start.
    func eventsInRange(start: Date, end: Date) async throws -> [CalendarEvent]
    /// Returns events that overlap `[start, end]` (conflict detection, SC5).
    func overlappingEvents(start: Date, end: Date) async throws -> [CalendarEvent]
    /// Writable calendars, for the Settings picker.
    func writableCalendars() async -> [(id: String, title: String)]
}
