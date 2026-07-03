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

    // 07.1-05 CQ-09: Todo.newID() is the single task-ID authority. The format is
    // REQUIREMENTS-pinned (decision 2026-05-08) as t_<8 hex> — pin it so any change
    // to the derivation is a deliberate, test-visible act.
    func testNewIDMatchesPinnedFormat() {
        let pinned = /^t_[0-9a-f]{8}$/
        for _ in 0..<100 {
            let id = Todo.newID()
            XCTAssertNotNil(id.wholeMatch(of: pinned),
                            "\(id) must match the pinned t_<8 hex> format")
        }
    }

    // 07.1-05 CQ-09: consecutive IDs must differ (UUID-derived, not constant).
    func testNewIDConsecutiveCallsDiffer() {
        XCTAssertNotEqual(Todo.newID(), Todo.newID())
    }

    // 07.1-05 CQ-09: Note.newID() is the parallel note-ID authority, pinned to n_<8 hex>.
    func testNoteNewIDMatchesPinnedFormat() {
        let pinned = /^n_[0-9a-f]{8}$/
        for _ in 0..<100 {
            let id = Note.newID()
            XCTAssertNotNil(id.wholeMatch(of: pinned),
                            "\(id) must match the pinned n_<8 hex> format")
        }
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
