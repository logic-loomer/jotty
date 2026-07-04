import XCTest
@testable import Jotty

/// #3: the pure, shared metadata-badge formatter/derivations. Pins the strings and
/// the overdue day-boundary so the menubar list, review list, and command bar agree.
final class TaskBadgeTests: XCTestCase {

    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Time block

    func testTimeBlockPillIsZeroPaddedStart() {
        let tb = TimeBlock(start: date(2026, 6, 12, 9, 5), end: date(2026, 6, 12, 10, 0))
        XCTAssertEqual(TaskBadge.timeBlockPill(tb, timezone: tz), "09:05")
    }

    func testTimeBlockLabelTodayVsOtherDay() {
        let asOf = date(2026, 6, 12, 8)
        let today = TimeBlock(start: date(2026, 6, 12, 9, 0), end: date(2026, 6, 12, 10, 30))
        XCTAssertEqual(TaskBadge.timeBlockLabel(today, asOf: asOf, calendar: cal),
                       "today 09:00–10:30")
        // 2026-06-15 is a Monday.
        let other = TimeBlock(start: date(2026, 6, 15, 14, 0), end: date(2026, 6, 15, 15, 0))
        XCTAssertEqual(TaskBadge.timeBlockLabel(other, asOf: asOf, calendar: cal),
                       "Mon 14:00–15:00")
    }

    // MARK: - Due label

    func testDueLabelTodayTomorrowWeekdayDate() {
        let asOf = date(2026, 6, 12, 8)   // Friday
        XCTAssertEqual(TaskBadge.dueLabel(date(2026, 6, 12), asOf: asOf, calendar: cal), "today")
        XCTAssertEqual(TaskBadge.dueLabel(date(2026, 6, 13), asOf: asOf, calendar: cal), "tomorrow")
        // 2026-06-16 is a Tuesday (4 days out → full weekday name).
        XCTAssertEqual(TaskBadge.dueLabel(date(2026, 6, 16), asOf: asOf, calendar: cal), "Tuesday")
        // Beyond a week → "MMM d".
        XCTAssertEqual(TaskBadge.dueLabel(date(2026, 7, 10), asOf: asOf, calendar: cal), "Jul 10")
    }

    // MARK: - Overdue boundary

    func testIsOverdueDayBoundary() {
        let asOf = date(2026, 6, 12, 8)
        // Due yesterday, not done → overdue.
        let past = Todo(id: "a", text: "x", createdAt: asOf, dueDate: date(2026, 6, 11, 23))
        XCTAssertTrue(TaskBadge.isOverdue(past, asOf: asOf, calendar: cal))
        // Due today (even at 00:00) → NOT overdue (boundary is the day).
        let today = Todo(id: "b", text: "x", createdAt: asOf, dueDate: date(2026, 6, 12, 0))
        XCTAssertFalse(TaskBadge.isOverdue(today, asOf: asOf, calendar: cal))
        // Done → never overdue even if the due day is past.
        let done = Todo(id: "c", text: "x", createdAt: asOf, done: true, dueDate: date(2026, 6, 1))
        XCTAssertFalse(TaskBadge.isOverdue(done, asOf: asOf, calendar: cal))
        // No due date → never overdue.
        let bare = Todo(id: "d", text: "x", createdAt: asOf)
        XCTAssertFalse(TaskBadge.isOverdue(bare, asOf: asOf, calendar: cal))
    }

    // MARK: - Recurring glyph

    func testRecurringGlyph() {
        let asOf = date(2026, 6, 12)
        let template = Todo(id: "t", text: "x", createdAt: asOf, recur: .daily)
        XCTAssertEqual(TaskBadge.recurringGlyph(template), "repeat")
        let instance = Todo(id: "i", text: "x", createdAt: asOf, recurSrc: "t:2026-06-12")
        XCTAssertEqual(TaskBadge.recurringGlyph(instance), "repeat.circle")
        let plain = Todo(id: "p", text: "x", createdAt: asOf)
        XCTAssertNil(TaskBadge.recurringGlyph(plain))
    }
}
