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

    /// Invoked on the main actor whenever EventKit reports an EXTERNAL change —
    /// principally an access grant toggled in System Settings while Jotty is already
    /// running (`authorizationStatus` is cached per-process and does NOT update live
    /// otherwise, so the "not granted" banner would otherwise persist until relaunch),
    /// but also underlying calendar-data edits. The app wiring sets this to re-run the
    /// menubar calendar reload. Set on the main actor before/after construction.
    var onStoreChanged: (@MainActor () -> Void)?

    /// Token for the `EKEventStoreChanged` observer, removed on deinit (the observer
    /// otherwise outlives the service). `nonisolated(unsafe)` so the nonisolated deinit
    /// can read it: assigned once in `init` on the main actor, read only in `deinit`
    /// once every other reference is gone (same idiom as AppDelegate's observer token).
    nonisolated(unsafe) private var storeChangeObserver: NSObjectProtocol?

    init(calendarID: @escaping () -> String?) {
        self.calendarID = calendarID
        // Observe live store/access changes so a System-Settings grant (or an external
        // event edit) refreshes the UI without an app restart. EventKit posts this for
        // THIS store instance; delivery on `.main` keeps the callback main-actor safe.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStoreChanged?() }
        }
    }

    deinit {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
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

    /// Notes sentinel stamped on every Jotty-created event, checked on update/delete so a
    /// recycled EventKit identifier can never clobber a stranger's event (WR-05).
    /// `nonisolated` so the nonisolated marker guard + tests can read it without an actor hop.
    nonisolated static let jottyMarker = "Created by Jotty"

    func createEvent(title: String, start: Date, end: Date) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = Self.jottyMarker
        event.calendar = targetCalendar()
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.underlying(message: error.localizedDescription)
        }
        // `eventIdentifier` is an IUO (`String!`); on some macOS versions it can still be nil
        // immediately after a successful save (before the store commits). Guard rather than
        // return nil into the non-optional `-> String` and trap (CR-01).
        guard let identifier = event.eventIdentifier else {
            throw CalendarError.underlying(message: "Calendar event saved without an identifier")
        }
        return identifier
    }

    func updateEvent(id: String, title: String, start: Date, end: Date) async throws {
        // nil => the event was deleted in Calendar; caller recreates + rewrites the id (SC3).
        // A matched event that is NOT Jotty-created means the id was recycled onto a
        // stranger's event after a delete+sync; treat it as not-found (recreate) rather than
        // overwriting someone else's calendar entry (WR-05).
        guard let event = store.event(withIdentifier: id), Self.isJottyEvent(event) else {
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
        // Same recycled-id guard as updateEvent (WR-05): only remove events Jotty created.
        // A non-Jotty match is treated as not-found so a recycled id can't delete a
        // stranger's event.
        guard let event = store.event(withIdentifier: id), Self.isJottyEvent(event) else {
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

    /// True when the event carries Jotty's notes sentinel — the defensive check that keeps
    /// update/delete from mutating a stranger's event behind a recycled identifier (WR-05).
    /// Internal + nonisolated (not private) so the marker guard can be unit-tested on an
    /// unsaved `EKEvent` without a live store / TCC prompt or an actor hop.
    nonisolated static func isJottyEvent(_ event: EKEvent) -> Bool {
        event.notes?.contains(jottyMarker) == true
    }

    /// Resolves the configured calendar id live, falling back to the store's default.
    private func targetCalendar() -> EKCalendar? {
        if let id = calendarID(), let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        return store.defaultCalendarForNewEvents
    }
}
