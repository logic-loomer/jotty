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
        let a = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        let b = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertEqual(a, b)
    }

    func testCalendarEventInequalWhenAnyFieldDiffers() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let base = CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: "Work")
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-2", title: "Standup", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Retro", start: start, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: end, end: end, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: start, end: start, calendarTitle: "Work"))
        XCTAssertNotEqual(base, CalendarEvent(id: "evt-1", title: "Standup", start: start, end: end, calendarTitle: nil))
    }

    func testCalendarEventIdentifiableUsesId() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(id: "evt-42", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertEqual(event.id, "evt-42")
    }

    func testCalendarTitleIsOptional() {
        let start = dateFor("2026-06-13T09:00:00+10:00")
        let end = dateFor("2026-06-13T10:00:00+10:00")
        let event = CalendarEvent(id: "evt-1", title: "x", start: start, end: end, calendarTitle: nil)
        XCTAssertNil(event.calendarTitle)
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
        let canned = CalendarEvent(id: "c-1", title: "Lunch",
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
        let canned = CalendarEvent(id: "c-2", title: "Meeting",
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
