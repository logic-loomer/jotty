import XCTest
@testable import Jotty

final class RolloverServiceTests: XCTestCase {
    var folder: URL!
    var statePath: URL!
    let tz = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        statePath = folder.appendingPathComponent("last-rollover.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testFirstLaunchNoOps() throws {
        let store = Store(folder: folder, timezone: tz)
        let now = makeDate(2026, 5, 8)
        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: now)
        let saved = try String(contentsOf: statePath, encoding: .utf8)
        XCTAssertEqual(saved, "2026-05-08")
    }

    func testIncompleteTaskRollsForward() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 5, 7, h: 7, m: 30)
        let today = makeDate(2026, 5, 8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [
                                    Todo(id: "t_a", text: "leftover", createdAt: yesterday),
                                    Todo(id: "t_b", text: "done", createdAt: yesterday,
                                         done: true, completedAt: yesterday)
                                ],
                                at: yesterday)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: today)

        let todayDoc = try store.readDoc(on: today)
        XCTAssertTrue(todayDoc.tasks.contains { $0.id == "t_a" && !$0.done })
        XCTAssertFalse(todayDoc.tasks.contains { $0.id == "t_b" })

        let ydayDoc = try store.readDoc(on: yesterday)
        XCTAssertEqual(ydayDoc.tasks.first(where: { $0.id == "t_a" })?.rolledTo
                       .flatMap(dateOnly), "2026-05-08")
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, m mn: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func dateOnly(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
        return f.string(from: d)
    }
}

private extension URL {
    func write(string: String) throws {
        try string.write(to: self, atomically: true, encoding: .utf8)
    }
}
