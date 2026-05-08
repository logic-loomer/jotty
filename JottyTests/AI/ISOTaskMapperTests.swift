import XCTest
@testable import Jotty

final class ISOTaskMapperTests: XCTestCase {

    // MARK: - Invariant 1: Empty/whitespace title is dropped

    func test_emptyTitle_isDropped() {
        let ai = [
            ExtractedTaskAI(title: "   ", dueDateISO: nil, blockStartISO: nil, blockEndISO: nil)
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertTrue(result.isEmpty, "Whitespace-only title should produce no tasks")
    }

    // MARK: - Invariant 2: end ≤ start drops block but keeps task

    func test_blockEndBeforeStart_dropsBlock() {
        let ai = [
            ExtractedTaskAI(
                title: "dentist",
                dueDateISO: nil,
                blockStartISO: "2026-05-04T14:00:00-07:00",
                blockEndISO: "2026-05-04T13:00:00-07:00"   // end BEFORE start
            )
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertEqual(result.count, 1, "Task should still be emitted")
        XCTAssertNil(result[0].timeBlock, "Invalid time block should be nil")
        XCTAssertFalse(result[0].calendarBlock, "calendarBlock must be false when timeBlock is nil")
        XCTAssertEqual(result[0].title, "dentist")
    }

    // MARK: - Invariant 3: calendarBlock == (timeBlock != nil)

    func test_calendarBlockMirrorsTimeBlock_withValidBlock() {
        let ai = [
            ExtractedTaskAI(
                title: "standup",
                dueDateISO: nil,
                blockStartISO: "2026-05-04T09:00:00-07:00",
                blockEndISO: "2026-05-04T09:30:00-07:00"
            )
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result[0].timeBlock)
        XCTAssertTrue(result[0].calendarBlock, "calendarBlock must be true when timeBlock is set")
        XCTAssertEqual(result[0].calendarBlock, result[0].timeBlock != nil)
    }

    func test_calendarBlockMirrorsTimeBlock_withoutBlock() {
        let ai = [
            ExtractedTaskAI(
                title: "review PR",
                dueDateISO: nil,
                blockStartISO: nil,
                blockEndISO: nil
            )
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].timeBlock)
        XCTAssertFalse(result[0].calendarBlock, "calendarBlock must be false when timeBlock is nil")
        XCTAssertEqual(result[0].calendarBlock, result[0].timeBlock != nil)
    }

    // MARK: - Invariant 4: malformed dueDate drops field, keeps task

    func test_malformedDueDate_dropsField() {
        let ai = [
            ExtractedTaskAI(
                title: "submit report",
                dueDateISO: "Friday",   // not yyyy-MM-dd
                blockStartISO: nil,
                blockEndISO: nil
            )
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertEqual(result.count, 1, "Task should still be emitted")
        XCTAssertNil(result[0].dueDate, "Malformed dueDate should be nil")
        XCTAssertEqual(result[0].title, "submit report")
    }

    // MARK: - Invariant 5: timezone preserved in timeBlock

    func test_timezone_drift_resolvesToUserTZ() {
        let ai = [
            ExtractedTaskAI(
                title: "lunch",
                dueDateISO: nil,
                blockStartISO: "2026-05-04T13:00:00-07:00",
                blockEndISO: "2026-05-04T14:00:00-07:00"
            )
        ]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let result = ISOTaskMapper.map(ai, in: tz)
        XCTAssertEqual(result.count, 1)
        guard let block = result[0].timeBlock else {
            XCTFail("timeBlock should not be nil")
            return
        }

        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        XCTAssertEqual(fmt.string(from: block.start), "2026-05-04 13:00",
                       "Start time in user TZ must match the ISO offset")
    }
}
