// JottyTests/Calendar/CalendarCoordinatorTests.swift
// Direct tests for the calendar orchestration seam extracted from
// MenubarListModel. The coordinator is value-oriented (no published state), so
// every branch is testable here against FakeCalendarService without a model in
// the loop — the model-level suites keep covering the same flows end-to-end.

import XCTest
@testable import Jotty

@MainActor
final class CalendarCoordinatorTests: XCTestCase {

    private let tz = TimeZone(identifier: "Australia/Sydney")!

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func event(_ id: String, _ title: String, h: Int) -> CalendarEvent {
        CalendarEvent(eventKitID: id, title: title,
                      start: makeDate(2026, 6, 12, h: h),
                      end: makeDate(2026, 6, 12, h: h + 1), calendarTitle: "Work")
    }

    private var window: (start: Date, end: Date) {
        (makeDate(2026, 6, 12, h: 0), makeDate(2026, 6, 13, h: 0))
    }

    // MARK: - resolveAccess: the lazy gate

    func testResolveAccessAuthorizedNeverRePrompts() async {
        let fake = FakeCalendarService()
        let outcome = await CalendarCoordinator(calendar: fake)
            .resolveAccess(promptIfUndetermined: true)
        XCTAssertEqual(outcome, .granted)
        XCTAssertFalse(fake.calls.contains(.requestAccess), "authorized never re-prompts")
    }

    func testResolveAccessDeniedWithoutPromptingOrReads() async {
        let fake = FakeCalendarService()
        fake.accessToReturn = .denied
        let outcome = await CalendarCoordinator(calendar: fake)
            .resolveAccess(promptIfUndetermined: true)
        XCTAssertEqual(outcome, .denied)
        XCTAssertFalse(fake.calls.contains(.requestAccess))
        XCTAssertFalse(fake.calls.contains(.eventsInRange), "the gate performs zero reads")
    }

    func testResolveAccessNotDeterminedWithoutPromptIsUnavailable() async {
        // WR-06: a background reload must never fire the TCC dialog.
        let fake = FakeCalendarService()
        fake.accessToReturn = .notDetermined
        let outcome = await CalendarCoordinator(calendar: fake)
            .resolveAccess(promptIfUndetermined: false)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(fake.requestAccessCallCount, 0)
    }

    func testResolveAccessNotDeterminedPromptsOnceAndRefusalDegrades() async {
        // The fake's requestAccess returns accessToReturn (.notDetermined here,
        // != .authorized), modelling a refused prompt → denied outcome, one ask.
        let fake = FakeCalendarService()
        fake.accessToReturn = .notDetermined
        let outcome = await CalendarCoordinator(calendar: fake)
            .resolveAccess(promptIfUndetermined: true)
        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(fake.requestAccessCallCount, 1, "asks exactly once")
    }

    // MARK: - Window fetches

    func testFetchTimedEventsReturnsFetched() async {
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("e1", "Standup", h: 9)]
        let outcome = await CalendarCoordinator(calendar: fake)
            .fetchTimedEvents(from: window.start, to: window.end)
        XCTAssertEqual(outcome, .fetched(fake.cannedEvents))
    }

    func testFetchTimedEventsReadFailureIsFailed() async {
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "boom")
        let outcome = await CalendarCoordinator(calendar: fake)
            .fetchTimedEvents(from: window.start, to: window.end)
        XCTAssertEqual(outcome, .failed)
    }

    func testFetchAllDayEventsReturnsFetchedAndFailsSoft() async {
        let fake = FakeCalendarService()
        fake.cannedAllDayEvents = [
            CalendarEvent(eventKitID: "ad1", title: "PTO",
                          start: window.start, end: window.end, calendarTitle: "Team")
        ]
        let coordinator = CalendarCoordinator(calendar: fake)
        let ok = await coordinator.fetchAllDayEvents(from: window.start, to: window.end)
        XCTAssertEqual(ok, .fetched(fake.cannedAllDayEvents))

        fake.errorToThrow = .underlying(message: "boom")
        let bad = await coordinator.fetchAllDayEvents(from: window.start, to: window.end)
        XCTAssertEqual(bad, .failed, "the chip row degrades, never blocks")
    }

    // MARK: - updateOrRecreate (SC3)

    func testUpdateOrRecreateUpdatesInPlace() async {
        let fake = FakeCalendarService()
        let block = TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                              end: makeDate(2026, 6, 12, h: 15))
        let outcome = await CalendarCoordinator(calendar: fake)
            .updateOrRecreate(eventID: "evt-1", title: "review", block: block, context: "test")
        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(fake.updatedEventIDs, ["evt-1"])
        XCTAssertTrue(fake.createdEvents.isEmpty)
    }

    func testUpdateOrRecreateRecreatesWhenEventGone() async {
        let fake = FakeCalendarService()
        fake.updateErrorToThrow = .eventNotFound
        let block = TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                              end: makeDate(2026, 6, 12, h: 15))
        let outcome = await CalendarCoordinator(calendar: fake)
            .updateOrRecreate(eventID: "evt-gone", title: "review", block: block, context: "test")
        XCTAssertEqual(outcome, .recreated(newID: "fake-event-1"))
        XCTAssertEqual(fake.createdEvents.count, 1)
        XCTAssertEqual(fake.createdEvents.first?.title, "review")
    }

    func testUpdateOrRecreateOtherErrorIsFailedWithoutRecreate() async {
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "network")
        let block = TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                              end: makeDate(2026, 6, 12, h: 15))
        let outcome = await CalendarCoordinator(calendar: fake)
            .updateOrRecreate(eventID: "evt-1", title: "review", block: block, context: "test")
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fake.createdEvents.isEmpty, "a non-notFound error never recreates")
    }

    // MARK: - firstConflictTitle (SC5 gate query)

    func testFirstConflictTitleExcludesOwnEvent() async {
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("evt-own", "My meeting", h: 14),
                             event("evt-busy", "Busy Slot", h: 15)]
        let block = TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                              end: makeDate(2026, 6, 12, h: 16))
        let coordinator = CalendarCoordinator(calendar: fake)

        let excluding = await coordinator.firstConflictTitle(overlapping: block,
                                                             excludingEventID: "evt-own")
        XCTAssertEqual(excluding, "Busy Slot", "the task's own event is not a conflict")

        let bare = await coordinator.firstConflictTitle(overlapping: block,
                                                        excludingEventID: nil)
        XCTAssertEqual(bare, "My meeting", "no exclusion → first overlap wins")
    }

    func testFirstConflictTitleReadFailureIsNilNotFatal() async {
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "boom")
        let block = TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                              end: makeDate(2026, 6, 12, h: 15))
        let title = await CalendarCoordinator(calendar: fake)
            .firstConflictTitle(overlapping: block, excludingEventID: nil)
        XCTAssertNil(title, "a gate read failure falls through to the write, never blocks")
    }
}
