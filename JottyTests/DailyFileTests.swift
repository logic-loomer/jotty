import XCTest
@testable import Jotty

final class DailyFileTests: XCTestCase {
    func testURLForDate() {
        let folder = URL(fileURLWithPath: "/tmp/Jotty")
        let date = makeDate(2026, 5, 8)
        let url = DailyFile.url(in: folder, on: date,
                                timezone: TimeZone(identifier: "Australia/Sydney")!)
        XCTAssertEqual(url.path, "/tmp/Jotty/2026-05-08.md")
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
