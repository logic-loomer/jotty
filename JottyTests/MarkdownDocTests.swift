import XCTest
@testable import Jotty

final class MarkdownDocTests: XCTestCase {
    func testEmptyDocSerializes() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let text = doc.serialize(timezone: tz)
        XCTAssertTrue(text.contains("date: 2026-05-08"))
        XCTAssertTrue(text.contains("## Notes"))
    }

    func testAppendNoteAddsTimestampedEntry() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        doc.appendNote(text: "first thought",
                       at: timeFor("2026-05-08T07:30:00+10:00"),
                       id: "n_001")
        let text = doc.serialize(timezone: tz)
        XCTAssertTrue(text.contains("### 07:30 <!-- id:n_001 -->"))
        XCTAssertTrue(text.contains("first thought"))
    }

    func testRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: "hello",
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_001")
        doc1.appendNote(text: "world",
                        at: timeFor("2026-05-08T08:15:00+10:00"),
                        id: "n_002")
        let serialized = doc1.serialize(timezone: tz)

        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 2)
        XCTAssertEqual(doc2.notes[0].id, "n_001")
        XCTAssertEqual(doc2.notes[0].text, "hello")
        XCTAssertEqual(doc2.notes[1].id, "n_002")
        XCTAssertEqual(doc2.notes[1].text, "world")
    }

    private func dateFor(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Australia/Sydney")
        return f.date(from: s)!
    }

    private func timeFor(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    func testNoteBodyContainingHashHashHashIsPreserved() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: "before\n### inline heading not a section\nafter",
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_x")
        let serialized = doc1.serialize(timezone: tz)
        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 1)
        XCTAssertEqual(doc2.notes[0].text,
                       "before\n### inline heading not a section\nafter")
    }

    func testTasksRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")

        doc.appendTodo(Todo(id: "t_001", text: "first", createdAt: now))
        doc.appendTodo(Todo(id: "t_002", text: "second",
                            createdAt: now,
                            done: true,
                            completedAt: timeFor("2026-05-08T09:30:00+10:00")))
        doc.appendTodo(Todo(id: "t_003", text: "future",
                            createdAt: now,
                            dueDate: dateFor("2026-05-09")))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("- [ ] first <!-- id:t_001"))
        XCTAssertTrue(serialized.contains("- [x] second <!-- id:t_002"))
        XCTAssertTrue(serialized.contains("due:2026-05-09"))

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 3)
        XCTAssertEqual(parsed.tasks[0].id, "t_001")
        XCTAssertFalse(parsed.tasks[0].done)
        XCTAssertEqual(parsed.tasks[0].createdAt.timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(parsed.tasks[1].id, "t_002")
        XCTAssertTrue(parsed.tasks[1].done)
        XCTAssertNotNil(parsed.tasks[1].completedAt)
        XCTAssertEqual(parsed.tasks[2].dueDate.flatMap(dateOnlyString), "2026-05-09")
    }

    private func dateOnlyString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Australia/Sydney")
        return f.string(from: d)
    }
}
