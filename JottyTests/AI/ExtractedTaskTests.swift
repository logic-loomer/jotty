import XCTest
@testable import Jotty

final class ExtractedTaskTests: XCTestCase {

    var now: Date!
    var later: Date!
    var tb: TimeBlock!

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSinceReferenceDate: 0)
        later = Date(timeIntervalSinceReferenceDate: 3600)
        tb = TimeBlock(start: now, end: later)
    }

    func testTimeBlockHoldsStartAndEnd() {
        XCTAssertEqual(tb.start, now)
        XCTAssertEqual(tb.end, later)
    }

    func testExtractedTaskFullFields() {
        let task = ExtractedTask(
            title: "ship",
            dueDate: now,
            timeBlock: tb,
            calendarBlock: true
        )
        XCTAssertEqual(task.title, "ship")
        XCTAssertEqual(task.dueDate, now)
        XCTAssertEqual(task.timeBlock, tb)
        XCTAssertTrue(task.calendarBlock)
    }

    func testExtractedTaskOptionalDefaults() {
        let task = ExtractedTask(title: "ship")
        XCTAssertNil(task.dueDate)
        XCTAssertNil(task.timeBlock)
        XCTAssertFalse(task.calendarBlock)
    }

    func testExtractionResultHoldsTasksAndBody() {
        let t1 = ExtractedTask(title: "task one")
        let t2 = ExtractedTask(title: "task two")
        let result = ExtractionResult(tasks: [t1, t2], noteBody: "raw")
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.noteBody, "raw")
    }

    func testExtractedTaskEquatable() {
        let a = ExtractedTask(title: "ship", dueDate: now, timeBlock: tb, calendarBlock: true)
        let b = ExtractedTask(title: "ship", dueDate: now, timeBlock: tb, calendarBlock: true)
        XCTAssertEqual(a, b)
    }
}
