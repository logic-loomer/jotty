import EventKit
import Foundation

/// The production `CalendarService`, and the only place (with `CalendarEventMapper`) that
/// touches EventKit. It owns ONE long-lived `EKEventStore` for the app's lifetime (Apple
/// guidance: constructing a store per call is slow and can drop just-saved events) and
/// maps every `EKEvent` to the `Sendable` `CalendarEvent` at the boundary, so EventKit
/// types never reach the app, view models, or tests (threat T-5-03).
///
/// `@MainActor` because `EKEventStore`/`EKEvent` are non-Sendable; main-actor isolation is
/// the simplest correct Swift 6 model and matches Jotty's other UI-adjacent services.
/// The live grant and real save/read paths are human-verify-only; the unit tests cover the
/// pure mapper/overlap/filter logic without ever constructing this type (no TCC prompt).
@MainActor
final class EventKitCalendarService: CalendarService {

    /// One instance, lifetime of the app (RESEARCH Anti-Pattern: never per-call).
    private let store = EKEventStore()

    /// Reads the chosen calendar id live (e.g. `AppConfig.calendarIdentifier`) rather than
    /// capturing it at init, so a Settings change takes effect without re-wiring.
    private let calendarID: () -> String?

    init(calendarID: @escaping () -> String?) {
        self.calendarID = calendarID
    }

    // MARK: Permission

    /// Cheap, synchronous status read - safe off the main actor and never prompts.
    nonisolated func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .authorized
        case .denied, .restricted, .writeOnly:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Lazily prompts for FULL access (macOS 14+ API). The deprecated `requestAccess(to:)`
    /// is intentionally NOT used; it no-ops with the new Info.plist key on macOS 14+.
    func requestAccess() async -> CalendarAccess {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        return granted ? .authorized : .denied
    }

    // MARK: Writes

    func createEvent(title: String, start: Date, end: Date) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = "Created by Jotty"
        event.calendar = targetCalendar()
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.underlying(message: error.localizedDescription)
        }
        return event.eventIdentifier
    }

    func updateEvent(id: String, title: String, start: Date, end: Date) async throws {
        // nil => the event was deleted in Calendar; caller recreates + rewrites the id (SC3).
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound
        }
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.underlying(message: error.localizedDescription)
        }
    }

    func deleteEvent(id: String) async throws {
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound
        }
        do {
            try store.remove(event, span: .thisEvent)
        } catch {
            throw CalendarError.underlying(message: error.localizedDescription)
        }
    }

    // MARK: Reads

    func eventsInRange(start: Date, end: Date) async throws -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // Drop all-day rows, map behind the boundary, sort by start - all in the mapper.
        return CalendarEventMapper.transform(
            store.events(matching: predicate),
            isAllDay: { $0.isAllDay },
            map: CalendarEventMapper.map)
    }

    func overlappingEvents(start: Date, end: Date) async throws -> [CalendarEvent] {
        // The predicate already returns events intersecting the window; tighten to a strict
        // overlap so touching intervals (end == start) are not flagged as conflicts (SC5).
        try await eventsInRange(start: start, end: end).filter {
            CalendarEventMapper.overlaps(
                start: $0.start, end: $0.end, otherStart: start, otherEnd: end)
        }
    }

    func writableCalendars() async -> [(id: String, title: String)] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { (id: $0.calendarIdentifier, title: $0.title) }
    }

    // MARK: Helpers

    /// Resolves the configured calendar id live, falling back to the store's default.
    private func targetCalendar() -> EKCalendar? {
        if let id = calendarID(), let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        return store.defaultCalendarForNewEvents
    }
}
