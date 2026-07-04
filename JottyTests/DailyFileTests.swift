import XCTest
@testable import Jotty

final class DailyFileTests: XCTestCase {
    let tz = TimeZone(identifier: "Australia/Sydney")!

    func testURLForDate() {
        let folder = URL(fileURLWithPath: "/tmp/Jotty")
        let date = makeDate(2026, 5, 8)
        let url = DailyFile.url(in: folder, on: date, timezone: tz)
        XCTAssertEqual(url.path, "/tmp/Jotty/2026-05-08.md")
    }

    /// Iteration-3 WR: the day-file NAME is a machine-format key and must be
    /// the POSIX Gregorian rendering regardless of the host region calendar.
    /// An unpinned formatter under a Thai Buddhist region renders the
    /// era-shifted year ("2569-05-08") — which the POSIX/Gregorian parse in
    /// `allDayDates` reads as Gregorian year 2569, silently killing the
    /// recurrence template scan. The expectation here is a hard-coded literal
    /// (formatter-independent); the Buddhist formatter only demonstrates the
    /// hazard is real.
    func testURLNamingIsPinnedAgainstNonGregorianRegionCalendar() {
        let folder = URL(fileURLWithPath: "/tmp/Jotty")
        let date = makeDate(2026, 5, 8)
        let url = DailyFile.url(in: folder, on: date, timezone: tz)
        XCTAssertEqual(url.lastPathComponent, "2026-05-08.md")

        // What an UNPINNED formatter would render under a Thai Buddhist
        // region: an era-shifted year (2026 CE = 2569 BE).
        let buddhist = DateFormatter()
        buddhist.calendar = Calendar(identifier: .buddhist)
        buddhist.locale = Locale(identifier: "th_TH")
        buddhist.dateFormat = "yyyy-MM-dd"
        buddhist.timeZone = tz
        XCTAssertTrue(buddhist.string(from: date).hasPrefix("2569"),
                      "sanity: the era-shift hazard is real")
        XCTAssertNotEqual(url.lastPathComponent, buddhist.string(from: date) + ".md",
                          "the pinned name must never be the era-shifted rendering")
    }

    /// Iteration-3 WR round-trip: a file NAMED by `DailyFile.url` must parse
    /// back to the same day through `Store.allDayDates` (they now share ONE
    /// formatter, so writer/parser asymmetry is impossible by construction).
    /// Filenames that do not parse under the pinned formatter are skipped
    /// defensively, never a crash.
    func testURLRoundTripsThroughAllDayDatesAndJunkIsSkipped() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let date = makeDate(2026, 5, 8)
        let url = DailyFile.url(in: folder, on: date, timezone: tz)
        try "# 2026-05-08\n".write(to: url, atomically: true, encoding: .utf8)
        // Junk that must be skipped without crashing.
        try "scratch".write(to: folder.appendingPathComponent("notes.md"),
                            atomically: true, encoding: .utf8)
        try "readme".write(to: folder.appendingPathComponent("README.txt"),
                           atomically: true, encoding: .utf8)

        let store = Store(folder: folder, timezone: tz)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        XCTAssertEqual(store.allDayDates(), [cal.startOfDay(for: date)],
                       "url -> allDayDates must round-trip to the exact day; junk skipped")
    }

    /// #5: the ONE calendar factory must pin BOTH the Gregorian identifier and
    /// the caller's timeZone — a forgotten timeZone is the exact silent
    /// day-boundary bug the factory exists to prevent.
    func testCalendarFactoryPinsIdentifierAndTimeZone() {
        let cal = DailyFile.calendar(timezone: tz)
        XCTAssertEqual(cal.identifier, .gregorian)
        XCTAssertEqual(cal.timeZone, tz)

        // A different zone flows through (not hard-pinned to one zone).
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DailyFile.calendar(timezone: utc).timeZone, utc)
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
