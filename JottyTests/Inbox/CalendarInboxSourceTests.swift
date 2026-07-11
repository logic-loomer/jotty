// JottyTests/Inbox/CalendarInboxSourceTests.swift
// Hermetic SC1/SC4/SC5 tests for CalendarInboxSource (plan 11-02). No EventKit,
// no network, no TCC prompt: every collaborator is injected — a FakeCalendarService
// plus enabled/linkedEventIDs/now closures and a pinned Australia/Sydney timezone.

import XCTest
@testable import Jotty

final class CalendarInboxSourceTests: XCTestCase {

    private let tz = TimeZone(identifier: "Australia/Sydney")!

    // MARK: Helpers

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func event(_ id: String, _ title: String, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(eventKitID: id, title: title, start: start, end: end, calendarTitle: nil)
    }

    private func makeSource(calendar: FakeCalendarService,
                            enabled: Bool = true,
                            linked: [LinkedEventRef] = [],
                            now: Date) -> CalendarInboxSource {
        CalendarInboxSource(
            calendar: calendar,
            enabled: { enabled },
            linkedEventIDs: { _ in linked },
            now: { now },
            timezone: tz
        )
    }

    // MARK: SC1 — map today's timed events

    func test_mapsTodaysTimedEvents() async throws {
        let now = makeDate(2026, 7, 4, h: 9)
        let s1 = makeDate(2026, 7, 4, h: 10), e1 = makeDate(2026, 7, 4, h: 11)
        let s2 = makeDate(2026, 7, 4, h: 14), e2 = makeDate(2026, 7, 4, h: 15)
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-1", "Standup", start: s1, end: e1),
                             event("evt-2", "Design review", start: s2, end: e2)]

        let items = try await makeSource(calendar: fake, now: now).fetchItems()

        XCTAssertEqual(items.count, 2)
        // Item ids carry the occurrence-unique composite (bare id + start), so two
        // occurrences of one recurring series never share an inbox identity.
        XCTAssertEqual(items[0].id, "calendar:evt-1@\(s1.timeIntervalSince1970)")
        XCTAssertEqual(items[0].sourceID, "calendar")
        XCTAssertEqual(items[0].title, "Standup")
        XCTAssertEqual(items[0].timestamp, s1)
        XCTAssertEqual(items[0].timeBlock, TimeBlock(start: s1, end: e1))
        XCTAssertEqual(items[0].calEventID, "evt-1")
        XCTAssertEqual(items[0].url, CalendarURL.show(for: s1)?.absoluteString)
        XCTAssertEqual(items[1].id, "calendar:evt-2@\(s2.timeIntervalSince1970)")
        XCTAssertEqual(items[1].calEventID, "evt-2")
        XCTAssertEqual(items[1].timeBlock, TimeBlock(start: s2, end: e2))
    }

    // MARK: SC1/P3 — today window pinned in the injected timezone (never .current)

    func test_queriesTodayWindowInPinnedTimezone() async throws {
        let now = makeDate(2026, 7, 4, h: 15)
        let fake = FakeCalendarService()

        _ = try await makeSource(calendar: fake, now: now).fetchItems()

        let cal = DailyFile.calendar(timezone: tz)
        let expectedStart = cal.startOfDay(for: now)
        let expectedEnd = cal.date(byAdding: .day, value: 1, to: expectedStart)!
        XCTAssertEqual(fake.lastEventsInRangeStart, expectedStart)
        XCTAssertEqual(fake.lastEventsInRangeEnd, expectedEnd)
    }

    // MARK: SC4/P2 — already-linked occurrences filtered (bare id + block start)

    func test_excludesAlreadyLinkedEvents() async throws {
        let now = makeDate(2026, 7, 4, h: 9)
        let s1 = makeDate(2026, 7, 4, h: 10), e1 = makeDate(2026, 7, 4, h: 11)
        let s2 = makeDate(2026, 7, 4, h: 14), e2 = makeDate(2026, 7, 4, h: 15)
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-1", "Already linked", start: s1, end: e1),
                             event("evt-2", "Fresh", start: s2, end: e2)]

        let items = try await makeSource(
            calendar: fake,
            linked: [LinkedEventRef(eventKitID: "evt-1", start: s1)],
            now: now).fetchItems()

        XCTAssertEqual(items.map(\.calEventID), ["evt-2"])
    }

    /// Recurring series: linking ONE occurrence must not hide its siblings. The refs
    /// carry the linked task's block start, so only the occurrence within the drift
    /// tolerance of that start is filtered — the 13:00 standup stays suggested after
    /// the 09:00 one is accepted. (Filtering on the bare id alone hid the whole series.)
    func test_linkedOccurrenceDoesNotHideOtherOccurrencesOfSameSeries() async throws {
        let now = makeDate(2026, 7, 4, h: 8)
        let s1 = makeDate(2026, 7, 4, h: 9), e1 = makeDate(2026, 7, 4, h: 9, min: 30)
        let s2 = makeDate(2026, 7, 4, h: 13), e2 = makeDate(2026, 7, 4, h: 13, min: 30)
        let fake = FakeCalendarService()
        // EventKit gives every occurrence of a series the SAME eventIdentifier.
        fake.cannedEvents = [event("series-1", "Standup", start: s1, end: e1),
                             event("series-1", "Standup", start: s2, end: e2)]

        let items = try await makeSource(
            calendar: fake,
            linked: [LinkedEventRef(eventKitID: "series-1", start: s1)],
            now: now).fetchItems()

        XCTAssertEqual(items.map(\.timestamp), [s2], "only the un-linked occurrence remains")
    }

    /// A linked task whose block start drifted a few seconds (sub-tolerance jitter
    /// between the markdown wall-clock and the EKEvent instant) still claims its
    /// occurrence — exact-instant matching would re-suggest an already-linked event.
    func test_linkedRefMatchesWithinDriftTolerance() async throws {
        let now = makeDate(2026, 7, 4, h: 8)
        let s1 = makeDate(2026, 7, 4, h: 9), e1 = makeDate(2026, 7, 4, h: 9, min: 30)
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-1", "Standup", start: s1, end: e1)]

        let items = try await makeSource(
            calendar: fake,
            linked: [LinkedEventRef(eventKitID: "evt-1", start: s1.addingTimeInterval(30))],
            now: now).fetchItems()

        XCTAssertTrue(items.isEmpty, "a 30s-jittered link still claims the occurrence")
    }

    /// A SOLE occurrence is claimed by its bare id regardless of start: an event the
    /// user rescheduled in Calendar.app (start moved well beyond the 60s tolerance)
    /// must not resurface as a suggestion while its task still links it — the drift
    /// prompt owns that reconciliation, and accepting the "suggestion" would write a
    /// duplicate task.
    func test_externallyRescheduledLinkedEventStaysClaimed() async throws {
        let now = makeDate(2026, 7, 4, h: 8)
        let movedStart = makeDate(2026, 7, 4, h: 10)   // was linked at 09:00
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-1", "1:1 with Sam",
                                   start: movedStart,
                                   end: makeDate(2026, 7, 4, h: 10, min: 30))]

        let items = try await makeSource(
            calendar: fake,
            linked: [LinkedEventRef(eventKitID: "evt-1", start: makeDate(2026, 7, 4, h: 9))],
            now: now).fetchItems()

        XCTAssertTrue(items.isEmpty,
                      "a rescheduled sole occurrence is still the linked event, not a new suggestion")
    }

    /// A linked ref with NO start (a linked task missing its time block, e.g. after a
    /// failed disk write) conservatively hides every occurrence of that series.
    func test_linkedRefWithNilStartHidesAllOccurrences() async throws {
        let now = makeDate(2026, 7, 4, h: 8)
        let s1 = makeDate(2026, 7, 4, h: 9), e1 = makeDate(2026, 7, 4, h: 9, min: 30)
        let s2 = makeDate(2026, 7, 4, h: 13), e2 = makeDate(2026, 7, 4, h: 13, min: 30)
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("series-1", "Standup", start: s1, end: e1),
                             event("series-1", "Standup", start: s2, end: e2)]

        let items = try await makeSource(
            calendar: fake,
            linked: [LinkedEventRef(eventKitID: "series-1", start: nil)],
            now: now).fetchItems()

        XCTAssertTrue(items.isEmpty)
    }

    // MARK: Calendar visibility — hidden calendars never suggest

    func test_hiddenCalendarEventsAreNotSuggested() async throws {
        let now = makeDate(2026, 7, 4, h: 9)
        let s1 = makeDate(2026, 7, 4, h: 10), e1 = makeDate(2026, 7, 4, h: 11)
        let s2 = makeDate(2026, 7, 4, h: 14), e2 = makeDate(2026, 7, 4, h: 15)
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(eventKitID: "evt-work", title: "Standup", start: s1, end: e1,
                          calendarTitle: "Work", calendarID: "cal-work"),
            CalendarEvent(eventKitID: "evt-personal", title: "Dentist", start: s2, end: e2,
                          calendarTitle: "Personal", calendarID: "cal-personal"),
        ]
        let source = CalendarInboxSource(
            calendar: fake,
            enabled: { true },
            linkedEventIDs: { _ in [] },
            now: { now },
            timezone: tz,
            visibleCalendarIDs: { ["cal-personal"] })

        let items = try await source.fetchItems()

        XCTAssertEqual(items.map(\.calEventID), ["evt-personal"],
                       "an event the user hid from display must not resurface as a suggestion")
    }

    // MARK: SC5/P4 — disabled ⇒ zero reads, zero prompt (short-circuits before access())

    func test_disabledDoesZeroCalendarReads() async throws {
        let now = makeDate(2026, 7, 4, h: 9)
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-1", "X", start: now, end: now)]

        let source = makeSource(calendar: fake, enabled: false, now: now)
        let items = try await source.fetchItems()

        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(fake.calls.contains(.eventsInRange))
        XCTAssertFalse(fake.calls.contains(.requestAccess))
        XCTAssertFalse(fake.calls.contains(.access))  // enabled() short-circuits before access()
    }

    // MARK: SC5/P4 — denied / notDetermined ⇒ never read or prompt

    func test_deniedAndNotDeterminedNeverReadOrPrompt() async throws {
        let now = makeDate(2026, 7, 4, h: 9)
        for access in [CalendarAccess.denied, .notDetermined] {
            let fake = FakeCalendarService()
            fake.accessToReturn = access
            fake.cannedEvents = [event("evt-1", "X", start: now, end: now)]

            let source = makeSource(calendar: fake, now: now)
            let items = try await source.fetchItems()

            XCTAssertTrue(items.isEmpty, "access=\(access)")
            XCTAssertFalse(fake.calls.contains(.eventsInRange), "access=\(access)")
            XCTAssertFalse(fake.calls.contains(.requestAccess), "access=\(access)")
            XCTAssertFalse(source.isConfigured, "access=\(access)")
        }
    }

    // MARK: isConfigured mirrors enabled() && access()==.authorized

    func test_isConfiguredMirrorsEnabledAndAccess() {
        let now = makeDate(2026, 7, 4, h: 9)
        let authFake = FakeCalendarService()
        authFake.accessToReturn = .authorized
        XCTAssertTrue(makeSource(calendar: authFake, enabled: true, now: now).isConfigured)
        XCTAssertFalse(makeSource(calendar: authFake, enabled: false, now: now).isConfigured)

        let deniedFake = FakeCalendarService()
        deniedFake.accessToReturn = .denied
        XCTAssertFalse(makeSource(calendar: deniedFake, enabled: true, now: now).isConfigured)
    }
}
