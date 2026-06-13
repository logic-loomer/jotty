import XCTest
@testable import Jotty

/// SC4 (inline rename + move-to-tomorrow). RED in plan 06-01 (`Store.renameTodo`
/// and `Store.moveTodoToTomorrow` do not exist yet); GREEN in plan 06-03 — that
/// plan adds the two `Store` methods, then removes the `#if false` guard + the
/// `XCTFail` marker below to activate the real assertions.
///
/// The guarded block is the executable contract 06-03 must satisfy:
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

    func testStoreRenameAndMoveContractPendingPlan06_03() {
        // GREEN in plan 06-03 — replace this marker with the guarded assertions.
        XCTFail("RED: Store.renameTodo / moveTodoToTomorrow not implemented yet (owned by plan 06-03)")
    }

    #if false
    // GREEN in plan 06-03: delete the #if false guard once the Store methods exist.

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

    func testRenameRejectsEmptyAfterTrim() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "keep", createdAt: now)], at: now)
        try store.renameTodo(id: "t_001", text: "   ", on: now)
        let doc = try store.readDoc(on: now)
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
    #endif

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
