import XCTest
@testable import Jotty

/// SC4: pure drift detection over linked tasks + store events.
///
/// `CalendarDrift.driftedTasks(_:against:)` splits linked tasks into `drifted` (title or
/// start/end changed beyond a 60s tolerance) and `missing` (linked event absent from the
/// store = deleted in Calendar). Only tasks with both `calEventID` and `timeBlock` are
/// candidates. Comparison is on absolute `Date` instants only (RESEARCH Pitfall 4).
final class DriftDetectionTests: XCTestCase {

    // MARK: - Fixtures (Sydney-pinned date construction, matching existing test idiom)

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func task(
        id: String = "t1",
        text: String,
        eventID: String?,
        start: String?,
        end: String?
    ) -> Todo {
        let tb: TimeBlock? = {
            guard let start, let end else { return nil }
            return TimeBlock(start: at(start), end: at(end))
        }()
        return Todo(id: id, text: text, createdAt: at("2026-06-13T06:00:00+10:00"),
                    timeBlock: tb, calEventID: eventID)
    }

    private func event(
        _ id: String,
        title: String,
        _ start: String,
        _ end: String
    ) -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: at(start), end: at(end), calendarTitle: "Work")
    }

    // MARK: - No drift

    func testExactMatchReportsNoDrift() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
    }

    func testSubToleranceStartShiftIsNotDrift() {
        // 59s start shift < 60s tolerance -> no drift.
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:00:59+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
    }

    func testSubToleranceEndShiftIsNotDrift() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:59+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty)
    }

    // MARK: - Drift on each field

    func testTitleChangeIsDrift() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup (moved)",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertEqual(result.drifted.map(\.task.id), ["t1"])
        XCTAssertEqual(result.drifted.map(\.event.id), ["e1"])
        XCTAssertTrue(result.missing.isEmpty)
    }

    func testStartShiftAtToleranceBoundaryIsDrift() {
        // exactly 60s -> drift (>= tolerance).
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:01:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertEqual(result.drifted.map(\.task.id), ["t1"])
    }

    func testEndShiftAtToleranceBoundaryIsDrift() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:31:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertEqual(result.drifted.map(\.task.id), ["t1"])
    }

    func testNegativeStartShiftBeyondToleranceIsDrift() {
        // event moved earlier by 5 min -> abs() catches it.
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Standup",
                            "2026-06-13T08:55:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertEqual(result.drifted.map(\.task.id), ["t1"])
    }

    // MARK: - Missing (deleted in Calendar), distinct from drifted

    func testLinkedEventAbsentFromStoreIsMissingNotDrifted() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("other", title: "Other",
                            "2026-06-13T11:00:00+10:00", "2026-06-13T12:00:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty)
        XCTAssertEqual(result.missing.map(\.id), ["t1"])
    }

    func testMissingWithEmptyStore() {
        let t = task(text: "Standup", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let result = CalendarDrift.driftedTasks([t], against: [])
        XCTAssertEqual(result.missing.map(\.id), ["t1"])
        XCTAssertTrue(result.drifted.isEmpty)
    }

    // MARK: - Non-candidate tasks are ignored

    func testTaskWithoutCalEventIDIsIgnored() {
        let t = task(text: "Standup", eventID: nil,
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let result = CalendarDrift.driftedTasks([t], against: [])
        XCTAssertTrue(result.drifted.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
    }

    func testTaskWithoutTimeBlockIsIgnored() {
        let t = task(text: "Standup", eventID: "e1", start: nil, end: nil)
        let events = [event("e1", title: "Standup",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
    }

    // MARK: - Shared sanitize prevents false drift from stripped markdown

    func testMarkdownTaskTextDoesNotFalseDriftAgainstSanitizedTitle() {
        // Event title was created with the sanitized text; task still carries markdown.
        let t = task(text: "**Ship** the `release`", eventID: "e1",
                     start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let events = [event("e1", title: "Ship the release",
                            "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:00+10:00")]
        let result = CalendarDrift.driftedTasks([t], against: events)
        XCTAssertTrue(result.drifted.isEmpty, "stripped-markdown title must match, not false-drift")
    }

    // MARK: - Mixed batch: drifted + missing + clean + non-candidate

    func testMixedBatchPartitionsCorrectly() {
        let clean = task(id: "clean", text: "Clean", eventID: "ec",
                         start: "2026-06-13T09:00:00+10:00", end: "2026-06-13T09:30:00+10:00")
        let drifted = task(id: "drift", text: "Drift", eventID: "ed",
                           start: "2026-06-13T10:00:00+10:00", end: "2026-06-13T10:30:00+10:00")
        let missing = task(id: "miss", text: "Miss", eventID: "em",
                           start: "2026-06-13T11:00:00+10:00", end: "2026-06-13T11:30:00+10:00")
        let noLink = task(id: "nolink", text: "NoLink", eventID: nil,
                          start: "2026-06-13T12:00:00+10:00", end: "2026-06-13T12:30:00+10:00")
        let events = [
            event("ec", title: "Clean", "2026-06-13T09:00:00+10:00", "2026-06-13T09:30:00+10:00"),
            event("ed", title: "Drift (renamed)", "2026-06-13T10:00:00+10:00", "2026-06-13T10:30:00+10:00"),
            // em not present -> missing
        ]
        let result = CalendarDrift.driftedTasks([clean, drifted, missing, noLink], against: events)
        XCTAssertEqual(result.drifted.map(\.task.id), ["drift"])
        XCTAssertEqual(result.drifted.map(\.event.id), ["ed"])
        XCTAssertEqual(result.missing.map(\.id), ["miss"])
    }
}
