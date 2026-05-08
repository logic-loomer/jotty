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
}
