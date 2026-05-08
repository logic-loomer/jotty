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
}
