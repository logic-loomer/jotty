// JottyTests/AI/DurationGuardrailTests.swift
// Tests for the shared DurationGuardrail helper (plan 04-09, Task 9.1).
// The guardrail was extracted verbatim from AppleFMProvider so that the
// Ollama provider (and any future provider) reuses identical behavior:
// duration phrases ("couple hours", "1-2 hours") never become time blocks.

import XCTest
@testable import Jotty

final class DurationGuardrailTests: XCTestCase {

    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let now = Date(timeIntervalSince1970: 1_781_300_000) // fixed instant

    private var sydneyCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = sydney
        return cal
    }

    // MARK: Test 1 — duration with day reference strips the timeBlock

    func testDurationWithDayReferenceStripsTimeBlockAndInfersDueDate() {
        let input = "couple hours of design review tomorrow"
        let bogusBlock = TimeBlock(
            start: now,
            end: now.addingTimeInterval(3600)
        )
        let tasks = [ExtractedTask(
            title: "design review",
            dueDate: nil,
            timeBlock: bogusBlock,
            calendarBlock: true
        )]

        let result = DurationGuardrail.apply(
            tasks, against: input, now: now, timezone: sydney)

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].timeBlock,
                     "duration phrase without clock anchor must strip the timeBlock")
        XCTAssertFalse(result[0].calendarBlock)

        let cal = sydneyCalendar
        let expectedTomorrow = cal.date(
            byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        XCTAssertEqual(result[0].dueDate, expectedTomorrow,
                       "'tomorrow' in the input must infer dueDate = tomorrow (Sydney)")
    }

    // MARK: Test 2 — explicit clock time leaves the task untouched

    func testExplicitClockTimeLeavesTaskUnchanged() {
        let input = "block 1-2pm code review"
        let block = TimeBlock(
            start: now,
            end: now.addingTimeInterval(3600)
        )
        let tasks = [ExtractedTask(
            title: "code review",
            dueDate: nil,
            timeBlock: block,
            calendarBlock: true
        )]

        let result = DurationGuardrail.apply(
            tasks, against: input, now: now, timezone: sydney)

        XCTAssertEqual(result, tasks,
                       "explicit clock time present — guardrail must not strip anything")
    }
}
