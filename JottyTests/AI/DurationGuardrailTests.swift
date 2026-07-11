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

    // MARK: "from N to N" is a clock anchor (WR: legit blocks stripped)

    /// A bare-digits clock range co-occurring with a duration phrase must NOT trip
    /// the whole-input strip: "meet Sam from 9 to 11, then an hour of email" carries
    /// a legitimate meeting block that the gate previously threw away along with the
    /// duration's ("an hour" matched, no am/pm/HH:MM anchor recognized).
    func testFromToClockRangeWithDurationPhraseKeepsBlocks() {
        let input = "meet Sam from 9 to 11 for planning, then an hour of email triage"
        let meetingBlock = TimeBlock(start: now, end: now.addingTimeInterval(2 * 3600))
        let tasks = [
            ExtractedTask(title: "meet Sam for planning", dueDate: nil,
                          timeBlock: meetingBlock, calendarBlock: true),
            ExtractedTask(title: "email triage", dueDate: nil,
                          timeBlock: nil, calendarBlock: false),
        ]
        let result = DurationGuardrail.apply(tasks, against: input, now: now, timezone: sydney)
        XCTAssertEqual(result, tasks,
                       "'from 9 to 11' is an explicit clock anchor — nothing may be stripped")
    }

    /// The pure-duration case still strips: no clock anchor anywhere in the input.
    func testDurationOnlyStillStripsWithoutFromToRange() {
        let input = "an hour of email triage"
        let bogus = TimeBlock(start: now, end: now.addingTimeInterval(3600))
        let tasks = [ExtractedTask(title: "email triage", dueDate: nil,
                                   timeBlock: bogus, calendarBlock: true)]
        let result = DurationGuardrail.apply(tasks, against: input, now: now, timezone: sydney)
        XCTAssertNil(result[0].timeBlock, "a bare duration must still never become a block")
    }
}
