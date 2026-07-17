import Foundation
import Synchronization
@testable import Jotty

/// In-memory `CalendarService` test double for the whole Phase 5 suite.
///
/// Records every call, returns canned `CalendarEvent`s, and can be flipped to throw a
/// configured `CalendarError`. It pulls in NO EventKit framework and constructs no event
/// store, so no test ever triggers a TCC permission prompt or touches the user's real
/// calendar (RESEARCH Pitfall 2 / threat T-5-03).
///
/// `CalendarService` is `Sendable`, so this fake must be `Sendable` too (a `@MainActor`
/// conformance is illegal for a `Sendable` protocol). All mutable state lives behind a single
/// `Mutex`, which makes the type genuinely `Sendable` while still exposing plain synchronous
/// getters/setters that plans 05-03..05-07 use from their `@MainActor` view models and tests.
final class FakeCalendarService: CalendarService {

    /// Every protocol method that was invoked, in call order.
    enum Call: Equatable, Sendable {
        case access
        case requestAccess
        case createEvent
        case updateEvent
        case deleteEvent
        case eventsInRange
        case allDayEventsInRange
        case overlappingEvents
        case writableCalendars
        case readableCalendars
    }

    /// All mutable recording + configuration state, guarded by one mutex.
    private struct State {
        var accessToReturn: CalendarAccess = .authorized
        var cannedEvents: [CalendarEvent] = []
        /// Returned by `allDayEventsInRange` (the chip row); empty by default so
        /// every pre-existing test sees no all-day rows.
        var cannedAllDayEvents: [CalendarEvent] = []
        var writableCalendarsToReturn: [CalendarRef] = []
        /// Returned by `readableCalendars()`; defaults to the writable list so
        /// existing fixtures need no extra setup.
        var readableCalendarsToReturn: [CalendarRef]? = nil
        var errorToThrow: CalendarError?
        /// When set, ONLY `updateEvent` throws this (everything else succeeds). Drives
        /// the SC3 edit-time recreate path: update -> .eventNotFound, then createEvent
        /// must still succeed and return a fresh id.
        var updateErrorToThrow: CalendarError?

        var createdEvents: [CreatedEvent] = []
        var updatedEventIDs: [String] = []
        /// Full-detail record of every `updateEvent` call (id/title/start/end), so the
        /// roadmap 2.3 task-wins drift resolution can assert exactly what was pushed —
        /// `updatedEventIDs` alone can't tell the sanitized title / block apart.
        var updatedEvents: [UpdatedEvent] = []
        /// Per-id override for `updateEvent`: when the id is a key, THAT call throws the
        /// mapped error regardless of `updateErrorToThrow`/`errorToThrow`. Lets a test
        /// simulate the WR-05 `isJottyEvent` marker guard refusing ONE recycled/foreign
        /// id (`.eventNotFound`) while a legitimate id in the SAME batch still succeeds
        /// (roadmap 2.3).
        var updateErrorsByID: [String: CalendarError] = [:]
        var deletedEventIDs: [String] = []
        var calls: [Call] = []
        var requestAccessCallCount = 0
        var createCounter = 0
        /// Window of the most recent `eventsInRange(start:end:)` call, so the
        /// today-window test (plan 11-02) can assert the source queries exactly
        /// [startOfDay(now), +1d) in the injected timezone. Additive; no existing
        /// Phase 5 behavior reads it.
        var lastEventsInRangeStart: Date?
        var lastEventsInRangeEnd: Date?
    }

    /// Recorded inputs to a `createEvent` call.
    struct CreatedEvent: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
    }

    /// Recorded inputs to an `updateEvent` call.
    struct UpdatedEvent: Equatable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    /// A writable-calendar entry (id + title), the value form of the protocol's tuple.
    struct CalendarRef: Equatable, Sendable {
        let id: String
        let title: String
    }

    private let state = Mutex(State())

    init() {}

    // MARK: Configurable behavior (synchronous, mutex-guarded)

    /// Returned by `access()` and `requestAccess()`. Default `.authorized`.
    var accessToReturn: CalendarAccess {
        get { state.withLock { $0.accessToReturn } }
        set { state.withLock { $0.accessToReturn = newValue } }
    }
    /// Returned by `eventsInRange` / `overlappingEvents` when not throwing.
    var cannedEvents: [CalendarEvent] {
        get { state.withLock { $0.cannedEvents } }
        set { state.withLock { $0.cannedEvents = newValue } }
    }
    /// Returned by `allDayEventsInRange` when not throwing.
    var cannedAllDayEvents: [CalendarEvent] {
        get { state.withLock { $0.cannedAllDayEvents } }
        set { state.withLock { $0.cannedAllDayEvents = newValue } }
    }
    /// Returned by `readableCalendars()`; nil (default) falls back to the writable list.
    var readableCalendarsToReturn: [(id: String, title: String)]? {
        get { state.withLock { $0.readableCalendarsToReturn?.map { ($0.id, $0.title) } } }
        set { state.withLock { $0.readableCalendarsToReturn = newValue?.map { CalendarRef(id: $0.id, title: $0.title) } } }
    }
    /// Returned by `writableCalendars()`.
    var writableCalendarsToReturn: [(id: String, title: String)] {
        get { state.withLock { $0.writableCalendarsToReturn.map { ($0.id, $0.title) } } }
        set { state.withLock { $0.writableCalendarsToReturn = newValue.map { CalendarRef(id: $0.id, title: $0.title) } } }
    }
    /// When non-nil, every throwing method throws this instead of succeeding.
    var errorToThrow: CalendarError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }
    /// When non-nil, ONLY `updateEvent` throws this (other methods unaffected). Set to
    /// `.eventNotFound` to exercise the SC3 edit-time recreate-and-relink path.
    var updateErrorToThrow: CalendarError? {
        get { state.withLock { $0.updateErrorToThrow } }
        set { state.withLock { $0.updateErrorToThrow = newValue } }
    }

    // MARK: Recorded state (assertions for later plans)

    /// Inputs to each `createEvent` call, in order.
    var createdEvents: [CreatedEvent] { state.withLock { $0.createdEvents } }
    var updatedEventIDs: [String] { state.withLock { $0.updatedEventIDs } }
    var updatedEvents: [UpdatedEvent] { state.withLock { $0.updatedEvents } }
    var deletedEventIDs: [String] { state.withLock { $0.deletedEventIDs } }
    /// Per-id override for `updateEvent`; set to make ONE id's call throw while
    /// its siblings in the same batch still succeed (roadmap 2.3 test (c)).
    var updateErrorsByID: [String: CalendarError] {
        get { state.withLock { $0.updateErrorsByID } }
        set { state.withLock { $0.updateErrorsByID = newValue } }
    }
    /// Ordered call log; supports "X called once" / "Y NOT called" assertions.
    var calls: [Call] { state.withLock { $0.calls } }
    var requestAccessCallCount: Int { state.withLock { $0.requestAccessCallCount } }
    /// Start/end of the most recent `eventsInRange` query (plan 11-02 today-window assert).
    var lastEventsInRangeStart: Date? { state.withLock { $0.lastEventsInRangeStart } }
    var lastEventsInRangeEnd: Date? { state.withLock { $0.lastEventsInRangeEnd } }

    // MARK: CalendarService

    func access() -> CalendarAccess {
        state.withLock {
            $0.calls.append(.access)
            return $0.accessToReturn
        }
    }

    func requestAccess() async -> CalendarAccess {
        state.withLock {
            $0.calls.append(.requestAccess)
            $0.requestAccessCallCount += 1
            return $0.accessToReturn
        }
    }

    func createEvent(title: String, start: Date, end: Date) async throws -> String {
        try state.withLock {
            $0.calls.append(.createEvent)
            $0.createdEvents.append(CreatedEvent(title: title, start: start, end: end))
            if let error = $0.errorToThrow { throw error }
            $0.createCounter += 1
            return "fake-event-\($0.createCounter)"
        }
    }

    func updateEvent(id: String, title: String, start: Date, end: Date) async throws {
        try state.withLock {
            $0.calls.append(.updateEvent)
            $0.updatedEventIDs.append(id)
            $0.updatedEvents.append(UpdatedEvent(id: id, title: title, start: start, end: end))
            if let idError = $0.updateErrorsByID[id] { throw idError }
            if let error = $0.updateErrorToThrow { throw error }
            if let error = $0.errorToThrow { throw error }
        }
    }

    func deleteEvent(id: String) async throws {
        try state.withLock {
            $0.calls.append(.deleteEvent)
            $0.deletedEventIDs.append(id)
            if let error = $0.errorToThrow { throw error }
        }
    }

    func eventsInRange(start: Date, end: Date) async throws -> [CalendarEvent] {
        try state.withLock {
            $0.calls.append(.eventsInRange)
            $0.lastEventsInRangeStart = start
            $0.lastEventsInRangeEnd = end
            if let error = $0.errorToThrow { throw error }
            return $0.cannedEvents
        }
    }

    func allDayEventsInRange(start: Date, end: Date) async throws -> [CalendarEvent] {
        try state.withLock {
            $0.calls.append(.allDayEventsInRange)
            if let error = $0.errorToThrow { throw error }
            return $0.cannedAllDayEvents
        }
    }

    func overlappingEvents(start: Date, end: Date) async throws -> [CalendarEvent] {
        try state.withLock {
            $0.calls.append(.overlappingEvents)
            if let error = $0.errorToThrow { throw error }
            return $0.cannedEvents
        }
    }

    func writableCalendars() async -> [(id: String, title: String)] {
        state.withLock {
            $0.calls.append(.writableCalendars)
            return $0.writableCalendarsToReturn.map { ($0.id, $0.title) }
        }
    }

    func readableCalendars() async -> [(id: String, title: String)] {
        state.withLock {
            $0.calls.append(.readableCalendars)
            let refs = $0.readableCalendarsToReturn ?? $0.writableCalendarsToReturn
            return refs.map { ($0.id, $0.title) }
        }
    }
}
