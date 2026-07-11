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
        let a = CalendarEvent(eventKitID: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        let b = CalendarEvent(eventKitID: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertEqual(a, b)
    }

    func testCalendarEventInequalWhenAnyFieldDiffers() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let base = CalendarEvent(eventKitID: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertNotEqual(base, CalendarEvent(eventKitID: "evt-2", title: "Standup", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(eventKitID: "evt-1", title: "Retro", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(eventKitID: "evt-1", title: "Standup", start: end, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(eventKitID: "evt-1", title: "Standup", start: start, end: start, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(eventKitID: "evt-1", title: "Standup", start: start, end: end, calendarTitle: nil))
    }

    func testCalendarEventIdentifiableUsesOccurrenceCompositeId() {
        // The Identifiable id is the occurrence-unique composite (bare id + start), NOT
        // the bare EventKit identifier — recurring occurrences share the bare id, and a
        // duplicate Identifiable id misrenders every SwiftUI ForEach it feeds.
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(eventKitID: "evt-42", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertEqual(event.eventKitID, "evt-42", "the bare id is what markdown links store")
        XCTAssertEqual(event.id, "evt-42@\(start.timeIntervalSince1970)")
    }

    func testCalendarTitleIsOptional() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(eventKitID: "evt-1", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertNil(event.calendarTitle)
    }

    // MARK: - Calendar-visibility display filter

    func testVisibleFilterNilShowsEverything() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let events = [
            CalendarEvent(eventKitID: "e1", title: "Work thing", start: start, end: end,
                          calendarTitle: "Work", calendarID: "cal-work"),
            CalendarEvent(eventKitID: "e2", title: "Holiday", start: start, end: end,
                          calendarTitle: "Holidays", calendarID: "cal-holidays"),
        ]
        XCTAssertEqual(events.visible(in: nil), events, "nil = all calendars visible")
    }

    func testVisibleFilterKeepsListedAndUnknownCalendars() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let work = CalendarEvent(eventKitID: "e1", title: "Work thing", start: start, end: end,
                                 calendarTitle: "Work", calendarID: "cal-work")
        let holiday = CalendarEvent(eventKitID: "e2", title: "Holiday", start: start, end: end,
                                    calendarTitle: "Holidays", calendarID: "cal-holidays")
        // Unknown owning calendar stays visible (fail-open — hiding it would be silent).
        let unknown = CalendarEvent(eventKitID: "e3", title: "Mystery", start: start, end: end,
                                    calendarTitle: nil, calendarID: nil)
        let filtered = [work, holiday, unknown].visible(in: ["cal-work"])
        XCTAssertEqual(filtered.map(\.eventKitID), ["e1", "e3"],
                       "listed calendar + unknown-calendar events survive; hidden one drops")
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

    func testCalshowURLPayloadEqualsTimeIntervalString() {
        // For an opaque (no //) URL, the part after "calshow:" is the timeInterval payload.
        let start = dateFor("2026-06-13T15:00:00+10:00")
        let secsString = "\(start.timeIntervalSinceReferenceDate)"
        let url = CalendarURL.show(for: start)
        XCTAssertEqual(url?.absoluteString, "calshow:\(secsString)")
        // NSURL.resourceSpecifier carries the payload for scheme-only opaque URLs.
        XCTAssertEqual((url as NSURL?)?.resourceSpecifier, secsString)
    }

    func testCalshowURLReturnsNilForNonFiniteDate() {
        // IN-03: a corrupted/non-finite Date must yield nil, never a "calshow:nan"/"inf" URL.
        let nan = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertNil(CalendarURL.show(for: nan))
        let inf = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertNil(CalendarURL.show(for: inf))
    }

    // MARK: - FakeCalendarService self-tests (Wave 0 scaffold)

    @MainActor
    func testFakeReturnsConfiguredAccess() async {
        let fake = FakeCalendarService()
        XCTAssertEqual(fake.access(), .authorized, "default access is authorized")

        fake.accessToReturn = .denied
        XCTAssertEqual(fake.access(), .denied)
        let requested = await fake.requestAccess()
        XCTAssertEqual(requested, .denied)
        XCTAssertEqual(fake.requestAccessCallCount, 1)
    }

    @MainActor
    func testFakeCreateEventRecordsAndReturnsStubId() async throws {
        let fake = FakeCalendarService()
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")

        let id1 = try await fake.createEvent(title: "Standup", start: start, end: end)
        let id2 = try await fake.createEvent(title: "Retro", start: start, end: end)

        // Deterministic, distinct ids.
        XCTAssertEqual(id1, "fake-event-1")
        XCTAssertEqual(id2, "fake-event-2")

        // Records inputs in order.
        XCTAssertEqual(fake.createdEvents.count, 2)
        XCTAssertEqual(fake.createdEvents[0].title, "Standup")
        XCTAssertEqual(fake.createdEvents[0].start, start)
        XCTAssertEqual(fake.createdEvents[0].end, end)
        XCTAssertEqual(fake.createdEvents[1].title, "Retro")

        // Call log reflects exactly which methods ran.
        XCTAssertEqual(fake.calls, [.createEvent, .createEvent])
    }

    @MainActor
    func testFakeEventsInRangeReturnsCannedEvents() async throws {
        let fake = FakeCalendarService()
        let start = dateFor("2026-06-13T00:00:00+10:00")
        let end = dateFor("2026-06-13T23:59:59+10:00")
        let canned = CalendarEvent(eventKitID: "c-1", title: "Lunch",
                                   start: dateFor("2026-06-13T12:00:00+10:00"),
                                   end: dateFor("2026-06-13T13:00:00+10:00"),
                                   calendarTitle: "Personal")
        fake.cannedEvents = [canned]

        let events = try await fake.eventsInRange(start: start, end: end)
        XCTAssertEqual(events, [canned])
        XCTAssertEqual(fake.calls, [.eventsInRange])
    }

    @MainActor
    func testFakeOverlappingEventsReturnsCannedAndRecordsCall() async throws {
        let fake = FakeCalendarService()
        let canned = CalendarEvent(eventKitID: "c-2", title: "Meeting",
                                   start: dateFor("2026-06-13T14:00:00+10:00"),
                                   end: dateFor("2026-06-13T15:00:00+10:00"),
                                   calendarTitle: nil)
        fake.cannedEvents = [canned]
        let events = try await fake.overlappingEvents(
            start: dateFor("2026-06-13T14:30:00+10:00"),
            end: dateFor("2026-06-13T15:30:00+10:00"))
        XCTAssertEqual(events, [canned])
        XCTAssertEqual(fake.calls, [.overlappingEvents])
    }

    @MainActor
    func testFakeUpdateAndDeleteRecordIds() async throws {
        let fake = FakeCalendarService()
        try await fake.updateEvent(id: "u-1", title: "Renamed",
                                   start: dateFor("2026-06-13T09:00:00+10:00"),
                                   end: dateFor("2026-06-13T10:00:00+10:00"))
        try await fake.deleteEvent(id: "d-1")
        XCTAssertEqual(fake.updatedEventIDs, ["u-1"])
        XCTAssertEqual(fake.deletedEventIDs, ["d-1"])
        XCTAssertEqual(fake.calls, [.updateEvent, .deleteEvent])
    }

    func testFakeUpdateErrorOnlyAffectsUpdateNotCreate() async throws {
        // SC3 edit-time recreate path needs update -> .eventNotFound while create succeeds.
        let fake = FakeCalendarService()
        fake.updateErrorToThrow = .eventNotFound

        do {
            try await fake.updateEvent(id: "gone", title: "x",
                                       start: dateFor("2026-06-13T09:00:00+10:00"),
                                       end: dateFor("2026-06-13T10:00:00+10:00"))
            XCTFail("expected updateEvent to throw .eventNotFound")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .eventNotFound)
        }

        // createEvent is unaffected by updateErrorToThrow: it still succeeds.
        let newID = try await fake.createEvent(title: "x",
                                               start: dateFor("2026-06-13T09:00:00+10:00"),
                                               end: dateFor("2026-06-13T10:00:00+10:00"))
        XCTAssertEqual(newID, "fake-event-1")
        XCTAssertEqual(fake.updatedEventIDs, ["gone"])
        XCTAssertEqual(fake.createdEvents.count, 1)
    }

    @MainActor
    func testFakeThrowModePropagatesConfiguredError() async {
        let fake = FakeCalendarService()
        fake.errorToThrow = .eventNotFound

        do {
            _ = try await fake.createEvent(title: "x",
                                           start: dateFor("2026-06-13T09:00:00+10:00"),
                                           end: dateFor("2026-06-13T10:00:00+10:00"))
            XCTFail("expected createEvent to throw")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .eventNotFound)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        // Even on throw, the call is recorded (so plans can assert "createEvent attempted").
        XCTAssertEqual(fake.calls, [.createEvent])
    }

    @MainActor
    func testFakeThrowModePropagatesToReads() async {
        let fake = FakeCalendarService()
        fake.errorToThrow = .accessDenied
        do {
            _ = try await fake.eventsInRange(
                start: dateFor("2026-06-13T00:00:00+10:00"),
                end: dateFor("2026-06-13T23:59:59+10:00"))
            XCTFail("expected eventsInRange to throw")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .accessDenied)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    @MainActor
    func testFakeWritableCalendarsReturnsConfigured() async {
        let fake = FakeCalendarService()
        fake.writableCalendarsToReturn = [(id: "cal-1", title: "Work"), (id: "cal-2", title: "Home")]
        let cals = await fake.writableCalendars()
        XCTAssertEqual(cals.count, 2)
        XCTAssertEqual(cals[0].id, "cal-1")
        XCTAssertEqual(cals[0].title, "Work")
        XCTAssertEqual(cals[1].id, "cal-2")
    }

    @MainActor
    func testFakeNotCalledAssertionsHold() async throws {
        // Demonstrates the "method NOT called" capability later plans rely on (SC3).
        let fake = FakeCalendarService()
        _ = try await fake.eventsInRange(
            start: dateFor("2026-06-13T00:00:00+10:00"),
            end: dateFor("2026-06-13T23:59:59+10:00"))
        XCTAssertFalse(fake.calls.contains(.updateEvent), "updateEvent must NOT have been called")
        XCTAssertFalse(fake.calls.contains(.deleteEvent), "deleteEvent must NOT have been called")
        XCTAssertEqual(fake.calls.filter { $0 == .eventsInRange }.count, 1)
    }
}
