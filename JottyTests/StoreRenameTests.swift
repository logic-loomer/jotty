import XCTest
@testable import Jotty

/// SC4 (inline rename + move-to-tomorrow). RED in plan 06-01 (`Store.renameTodo`
/// and `Store.moveTodoToTomorrow` did not exist yet); GREEN in plan 06-03 — that
/// plan adds the two `Store` methods, then activates the real assertions below.
///
/// The assertions are the executable contract 06-03 satisfies:
///  - renameTodo rewrites ONLY task.text, preserving id / created / time: / cal_event:
///  - empty-after-trim rename is rejected (no-op, original text intact)
///  - a rename whose text contains `<!--` survives the markdown parse round-trip
///  - moveTodoToTomorrow removes the task from today and lands it on tomorrow's file
final class StoreRenameTests: XCTestCase {
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

    func testRenamePreservesIdCreatedTimeAndCalEventTokens() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let start = makeDate(2026, 5, 8, h: 14, m: 0)
        let end = makeDate(2026, 5, 8, h: 15, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_001", text: "old text", createdAt: now,
                 timeBlock: TimeBlock(start: start, end: end), calEventID: "evt-abc")
        ], at: now)

        try store.renameTodo(id: "t_001", text: "new text", on: now)

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first { $0.id == "t_001" })
        XCTAssertEqual(task.text, "new text")
        XCTAssertEqual(task.id, "t_001")
        XCTAssertEqual(task.calEventID, "evt-abc")
        XCTAssertEqual(task.timeBlock, TimeBlock(start: start, end: end))
    }

    func testRenameTrimsSurroundingWhitespace() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)], at: now)
        try store.renameTodo(id: "t_001", text: "  spaced out  ", on: now)
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first).text, "spaced out")
    }

    func testRenameRejectsEmptyAfterTrim() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "keep", createdAt: now)], at: now)
        // Capture the file bytes before the rejected rename so we can prove no write happened.
        let url = folder.appendingPathComponent("2026-05-08.md")
        let before = try String(contentsOf: url, encoding: .utf8)
        try store.renameTodo(id: "t_001", text: "   ", on: now)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(before, after, "empty-after-trim rename must leave the file byte-identical")
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first).text, "keep")
    }

    func testRenameMissingIdIsNoOp() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "keep", createdAt: now)], at: now)
        try store.renameTodo(id: "t_nope", text: "ignored", on: now)
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_001"])
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first).text, "keep")
    }

    func testRenameWithCommentDelimiterSurvivesRoundTrip() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)], at: now)
        try store.renameTodo(id: "t_001", text: "look <!-- not a real token -->", on: now)
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first { $0.id == "t_001" })
        // The comment delimiter must NOT shift the structural boundary: id + tokens survive.
        XCTAssertEqual(task.id, "t_001")
        XCTAssertTrue(task.text.contains("look"))
    }

    func testMoveToTomorrowRemovesFromTodayAndLandsOnTomorrow() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "carry over", createdAt: now)], at: now)

        try store.moveTodoToTomorrow(id: "t_001", on: now)

        XCTAssertTrue(try store.readDoc(on: now).tasks.isEmpty)
        XCTAssertEqual(try store.readDoc(on: tomorrow).tasks.map(\.id), ["t_001"])
    }

    func testMoveToTomorrowKeepsTextTokensAndRepartitionsCreatedAt() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 7, m: 30)
        let start = makeDate(2026, 5, 8, h: 14, m: 0)
        let end = makeDate(2026, 5, 8, h: 15, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_001", text: "carry over", createdAt: now,
                 timeBlock: TimeBlock(start: start, end: end), calEventID: "evt-abc")
        ], at: now)

        try store.moveTodoToTomorrow(id: "t_001", on: now)

        let moved = try XCTUnwrap(try store.readDoc(on: tomorrow).tasks.first { $0.id == "t_001" })
        XCTAssertEqual(moved.text, "carry over")
        XCTAssertEqual(moved.calEventID, "evt-abc")
        XCTAssertEqual(moved.timeBlock, TimeBlock(start: start, end: end))
        XCTAssertFalse(moved.done, "a moved task is not completed")
        // createdAt advanced to tomorrow's startOfDay so the menubar groups it as a
        // tomorrow task, NOT a !done leftover from today.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        XCTAssertEqual(moved.createdAt, cal.startOfDay(for: tomorrow))
    }

    func testMoveToTomorrowMissingIdIsNoOp() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "stay", createdAt: now)], at: now)
        try store.moveTodoToTomorrow(id: "t_nope", on: now)
        XCTAssertEqual(try store.readDoc(on: now).tasks.map(\.id), ["t_001"])
        XCTAssertTrue(try store.readDoc(on: tomorrow).tasks.isEmpty)
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
