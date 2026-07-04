import XCTest
@testable import Jotty

/// Phase 8 plan 01 / SC2 (CALX-02): the pure `Recurrence` value type.
/// parse/serialize round-trip + `isDue(on:templateWeekday:calendar:)` weekday math,
/// all against a timezone-pinned gregorian calendar (Australia/Sydney) — never
/// `Date()`-relative (RESEARCH Pitfall: timezone weekday math).
final class RecurrenceTests: XCTestCase {
    let tz = TimeZone(identifier: "Australia/Sydney")!

    private var sydney: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// Mirrors RolloverServiceTests.makeDate: wall-clock components in Sydney.
    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, m mn: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - parse

    func testParseNamedRules() {
        XCTAssertEqual(Recurrence.parse("daily"), .daily)
        XCTAssertEqual(Recurrence.parse("weekly"), .weekly(nil), "bare weekly → legacy nil weekday")
        XCTAssertEqual(Recurrence.parse("weekday"), .weekday)
    }

    /// Sweep INFO: a `weekly:<wd>` token captures the weekday the user chose the
    /// rule on; bare `weekly` stays back-compatible (nil = createdAt fallback).
    func testParseWeeklyWithExplicitWeekday() {
        XCTAssertEqual(Recurrence.parse("weekly:3"), .weekly(3))
        XCTAssertEqual(Recurrence.parse("weekly:1"), .weekly(1))
        XCTAssertEqual(Recurrence.parse("weekly:7"), .weekly(7))
        XCTAssertNil(Recurrence.parse("weekly:0"), "weekday ints are gregorian 1=Sun…7=Sat")
        XCTAssertNil(Recurrence.parse("weekly:8"))
        XCTAssertNil(Recurrence.parse("weekly:x"))
    }

    func testParseCustomCSV() {
        XCTAssertEqual(Recurrence.parse("custom:1,3,5"), .custom([1, 3, 5]))
    }

    func testParseCustomDedupes() {
        XCTAssertEqual(Recurrence.parse("custom:1,1,3"), .custom([1, 3]))
    }

    func testParseUnknownOrEmptyReturnsNil() {
        XCTAssertNil(Recurrence.parse("monthly"))
        XCTAssertNil(Recurrence.parse(""))
        XCTAssertNil(Recurrence.parse("DAILY"), "rules are lowercase tokens; unknown casing degrades to nil")
    }

    func testParseCustomWithNoNumbersReturnsNil() {
        XCTAssertNil(Recurrence.parse("custom:"))
        XCTAssertNil(Recurrence.parse("custom:,,"))
    }

    func testParseCustomWithInvalidWeekdaysReturnsNil() {
        // T-8-02: a hand-edited malformed value degrades to a non-recurring task.
        XCTAssertNil(Recurrence.parse("custom:a,b"))
        XCTAssertNil(Recurrence.parse("custom:0,8"), "weekday ints are gregorian 1=Sun…7=Sat")
    }

    // MARK: - serialize round-trip

    func testSerializeRoundTripsAllRuleShapes() {
        let rules: [Recurrence] = [.daily, .weekly(nil), .weekly(3), .weekday, .custom([1, 3, 5])]
        for rule in rules {
            XCTAssertEqual(Recurrence.parse(rule.serialize()), rule,
                           "parse(serialize()) must round-trip \(rule)")
        }
    }

    func testSerializeWeeklyTokenShapes() {
        XCTAssertEqual(Recurrence.weekly(nil).serialize(), "weekly", "legacy weekly stays bare")
        XCTAssertEqual(Recurrence.weekly(3).serialize(), "weekly:3")
    }

    func testSerializeCustomIsSortedAscending() {
        // Deterministic csv so the on-disk token is stable across runs.
        XCTAssertEqual(Recurrence.custom([5, 1, 3]).serialize(), "custom:1,3,5")
    }

    // MARK: - isDue (Australia/Sydney gregorian; 2026-06-15 is a Monday)

    func testDailyIsDueEveryDay() {
        // Sun 14th → Sat 20th June 2026, a full week.
        for day in 14...20 {
            XCTAssertTrue(Recurrence.daily.isDue(on: makeDate(2026, 6, day),
                                                 templateWeekday: 2, calendar: sydney),
                          ".daily must be due on 2026-06-\(day)")
        }
    }

    func testWeekdayIsDueMonThroughFriOnly() {
        // Mon 15th … Fri 19th are due.
        for day in 15...19 {
            XCTAssertTrue(Recurrence.weekday.isDue(on: makeDate(2026, 6, day),
                                                   templateWeekday: 2, calendar: sydney),
                          ".weekday must be due on 2026-06-\(day) (Mon–Fri)")
        }
        // Sat 20th and Sun 14th are NOT due.
        XCTAssertFalse(Recurrence.weekday.isDue(on: makeDate(2026, 6, 20),
                                                templateWeekday: 2, calendar: sydney),
                       ".weekday must NOT be due on Saturday")
        XCTAssertFalse(Recurrence.weekday.isDue(on: makeDate(2026, 6, 14),
                                                templateWeekday: 2, calendar: sydney),
                       ".weekday must NOT be due on Sunday")
    }

    func testWeeklyBareTokenIsDueOnTemplateWeekday() {
        // Legacy bare weekly (nil): falls back to the template weekday = Wednesday (4).
        // Wed 17 June 2026 is due; the rest are not.
        let rule = Recurrence.weekly(nil)
        XCTAssertTrue(rule.isDue(on: makeDate(2026, 6, 17),
                                 templateWeekday: 4, calendar: sydney),
                      "bare .weekly must fall back to the template weekday")
        for day in [14, 15, 16, 18, 19, 20] {
            XCTAssertFalse(rule.isDue(on: makeDate(2026, 6, day),
                                      templateWeekday: 4, calendar: sydney),
                           "bare .weekly must NOT be due on 2026-06-\(day)")
        }
    }

    /// Sweep INFO: an explicit weekday fires on THAT weekday, ignoring the
    /// createdAt-derived templateWeekday entirely. Tuesday(3) 16 June 2026.
    func testWeeklyExplicitWeekdayFiresOnChosenNotTemplateWeekday() {
        let rule = Recurrence.weekly(3)   // Tuesday
        XCTAssertTrue(rule.isDue(on: makeDate(2026, 6, 16),          // Tuesday
                                 templateWeekday: 5, calendar: sydney),
                      "explicit weekday must fire on Tuesday regardless of templateWeekday")
        XCTAssertFalse(rule.isDue(on: makeDate(2026, 6, 18),         // Thursday (templateWeekday)
                                  templateWeekday: 5, calendar: sydney),
                       "explicit weekday must NOT fire on the createdAt weekday")
    }

    func testCustomIsDueOnListedWeekdaysOnly() {
        // custom:1,5 = Sunday(1) + Thursday(5).
        let rule = Recurrence.custom([1, 5])
        XCTAssertTrue(rule.isDue(on: makeDate(2026, 6, 14),
                                 templateWeekday: 2, calendar: sydney),
                      "custom:1,5 must be due on Sunday 2026-06-14")
        XCTAssertTrue(rule.isDue(on: makeDate(2026, 6, 18),
                                 templateWeekday: 2, calendar: sydney),
                      "custom:1,5 must be due on Thursday 2026-06-18")
        for day in [15, 16, 17, 19, 20] {
            XCTAssertFalse(rule.isDue(on: makeDate(2026, 6, day),
                                      templateWeekday: 2, calendar: sydney),
                           "custom:1,5 must NOT be due on 2026-06-\(day)")
        }
    }

    func testIsDueUsesTheCalendarTimezoneNotUTC() {
        // 2026-06-20 08:00 in Sydney (AEST, +10) is Saturday there, but still
        // Friday 22:00 in UTC. The rule must answer for the CALENDAR's timezone.
        let instant = makeDate(2026, 6, 20, h: 8)

        XCTAssertFalse(Recurrence.weekday.isDue(on: instant,
                                                templateWeekday: 2, calendar: sydney),
                       "Saturday in Sydney → .weekday not due")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertTrue(Recurrence.weekday.isDue(on: instant,
                                               templateWeekday: 2, calendar: utc),
                      "the same instant is Friday in UTC → .weekday due there")
    }
}
