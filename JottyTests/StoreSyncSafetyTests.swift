import XCTest
@testable import Jotty

/// Roadmap 3.4 phase 1 — sync-safety hardening. Design note:
/// brain/projects/jotty/2026-07-12-sync-safety-design.md
final class StoreSyncSafetyTests: XCTestCase {
    var folder: URL!
    var store: Store!
    let tz = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = Store(folder: folder, timezone: tz)
    }

    override func tearDown() {
        // Restore permissions so removeItem can clean up chmod-000 fixtures.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names {
                let p = folder.appendingPathComponent(name).path
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p)
            }
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeDate(_ y: Int, _ mo: Int, _ d: Int, h: Int, m: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = m
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: comps)!
    }

    // MARK: - Absent vs unreadable (the evicted-iCloud-file clobber, design §Phase 1)

    /// An I/O-layer read failure (permissions blip, dataless iCloud file offline)
    /// must FAIL the operation — not masquerade as an absent file whose next write
    /// clobbers the whole day with a fresh doc.
    func testAppendToUnreadableDayFileThrowsAndLeavesFileUntouched() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "precious existing content", at: date, id: "n_001")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let originalBytes = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(
            try store.appendNote(text: "new capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_002")
        ) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable, got \(error)")
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "unreadable day file must never be overwritten")
    }

    /// A genuinely missing file keeps today's behavior: fresh doc, capture lands.
    func testAppendToAbsentDayFileStillCreatesFreshDoc() throws {
        let date = makeDate(2026, 5, 9, h: 9, m: 0)
        try store.appendNote(text: "first of the day", at: date, id: "n_003")
        let body = try String(contentsOf: folder.appendingPathComponent("2026-05-09.md"), encoding: .utf8)
        XCTAssertTrue(body.contains("first of the day"))
    }

    /// Guarded ops (rename/toggle/…) on an unreadable file must also throw rather
    /// than silently no-op — the caller needs to surface the failure notice.
    func testRenameOnUnreadableDayFileThrows() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "seed", at: date, id: "n_010")
        let url = folder.appendingPathComponent("2026-05-08.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(try store.renameTodo(id: "t_1", text: "new", on: date)) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable, got \(error)")
            }
        }
    }
}
