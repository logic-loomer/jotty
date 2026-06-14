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

        try store.moveTodoToTomorrow(id: "t_001", from: now, now: now)

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

        try store.moveTodoToTomorrow(id: "t_001", from: now, now: now)

        let moved = try XCTUnwrap(try store.readDoc(on: tomorrow).tasks.first { $0.id == "t_001" })
        XCTAssertEqual(moved.text, "carry over")
        XCTAssertEqual(moved.calEventID, "evt-abc")
        // The `time:` token serializes as wall-clock HH:mm and re-parses against the
        // landing file's day, so a 14:00-15:00 block moves to tomorrow's 14:00-15:00.
        let movedStart = makeDate(2026, 5, 9, h: 14, m: 0)
        let movedEnd = makeDate(2026, 5, 9, h: 15, m: 0)
        XCTAssertEqual(moved.timeBlock, TimeBlock(start: movedStart, end: movedEnd))
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
        try store.moveTodoToTomorrow(id: "t_nope", from: now, now: now)
        XCTAssertEqual(try store.readDoc(on: now).tasks.map(\.id), ["t_001"])
        XCTAssertTrue(try store.readDoc(on: tomorrow).tasks.isEmpty)
    }

    func testMoveStaleSourceLandsRelativeToNowNotSource() throws {
        // CR-01 at the store layer: the destination is now()+1 day, derived from the
        // CURRENT day — never from the (past) source day. A task living in a 3-days-ago
        // file moves to now+1, removed from its old file.
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let sourceDay = makeDate(2026, 5, 5, h: 9, m: 0)   // 3 days before "now"
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let realTomorrow = makeDate(2026, 5, 9, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "stale", createdAt: sourceDay)],
                                at: sourceDay)

        try store.moveTodoToTomorrow(id: "t_001", from: sourceDay, now: now)

        // Removed from the old source file.
        XCTAssertTrue(try store.readDoc(on: sourceDay).tasks.isEmpty,
                      "removed from its old source day")
        // Landed on now+1, not source+1 (which would be 2026-05-06, in the past).
        XCTAssertEqual(try store.readDoc(on: realTomorrow).tasks.map(\.id), ["t_001"])
        let pastDay = makeDate(2026, 5, 6, h: 7, m: 30)   // source+1, the WRONG (past) day
        XCTAssertTrue(try store.readDoc(on: pastDay).tasks.isEmpty,
                      "must NOT land in source+1 past-day file")
    }

    func testMoveWhenSourceIsAlreadyTomorrowRepartitionsInPlace() throws {
        // Same-file branch: source day == tomorrow (now+1). The task stays in that file
        // but its createdAt advances to tomorrow's startOfDay (it must not be duplicated
        // or lost when remove+append target the same path).
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 10, m: 0)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "already future", createdAt: tomorrow)],
                                at: tomorrow)

        try store.moveTodoToTomorrow(id: "t_001", from: tomorrow, now: now)

        let docs = try store.readDoc(on: tomorrow).tasks
        XCTAssertEqual(docs.map(\.id), ["t_001"], "exactly one copy survives in the same file")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        XCTAssertEqual(docs.first?.createdAt, cal.startOfDay(for: tomorrow))
    }

    func testMoveToTomorrowPreservesSourceProvenanceAndAllTokens() throws {
        // Phase 7 CR-01 regression: an accepted inbox task carries source:/source_url:
        // (provenance back to the GitHub issue/PR) plus time:/cal_event:. The
        // field-by-field rebuild in moveTodoToTomorrow dropped source/sourceURL.
        // The copy-mutate fix must carry EVERY token across the cross-file move.
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 7, m: 30)
        let start = makeDate(2026, 5, 8, h: 14, m: 0)
        let end = makeDate(2026, 5, 8, h: 15, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_001", text: "from github", createdAt: now,
                 timeBlock: TimeBlock(start: start, end: end), calEventID: "evt-abc",
                 source: "github:123456", sourceURL: "https://github.com/o/r/issues/7")
        ], at: now)

        try store.moveTodoToTomorrow(id: "t_001", from: now, now: now)

        let moved = try XCTUnwrap(try store.readDoc(on: tomorrow).tasks.first { $0.id == "t_001" })
        XCTAssertEqual(moved.source, "github:123456", "source: token must survive the move")
        XCTAssertEqual(moved.sourceURL, "https://github.com/o/r/issues/7",
                       "source_url: token must survive the move")
        XCTAssertEqual(moved.calEventID, "evt-abc", "cal_event: token must survive the move")
        let movedStart = makeDate(2026, 5, 9, h: 14, m: 0)
        let movedEnd = makeDate(2026, 5, 9, h: 15, m: 0)
        XCTAssertEqual(moved.timeBlock, TimeBlock(start: movedStart, end: movedEnd),
                       "time: token must survive the move")
    }

    func testMoveSameFilePreservesSourceProvenance() throws {
        // Same-file branch (source day == tomorrow) must also carry source/sourceURL.
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tomorrow = makeDate(2026, 5, 9, h: 10, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_001", text: "from github", createdAt: tomorrow,
                 source: "github:999", sourceURL: "https://github.com/o/r/pull/9")
        ], at: tomorrow)

        try store.moveTodoToTomorrow(id: "t_001", from: tomorrow, now: now)

        let moved = try XCTUnwrap(try store.readDoc(on: tomorrow).tasks.first { $0.id == "t_001" })
        XCTAssertEqual(moved.source, "github:999")
        XCTAssertEqual(moved.sourceURL, "https://github.com/o/r/pull/9")
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
