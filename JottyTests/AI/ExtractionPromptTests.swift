// JottyTests/AI/ExtractionPromptTests.swift
// Anchor-injection and rules-presence coverage for ExtractionPrompt — the
// single shared extraction system prompt consumed by AppleFMProvider and the
// cloud/Ollama providers. The prompt extraction from AppleFMProvider is a
// behavior-preserving refactor; AppleFMProviderSubsetTests is the regression
// bar for the wording itself.

import XCTest
@testable import Jotty

final class ExtractionPromptTests: XCTestCase {

    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    /// 2026-06-09T03:00:00Z — a Tuesday in both UTC and Sydney (13:00 AEST).
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-06-09T03:00:00Z")!

    // Test 1 — anchor injection: ISO now + timezone identifier + weekday name.
    // The anchor renders in the SUPPLIED timezone (offset form), not UTC: the line
    // is labelled "Current local date-time anchor", so 03:00Z must appear as
    // 13:00+10:00 — the same wall-clock day the weekday is computed from.
    func testAnchorInjection() {
        let text = ExtractionPrompt.text(now: fixedNow, timezone: sydney)

        XCTAssertTrue(text.contains("2026-06-09T13:00:00+10:00"),
                      "anchor should be the local (Sydney) wall-clock form of the fixed date, not UTC")
        XCTAssertFalse(text.contains("2026-06-09T03:00:00Z"),
                       "anchor must NOT be the UTC form — that mislabels a UTC instant as 'local'")
        XCTAssertTrue(text.contains("Australia/Sydney"),
                      "prompt should contain the timezone identifier")
        // A fresh gregorian Calendar carries the fixed locale, whose
        // weekdaySymbols are abbreviated ("Tue") — same behavior as the
        // original AppleFMProvider.makeSession logic this was extracted from.
        XCTAssertTrue(text.contains("Weekday: Tue."),
                      "prompt should contain the weekday name of the fixed date")
        XCTAssertTrue(text.contains("Current local date-time anchor:"),
                      "prompt should carry the anchor line verbatim")
    }

    // Test 1b — weekday is computed in the supplied timezone, not UTC.
    // 2026-06-09T20:00:00Z is Tuesday in UTC but already Wednesday 06:00 in Sydney.
    func testWeekdayResolvesInSuppliedTimezone() {
        let lateUTC = ISO8601DateFormatter().date(from: "2026-06-09T20:00:00Z")!
        let text = ExtractionPrompt.text(now: lateUTC, timezone: sydney)

        XCTAssertTrue(text.contains("Weekday: Wed."),
                      "weekday must resolve in the supplied timezone (Sydney is a day ahead)")
    }

    // Test 1c — REGRESSION (#date-off-by-one): early local morning, when the user's
    // timezone is AHEAD of UTC, the local calendar day is already the NEXT day while
    // UTC is still on the previous one. The anchor DATE must be the local day so the
    // model resolves "today" correctly — else a task captured at 00:30 Mon lands on Sun.
    // 2026-07-06T00:30:00+10:00 == 2026-07-05T14:30:00Z (Mon locally, still Sun in UTC).
    func testAnchorUsesLocalDayNotUTCDay() {
        let earlyMonday = ISO8601DateFormatter().date(from: "2026-07-05T14:30:00Z")!
        let text = ExtractionPrompt.text(now: earlyMonday, timezone: sydney)

        XCTAssertTrue(text.contains("2026-07-06T00:30:00+10:00"),
                      "anchor must carry the LOCAL day (Jul 6), the day the user is actually in")
        XCTAssertFalse(text.contains("2026-07-05"),
                       "anchor must NOT expose the UTC day (Jul 5) — that is what stamped tasks a day early")
        XCTAssertTrue(text.contains("Weekday: Mon."),
                      "weekday must match the local anchor day (Monday), not the UTC day (Sunday)")
    }

    // Test 2 — rules present: sentinel strings prove the full rules block
    // moved into ExtractionPrompt, not a stub.
    func testRulesBlockPresent() {
        let text = ExtractionPrompt.text(now: fixedNow, timezone: sydney)

        XCTAssertTrue(text.contains("Bare duration NEVER becomes a timeBlock"),
                      "duration rule sentinel missing — rules block not fully moved")
        XCTAssertTrue(text.contains("Past-tense / completed-action: ZERO tasks"),
                      "past-tense rule sentinel missing — rules block not fully moved")
    }
}
