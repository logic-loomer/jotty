import XCTest
@testable import Jotty

/// #8: the pure typed-token parser for manual capture. Fixed `asOf` = Wednesday 2026-07-08
/// 09:30 in a no-DST UTC zone so every time-block hour and weekday resolution is deterministic.
final class CaptureTokenParserTests: XCTestCase {
    private let tz = TimeZone(secondsFromGMT: 0)!
    private var cal: Calendar { DailyFile.calendar(timezone: tz) }
    /// Wednesday, 2026-07-08 09:30 UTC.
    private var asOf: Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 30))!
    }

    private func parse(_ s: String) -> CaptureTokenParser.Result {
        CaptureTokenParser.parse(s, asOf: asOf, timezone: tz)
    }

    /// Start-of-day for a concrete calendar date (unambiguous — not derived from the parser).
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A wall-clock instant on a concrete calendar date.
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var thirtyMin: TimeInterval { TimeInterval(CaptureTokenParser.defaultDurationMinutes * 60) }

    // MARK: - Fixture sanity

    func testFixtureIsWednesday() {
        XCTAssertEqual(cal.component(.weekday, from: asOf), 4, "2026-07-08 must be a Wednesday")
    }

    // MARK: - No tokens → pass through

    func testPlainTitleUnchanged() {
        let r = parse("call mom")
        XCTAssertEqual(r.cleanTitle, "call mom")
        XCTAssertNil(r.dueDate)
        XCTAssertNil(r.timeBlock)
    }

    func testEmailAddressNotEaten() {
        let r = parse("reply to jane@work.com about invoice")
        XCTAssertEqual(r.cleanTitle, "reply to jane@work.com about invoice")
        XCTAssertNil(r.dueDate)
        XCTAssertNil(r.timeBlock)
    }

    func testUnknownAtWordNotEaten() {
        let r = parse("ping @channel now")
        XCTAssertEqual(r.cleanTitle, "ping @channel now")
        XCTAssertNil(r.dueDate)
        XCTAssertNil(r.timeBlock)
    }

    func testUnknownDueValueNotEaten() {
        let r = parse("ship it due:soon")
        XCTAssertEqual(r.cleanTitle, "ship it due:soon")
        XCTAssertNil(r.dueDate)
        XCTAssertNil(r.timeBlock)
    }

    func testHourOutOfRangeNotEaten() {
        let r = parse("meet @25")   // 25 is not a valid 24h hour
        XCTAssertEqual(r.cleanTitle, "meet @25")
        XCTAssertNil(r.timeBlock)
    }

    // MARK: - Time tokens (block on today when no day named)

    func test12HourPM() {
        let r = parse("standup @3pm")
        XCTAssertEqual(r.cleanTitle, "standup")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 15, 0))
        XCTAssertEqual(r.timeBlock?.end, at(2026, 7, 8, 15, 0).addingTimeInterval(thirtyMin))
        XCTAssertNil(r.dueDate, "bare @time schedules today without stamping a due date")
    }

    func test12HourAM() {
        let r = parse("gym @9am")
        XCTAssertEqual(r.cleanTitle, "gym")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 9, 0))
    }

    func test24HourColon() {
        let r = parse("deploy @15:00")
        XCTAssertEqual(r.cleanTitle, "deploy")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 15, 0))
    }

    func testBareHourIs24Hour() {
        let r = parse("call @9")
        XCTAssertEqual(r.cleanTitle, "call")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 9, 0),
                       "bare @9 is 09:00, not 9pm")
    }

    func test12HourWithMinutes() {
        let r = parse("review @3:30pm")
        XCTAssertEqual(r.cleanTitle, "review")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 15, 30))
    }

    func testNoonAndMidnightMeridiem() {
        XCTAssertEqual(parse("lunch @12pm").timeBlock?.start, at(2026, 7, 8, 12, 0))
        XCTAssertEqual(parse("wake @12am").timeBlock?.start, at(2026, 7, 8, 0, 0))
    }

    // MARK: - Day tokens (@)

    func testAtToday() {
        let r = parse("file taxes @today")
        XCTAssertEqual(r.cleanTitle, "file taxes")
        XCTAssertEqual(r.dueDate, day(2026, 7, 8))
        XCTAssertNil(r.timeBlock)
    }

    func testAtTomorrow() {
        let r = parse("renew domain @tomorrow")
        XCTAssertEqual(r.cleanTitle, "renew domain")
        XCTAssertEqual(r.dueDate, day(2026, 7, 9))
    }

    func testAtWeekdayFullName() {
        let r = parse("submit report @friday")
        XCTAssertEqual(r.cleanTitle, "submit report")
        XCTAssertEqual(r.dueDate, day(2026, 7, 10))   // next Friday from Wed
    }

    func testAtWeekdayAbbrevNextWeek() {
        let r = parse("standup @mon")
        XCTAssertEqual(r.cleanTitle, "standup")
        XCTAssertEqual(r.dueDate, day(2026, 7, 13))   // next Monday from Wed
    }

    func testAtWeekdayTodayCounts() {
        let r = parse("ship @wed")
        XCTAssertEqual(r.dueDate, day(2026, 7, 8), "same weekday resolves to today")
    }

    // MARK: - due: tokens

    func testDueWeekday() {
        let r = parse("invoice due:fri")
        XCTAssertEqual(r.cleanTitle, "invoice")
        XCTAssertEqual(r.dueDate, day(2026, 7, 10))
    }

    func testDueTomorrow() {
        let r = parse("call back due:tomorrow")
        XCTAssertEqual(r.cleanTitle, "call back")
        XCTAssertEqual(r.dueDate, day(2026, 7, 9))
    }

    func testDueISODate() {
        let r = parse("launch due:2026-07-10")
        XCTAssertEqual(r.cleanTitle, "launch")
        XCTAssertEqual(r.dueDate, day(2026, 7, 10))
        XCTAssertNil(r.timeBlock)
    }

    // MARK: - Combined day + time

    func testTomorrowPlusTime() {
        let r = parse("call dentist @tomorrow @3pm")
        XCTAssertEqual(r.cleanTitle, "call dentist")
        XCTAssertEqual(r.dueDate, day(2026, 7, 9), "day token stamps a due date")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 9, 15, 0), "time block lands on tomorrow")
        XCTAssertEqual(r.timeBlock?.end, at(2026, 7, 9, 15, 0).addingTimeInterval(thirtyMin))
    }

    func testDueWeekdayPlusTime() {
        let r = parse("demo due:fri @9am")
        XCTAssertEqual(r.cleanTitle, "demo")
        XCTAssertEqual(r.dueDate, day(2026, 7, 10))
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 10, 9, 0))
    }

    // MARK: - Title cleanup

    func testTokensStrippedMidSentenceNoDoubleSpace() {
        let r = parse("call @tomorrow the dentist @3pm")
        XCTAssertEqual(r.cleanTitle, "call the dentist")
        XCTAssertFalse(r.cleanTitle.contains("  "), "no double spaces after token removal")
    }

    func testTokenOnlyLineKeepsBareTitle() {
        // Stripping would empty the title → treat as token-free (no empty task, no schedule).
        let r = parse("@3pm")
        XCTAssertEqual(r.cleanTitle, "@3pm")
        XCTAssertNil(r.dueDate)
        XCTAssertNil(r.timeBlock)
    }

    func testLastDayTokenWins() {
        let r = parse("thing @today @tomorrow")
        XCTAssertEqual(r.cleanTitle, "thing")
        XCTAssertEqual(r.dueDate, day(2026, 7, 9))
    }

    // MARK: - Natural clock-time fallback (#time-reliability)

    func testNaturalTimeBlocksOnTodayAndStripsPhrase() {
        let r = parse("Call Asim at 9pm")
        XCTAssertEqual(r.cleanTitle, "Call Asim", "the 'at 9pm' phrase is stripped")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 21, 0))
        XCTAssertEqual(r.timeBlock?.end, at(2026, 7, 8, 21, 0).addingTimeInterval(thirtyMin))
        XCTAssertNil(r.dueDate, "a natural time schedules today without a due date")
    }

    func testNaturalColonTime() {
        let r = parse("deploy 17:00")
        XCTAssertEqual(r.cleanTitle, "deploy")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 17, 0))
    }

    func testAtTokenTimeStillWinsOverNatural() {
        // An explicit @time token must take precedence; the natural fallback never runs.
        let r = parse("standup @3pm at 9pm")
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 8, 15, 0), "@3pm wins, not the natural 9pm")
        XCTAssertTrue(r.cleanTitle.contains("9pm"), "natural phrase left intact when @token wins")
    }

    func testNaturalTimeCombinesWithDueDay() {
        // A day token sets the due date; the natural time lands the block on that day.
        let r = parse("call dentist @tomorrow at 9pm")
        XCTAssertEqual(r.cleanTitle, "call dentist")
        XCTAssertEqual(r.dueDate, day(2026, 7, 9))
        XCTAssertEqual(r.timeBlock?.start, at(2026, 7, 9, 21, 0))
    }

    func testNonTimeLineUnchangedByNaturalFallback() {
        let r = parse("read section 9")
        XCTAssertEqual(r.cleanTitle, "read section 9")
        XCTAssertNil(r.timeBlock)
        XCTAssertNil(r.dueDate)
    }

    func testDurationNeverBlocksInManualPath() {
        let r = parse("focus 2 hours")
        XCTAssertEqual(r.cleanTitle, "focus 2 hours")
        XCTAssertNil(r.timeBlock)
    }
}
