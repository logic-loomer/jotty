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

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
