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

    // IN-01: task text containing the comment delimiters must not corrupt the round-trip.
    func testTaskTextWithCommentDelimitersDoesNotCorruptRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        // A calendar-sourced title (via SC4 sync) could carry these delimiters.
        doc.appendTodo(Todo(id: "t_x", text: "plan <!-- secret --> review", createdAt: now))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)

        // The metadata still parses cleanly (id survives, exactly one task).
        XCTAssertEqual(parsed.tasks.count, 1)
        let task = try XCTUnwrap(parsed.tasks.first)
        XCTAssertEqual(task.id, "t_x", "metadata boundary must not be shifted by delimiters in text")
        // Delimiters were neutralized in the text, so they cannot break the parser.
        XCTAssertFalse(task.text.contains("<!--"), "comment-open delimiter must be neutralized")
        XCTAssertFalse(task.text.contains("-->"), "comment-close delimiter must be neutralized")
    }

    private func dateOnlyString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Australia/Sydney")
        return f.string(from: d)
    }

    // Phase 5 plan 01: time:HH:MM-HH:MM serializes and re-parses to the same
    // wall-clock start/end on the doc's date.
    func testTimeBlockRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_001", text: "deep work", createdAt: now,
                            timeBlock: tb))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("time:08:00-09:30"),
                      "serialized line should carry time:08:00-09:30")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let parsedTB = try XCTUnwrap(parsed.tasks[0].timeBlock)
        XCTAssertEqual(parsedTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(parsedTB.end.timeIntervalSince1970,
                       tb.end.timeIntervalSince1970, accuracy: 1.0)
    }

    // Phase 5 plan 01: cal_event:<id> serializes and re-parses to the identical id.
    func testCalEventRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_001", text: "linked", createdAt: now,
                            calEventID: "ABC123:DEF456"))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("cal_event:ABC123:DEF456"),
                      "serialized line should carry cal_event:ABC123:DEF456")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].calEventID, "ABC123:DEF456")
    }

    // Phase 5 plan 01: done + due + rolled_to + source_note + time + cal_event
    // all together round-trip with no token clobbering another.
    func testAllTokensRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_777", text: "everything", createdAt: now,
                            done: true,
                            completedAt: timeFor("2026-05-08T10:00:00+10:00"),
                            dueDate: dateFor("2026-05-09"),
                            rolledTo: dateFor("2026-05-10"),
                            sourceNote: "n_042",
                            timeBlock: tb,
                            calEventID: "EVT:9001"))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_777")
        XCTAssertEqual(t.text, "everything")
        XCTAssertTrue(t.done)
        XCTAssertNotNil(t.completedAt)
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(t.rolledTo.flatMap(dateOnlyString), "2026-05-10")
        XCTAssertEqual(t.sourceNote, "n_042")
        let allTB = try XCTUnwrap(t.timeBlock)
        XCTAssertEqual(allTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(allTB.end.timeIntervalSince1970,
                       tb.end.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(t.calEventID, "EVT:9001")
    }

    // Phase 5 plan 01: a legacy task line WITHOUT time:/cal_event: still parses
    // (new fields nil) — back-compat with pre-Phase-5 files. Includes a
    // createdAt-based line to protect Phase 2.5 leftover detection.
    func testLegacyTaskLineParsesWithNilCalendarFields() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let legacy = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] old task <!-- id:t_legacy created:2026-05-08T07:30:00+10:00 due:2026-05-09 rolled_to:2026-05-10 source_note:n_001 -->

        ## Notes

        """
        let parsed = try MarkdownDoc.parse(legacy, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_legacy")
        XCTAssertNil(t.timeBlock, "legacy line has no time: -> timeBlock nil")
        XCTAssertNil(t.calEventID, "legacy line has no cal_event: -> calEventID nil")
        // Phase 2.5 createdAt-based detection still resolves the original created date.
        XCTAssertEqual(t.createdAt.timeIntervalSince1970,
                       timeFor("2026-05-08T07:30:00+10:00").timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(t.rolledTo.flatMap(dateOnlyString), "2026-05-10")
        XCTAssertEqual(t.sourceNote, "n_001")
    }

    // Phase 5 plan 01 / T-5-01: a calEventID containing whitespace must NOT be
    // written as a token (would split into a bogus token and corrupt the line).
    func testCalEventWithWhitespaceIsNotSerialized() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_001", text: "spaced id", createdAt: now,
                            calEventID: "BAD ID 123"))
        let serialized = doc.serialize(timezone: tz)
        XCTAssertFalse(serialized.contains("cal_event:"),
                       "a whitespace-bearing event id must be skipped, not corrupt the line")
        // The line must still be well-formed and re-parse.
        XCTAssertNoThrow(try MarkdownDoc.parse(serialized, timezone: tz))
    }
}
