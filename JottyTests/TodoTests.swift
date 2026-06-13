import XCTest
@testable import Jotty

final class TodoTests: XCTestCase {
    func testInitWithDefaults() {
        let now = Date()
        let todo = Todo(id: "t_001", text: "ship Phase 2", createdAt: now)
        XCTAssertEqual(todo.id, "t_001")
        XCTAssertEqual(todo.text, "ship Phase 2")
        XCTAssertFalse(todo.done)
        XCTAssertNil(todo.completedAt)
        XCTAssertNil(todo.dueDate)
        XCTAssertNil(todo.rolledTo)
        XCTAssertNil(todo.sourceNote)
    }

    func testEquatable() {
        let now = Date()
        let a = Todo(id: "t_001", text: "x", createdAt: now)
        let b = Todo(id: "t_001", text: "x", createdAt: now)
        XCTAssertEqual(a, b)
    }

    // Phase 5 plan 01: calendar fields default to nil when omitted.
    func testCalendarFieldsDefaultNil() {
        let todo = Todo(id: "t_001", text: "x", createdAt: Date())
        XCTAssertNil(todo.timeBlock)
        XCTAssertNil(todo.calEventID)
    }

    // Phase 5 plan 01: a Todo initialized with a timeBlock and calEventID retains both.
    func testCalendarFieldsRetained() {
        let start = Date()
        let end = start.addingTimeInterval(5400)
        let tb = TimeBlock(start: start, end: end)
        let todo = Todo(id: "t_001", text: "x", createdAt: start,
                        timeBlock: tb, calEventID: "ABC123:DEF456")
        XCTAssertEqual(todo.timeBlock, tb)
        XCTAssertEqual(todo.calEventID, "ABC123:DEF456")
    }
}
