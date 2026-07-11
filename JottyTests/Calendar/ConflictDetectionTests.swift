import XCTest
@testable import Jotty

/// SC5: pure conflict detection over `CalendarEvent` value types.
///
/// `CalendarDrift.conflicts(start:end:against:)` returns the events whose interval
/// strictly overlaps the candidate window `[start, end)`. Touching endpoints do NOT
/// conflict. Pure Foundation: no EventKit, no store, no I/O.
final class ConflictDetectionTests: XCTestCase {

    // MARK: - Fixtures

    /// Sydney-pinned date builder matching the existing test idiom across JottyTests.
    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func event(_ id: String, _ start: String, _ end: String, title: String = "ev") -> CalendarEvent {
        CalendarEvent(eventKitID: id, title: title, start: at(start), end: at(end), calendarTitle: "Work")
    }

    // MARK: - Empty / disjoint

    func testEmptyEventListReturnsEmpty() {
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDisjointEventsReturnEmpty() {
        // Candidate 09:00-10:00; events entirely before and entirely after.
        let events = [
            event("before", "2026-06-13T07:00:00+10:00", "2026-06-13T08:00:00+10:00"),
            event("after", "2026-06-13T11:00:00+10:00", "2026-06-13T12:00:00+10:00"),
        ]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Touching endpoints (strict: NO conflict)

    func testEventEndingExactlyAtCandidateStartDoesNotConflict() {
        // event.end == candidate.start -> touching, not overlapping.
        let events = [event("touch-left", "2026-06-13T08:00:00+10:00", "2026-06-13T09:00:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEventStartingExactlyAtCandidateEndDoesNotConflict() {
        // event.start == candidate.end -> touching, not overlapping.
        let events = [event("touch-right", "2026-06-13T10:00:00+10:00", "2026-06-13T11:00:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Overlap cases

    func testPartialOverlapAtFrontConflicts() {
        // event 08:30-09:30 overlaps candidate 09:00-10:00.
        let events = [event("front", "2026-06-13T08:30:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertEqual(result.map(\.eventKitID), ["front"])
    }

    func testPartialOverlapAtBackConflicts() {
        let events = [event("back", "2026-06-13T09:30:00+10:00", "2026-06-13T10:30:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertEqual(result.map(\.eventKitID), ["back"])
    }

    func testEventFullyInsideCandidateConflicts() {
        let events = [event("inside", "2026-06-13T09:15:00+10:00", "2026-06-13T09:45:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertEqual(result.map(\.eventKitID), ["inside"])
    }

    func testCandidateFullyInsideEventConflicts() {
        let events = [event("enclosing", "2026-06-13T08:00:00+10:00", "2026-06-13T11:00:00+10:00")]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertEqual(result.map(\.eventKitID), ["enclosing"])
    }

    // MARK: - Multiple overlaps (stable order by start)

    func testMultipleOverlapsReturnedAllSortedByStart() {
        // Provided out of start-order; touching-left and disjoint-after excluded.
        let events = [
            event("b", "2026-06-13T09:30:00+10:00", "2026-06-13T10:30:00+10:00"),
            event("touch", "2026-06-13T08:00:00+10:00", "2026-06-13T09:00:00+10:00"), // touching, excluded
            event("a", "2026-06-13T08:30:00+10:00", "2026-06-13T09:15:00+10:00"),
            event("c", "2026-06-13T09:45:00+10:00", "2026-06-13T11:00:00+10:00"),
            event("far", "2026-06-13T12:00:00+10:00", "2026-06-13T13:00:00+10:00"), // disjoint, excluded
        ]
        let result = CalendarDrift.conflicts(
            start: at("2026-06-13T09:00:00+10:00"),
            end: at("2026-06-13T10:00:00+10:00"),
            against: events
        )
        XCTAssertEqual(result.map(\.eventKitID), ["a", "b", "c"])
    }

    // MARK: - Zero-length candidate window

    func testZeroLengthCandidateNeverConflicts() {
        // [t, t) is empty; strict overlap requires positive intersection -> no conflict.
        let t = "2026-06-13T09:00:00+10:00"
        let events = [event("spanning", "2026-06-13T08:00:00+10:00", "2026-06-13T10:00:00+10:00")]
        let result = CalendarDrift.conflicts(start: at(t), end: at(t), against: events)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Sanitize (shared title rule, also used by drift + plan 05 createEvent)

    func testSanitizeStripsBoldAndItalicMarkers() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "**Ship** the *release*"), "Ship the release")
    }

    func testSanitizeStripsInlineCodeBackticks() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "Fix `parser` bug"), "Fix parser bug")
    }

    func testSanitizeStripsLeadingHeadingHashes() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "## Review PR"), "Review PR")
    }

    func testSanitizeStripsControlCharacters() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "line\u{0007}one\ttwo"), "lineone two")
    }

    func testSanitizeCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "   spaced   out  task  "), "spaced out task")
    }

    func testSanitizeStripsUnderscoreEmphasis() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "do __the__ _thing_"), "do the thing")
    }

    func testSanitizeIsIdempotent() {
        let once = CalendarDrift.sanitize(title: "**a** `b` ## c")
        XCTAssertEqual(CalendarDrift.sanitize(title: once), once)
    }

    /// Sweep WR (CalendarDrift.swift:120): a `#` that only becomes leading AFTER
    /// backtick/emphasis/whitespace stripping was removed on the SECOND pass —
    /// so sanitize was not a fixed point for these titles → perpetual false
    /// drift + silent loss of the user's `#`. Every case must satisfy
    /// sanitize(x) == sanitize(sanitize(x)).
    func testSanitizeIsIdempotentForHashExposedByOtherSteps() {
        for title in ["**#1 priority**", "`#tag`", "  # x", "__#note__", "* #starred"] {
            let once = CalendarDrift.sanitize(title: title)
            XCTAssertEqual(CalendarDrift.sanitize(title: once), once,
                           "sanitize must be a fixed point for \(title.debugDescription)")
        }
    }

    func testSanitizePlainTitleUnchanged() {
        XCTAssertEqual(CalendarDrift.sanitize(title: "Standup at 9"), "Standup at 9")
    }
}
