import XCTest
@testable import Jotty

@MainActor
final class MenubarListModelTests: XCTestCase {
    var folder: URL!
    var defaults: UserDefaults!
    var suiteName: String!
    let tz = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Grouping

    func testLeftoverGroupedByCreatedAtDatePart() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        // Both tasks live in TODAY's file (simulating a rolled copy + a fresh task).
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday),
            Todo(id: "t_new", text: "fresh", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertEqual(model.leftovers.map(\.id), ["t_old"])
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_new"])
        XCTAssertFalse(model.leftoversCollapsed)
    }

    func testNoLeftoversEmptyArray() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "fresh one", createdAt: today),
            Todo(id: "t_b", text: "fresh two", createdAt: makeDate(2026, 6, 12, h: 7))
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertEqual(model.leftovers, [])
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_a", "t_b"])
    }

    // MARK: - Collapse trigger

    func testToggleLeftoverCollapsesAndPersists() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday),
            Todo(id: "t_new", text: "fresh", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let leftover = try XCTUnwrap(model.leftovers.first)
        model.toggle(leftover)

        XCTAssertTrue(model.leftoversCollapsed)
        XCTAssertTrue(defaults.bool(forKey: "leftoversCollapsed-2026-06-12"))
    }

    func testToggleTodayTaskDoesNotCollapse() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday),
            Todo(id: "t_new", text: "fresh", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let todayTask = try XCTUnwrap(model.todayTasks.first)
        model.toggle(todayTask)

        XCTAssertFalse(model.leftoversCollapsed)
        XCTAssertNil(defaults.object(forKey: "leftoversCollapsed-2026-06-12"))
    }

    func testReloadDoesNotCollapse() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        // Popover open simulation: repeated reloads must never collapse.
        model.reload()
        model.reload()
        model.reload()

        XCTAssertFalse(model.leftoversCollapsed)
        XCTAssertNil(defaults.object(forKey: "leftoversCollapsed-2026-06-12"))
    }

    // MARK: - Persistence / day reset

    func testNewDayResetsToExpanded() throws {
        let store = Store(folder: folder, timezone: tz)
        let tomorrow = makeDate(2026, 6, 13, h: 8)
        // Collapsed yesterday (2026-06-12); a leftover exists in tomorrow's file.
        defaults.set(true, forKey: "leftoversCollapsed-2026-06-12")
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: makeDate(2026, 6, 12, h: 9))
        ], at: tomorrow)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { tomorrow })
        XCTAssertFalse(model.leftoversCollapsed)
    }

    func testManualSetCollapsedRoundTrips() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday)
        ], at: today)

        let first = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        first.setCollapsed(true)
        XCTAssertTrue(first.leftoversCollapsed)

        // Fresh model (popover reopen) reads the persisted flag.
        let second = MenubarListModel(store: store, timezone: tz,
                                      defaults: defaults, now: { today })
        XCTAssertTrue(second.leftoversCollapsed)

        // Manual expand persists for the rest of the day (Assumption A3).
        second.setCollapsed(false)
        XCTAssertFalse(second.leftoversCollapsed)

        let third = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertFalse(third.leftoversCollapsed)
    }

    func testToggleAfterManualExpandStaysExpanded() throws {
        // MA-01 regression: a manual expand (key present) is the user's choice
        // and must survive subsequent leftover toggles the same day.
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old1", text: "leftover one", createdAt: yesterday),
            Todo(id: "t_old2", text: "leftover two", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let first = try XCTUnwrap(model.leftovers.first)
        model.toggle(first) // first interaction of the day auto-collapses
        XCTAssertTrue(model.leftoversCollapsed)

        model.setCollapsed(false) // manual expand via the header
        let second = try XCTUnwrap(model.leftovers.first)
        model.toggle(second) // must NOT re-collapse

        XCTAssertFalse(model.leftoversCollapsed)
        XCTAssertFalse(defaults.bool(forKey: "leftoversCollapsed-2026-06-12"))
    }

    // MARK: - Done / undone membership

    func testCompletedLeftoverLeavesSection() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let leftover = try XCTUnwrap(model.leftovers.first)

        // Complete it: leaves the leftovers section, renders via normal done handling.
        model.toggle(leftover)
        XCTAssertFalse(model.leftovers.contains { $0.id == "t_old" })
        XCTAssertTrue(model.todayTasks.contains { $0.id == "t_old" && $0.done })

        // Uncheck it: returns to the leftovers section (membership = createdAt rule).
        let completed = try XCTUnwrap(model.todayTasks.first { $0.id == "t_old" })
        model.toggle(completed)
        XCTAssertTrue(model.leftovers.contains { $0.id == "t_old" && !$0.done })
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_old" })
    }

    // MARK: - Timezone boundary

    func testSydneyMidnightBoundary() throws {
        let store = Store(folder: folder, timezone: tz)
        let now = makeDate(2026, 6, 12, h: 0, m: 1)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_lateNight", text: "just before midnight",
                 createdAt: makeDate(2026, 6, 11, h: 23, m: 59)),
            Todo(id: "t_earlyToday", text: "just after midnight",
                 createdAt: makeDate(2026, 6, 12, h: 0, m: 1))
        ], at: now)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { now })
        XCTAssertEqual(model.leftovers.map(\.id), ["t_lateNight"])
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_earlyToday"])
    }

    // MARK: - Helpers

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, m mn: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
