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
        case overlappingEvents
        case writableCalendars
    }

    /// All mutable recording + configuration state, guarded by one mutex.
    private struct State {
        var accessToReturn: CalendarAccess = .authorized
        var cannedEvents: [CalendarEvent] = []
        var writableCalendarsToReturn: [CalendarRef] = []
        var errorToThrow: CalendarError?

        var createdEvents: [CreatedEvent] = []
        var updatedEventIDs: [String] = []
        var deletedEventIDs: [String] = []
        var calls: [Call] = []
        var requestAccessCallCount = 0
        var createCounter = 0
    }

    /// Recorded inputs to a `createEvent` call.
    struct CreatedEvent: Equatable, Sendable {
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

    // MARK: Recorded state (assertions for later plans)

    /// Inputs to each `createEvent` call, in order.
    var createdEvents: [CreatedEvent] { state.withLock { $0.createdEvents } }
    var updatedEventIDs: [String] { state.withLock { $0.updatedEventIDs } }
    var deletedEventIDs: [String] { state.withLock { $0.deletedEventIDs } }
    /// Ordered call log; supports "X called once" / "Y NOT called" assertions.
    var calls: [Call] { state.withLock { $0.calls } }
    var requestAccessCallCount: Int { state.withLock { $0.requestAccessCallCount } }

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
            if let error = $0.errorToThrow { throw error }
            return $0.cannedEvents
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
}
