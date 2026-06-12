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
    func testAnchorInjection() {
        let text = ExtractionPrompt.text(now: fixedNow, timezone: sydney)

        XCTAssertTrue(text.contains("2026-06-09T03:00:00Z"),
                      "prompt should contain the ISO-8601 form of the fixed date")
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
