import XCTest
@testable import Jotty

/// Exhaustive table tests for the conservative single-clock-time matcher (#time-reliability).
/// The NEGATIVE table is load-bearing: a false positive silently blocks the wrong calendar
/// slot, which is worse than a miss. Every "must not match" shape from the spec is pinned.
final class NaturalTimeTests: XCTestCase {

    /// Asserts `text` yields a match at (hour, minute) and that the matched substring == `matched`.
    private func expectMatch(_ text: String, _ hour: Int, _ minute: Int,
                             matched: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let m = NaturalTime.firstMatch(in: text) else {
            return XCTFail("expected a match in \(text.debugDescription)", file: file, line: line)
        }
        XCTAssertEqual(m.hour, hour, "hour for \(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(m.minute, minute, "minute for \(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(String(text[m.range]), matched,
                       "matched substring for \(text.debugDescription)", file: file, line: line)
    }

    private func expectNoMatch(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        if let m = NaturalTime.firstMatch(in: text) {
            XCTFail("expected NO match in \(text.debugDescription), got \(String(text[m.range]).debugDescription) → \(m.hour):\(m.minute)",
                    file: file, line: line)
        }
    }

    // MARK: - POSITIVE table

    func testMeridiemForms() {
        expectMatch("Call Asim at 9pm today", 21, 0, matched: "9pm")
        expectMatch("standup 9 pm", 21, 0, matched: "9 pm")
        expectMatch("review 9:30pm", 21, 30, matched: "9:30pm")
        expectMatch("review 9:30 pm", 21, 30, matched: "9:30 pm")
        expectMatch("wake 12am", 0, 0, matched: "12am")
        expectMatch("lunch 12pm", 12, 0, matched: "12pm")
        expectMatch("gym 9am", 9, 0, matched: "9am")
        expectMatch("early 6AM", 6, 0, matched: "6AM")
    }

    func testColonForms24Hour() {
        expectMatch("deploy 9:30", 9, 30, matched: "9:30")
        expectMatch("deploy 17:00", 17, 0, matched: "17:00")
        expectMatch("standup 08:05", 8, 5, matched: "08:05")
        expectMatch("midnight 00:00", 0, 0, matched: "00:00")
        expectMatch("late 23:59", 23, 59, matched: "23:59")
    }

    func testAtPrefixOnlyWithMeridiemOrColon() {
        expectMatch("Call Asim at 9pm", 21, 0, matched: "9pm")
        expectMatch("meet at 5pm", 17, 0, matched: "5pm")
        expectMatch("sync at 17:30", 17, 30, matched: "17:30")
    }

    func testFirstMatchWinsWhenMultiple() {
        // The FIRST unambiguous time is returned; a later one is ignored.
        expectMatch("call at 9pm then again 10pm", 21, 0, matched: "9pm")
    }

    func testValidTimeAfterRejectedCandidate() {
        // A phone-like 911 is skipped; the later real time is still found.
        expectMatch("dial 911 then call at 9pm", 21, 0, matched: "9pm")
    }

    // MARK: - NEGATIVE table (load-bearing: false positives block the wrong slot)

    func testBareNumberNeverMatches() {
        expectNoMatch("read section 9")
        expectNoMatch("call 9")
        expectNoMatch("item 5")
        expectNoMatch("at 5")          // `at <hour>` with no am/pm and no colon is ambiguous
        expectNoMatch("at 9 today")
        expectNoMatch("chapter 17")
    }

    func testDurationsNeverMatch() {
        expectNoMatch("2 hours of focus")
        expectNoMatch("30 min standup")
        expectNoMatch("an hour of code review")
        expectNoMatch("couple hours tomorrow")
        expectNoMatch("1-2 hours of refactor")
        expectNoMatch("half hour break")
    }

    func testRangesAreNotSingleProcessed() {
        // Ranges belong to the AI/range path — never single-match one endpoint.
        expectNoMatch("block 1-2pm laptop setup")
        expectNoMatch("from 9-11am")
    }

    func testPhoneLikeNeverMatches() {
        expectNoMatch("call 911")
        expectNoMatch("dial 1-800-555")
        expectNoMatch("ext 12345")
    }

    func testMoneyNeverMatches() {
        expectNoMatch("owe $9.99")
        expectNoMatch("costs $12")
        expectNoMatch("$5pm budget")   // $ glued before → rejected even with pm
    }

    func testDatesAndFractionsNeverMatch() {
        expectNoMatch("due 2026-07-10")
        expectNoMatch("ratio 9/10")
        expectNoMatch("version 1.5")
        expectNoMatch("split 3/4")
    }

    func testEmptyAndPunctuation() {
        expectNoMatch("")
        expectNoMatch("   ")
        expectNoMatch("just some prose with no time")
    }

    func testInvalidClockValuesRejected() {
        expectNoMatch("code 25:00")    // hour > 23
        expectNoMatch("code 12:99")    // minute > 59
        expectNoMatch("count 13pm")    // 12-hour hour > 12
    }
}
