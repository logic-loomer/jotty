import XCTest
@testable import Jotty

final class StoreTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAppendNoteCreatesFileIfMissing() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let date = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendNote(text: "hello", at: date, id: "n_001")

        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("### 07:30 <!-- id:n_001 -->"))
        XCTAssertTrue(body.contains("hello"))
    }

    func testAppendNoteAppendsToExisting() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let d1 = makeDate(2026, 5, 8, h: 7, m: 30)
        let d2 = makeDate(2026, 5, 8, h: 8, m: 15)
        try store.appendNote(text: "first", at: d1, id: "n_001")
        try store.appendNote(text: "second", at: d2, id: "n_002")

        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("first"))
        XCTAssertTrue(body.contains("second"))
        XCTAssertTrue(body.contains("n_001"))
        XCTAssertTrue(body.contains("n_002"))
    }

    func testAppendCaptureWritesTasksAndNoteTogether() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tasks = [Todo(id: "t_001", text: "one", createdAt: now)]
        try store.appendCapture(noteText: "a note", noteId: "n_001",
                                tasks: tasks, at: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] one <!-- id:t_001"))
        XCTAssertTrue(body.contains("a note"))
    }

    func testToggleTaskFlipsState() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)],
                                at: now)
        try store.toggleTodo(id: "t_001", on: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("- [x] x <!-- id:t_001"))
        XCTAssertTrue(body.contains("done:"), "completedAt should be serialized as 'done:<ISO>' on toggle-on")

        try store.toggleTodo(id: "t_001", on: now)
        let body2 = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body2.contains("- [ ] x <!-- id:t_001"))
        XCTAssertFalse(body2.contains("done:"), "'done:' metadata should be removed on toggle-off")
    }

    func testReplaceTasksOverwritesList() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "old", createdAt: now)],
                                at: now)
        try store.replaceTasks([Todo(id: "t_999", text: "new", createdAt: now)], on: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(body.contains("t_001"))
        XCTAssertTrue(body.contains("t_999"))
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
