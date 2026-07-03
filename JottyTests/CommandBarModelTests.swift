import XCTest
@testable import Jotty

/// CMDB-01/02 model layer (09-04): query→sections ranking with the locked
/// caps/order, id-tracked selection semantics, and Enter routing over existing
/// seams. Fixed fake action list (never the real registry) so scores are
/// hand-computable; historical items seeded via the internal
/// `merge(historical:generation:)` — the same entry point the detached build
/// uses in production.
@MainActor
final class CommandBarModelTests: XCTestCase {
    var folder: URL!
    var defaults: UserDefaults!
    var suiteName: String!

    /// Process timezone, matching CommandBarIndexTests: CommandItem day keys
    /// format in `.current`, so fixtures must live in the same zone.
    let tz = TimeZone.current

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

    // MARK: - Sections: fixed order, empty-hide (part 1)

    func testSectionsFixedOrderAndEmptySectionsHidden() async throws {
        let today = makeDate(2026, 6, 16, h: 9)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_t1", text: "match one", createdAt: today),
            Todo(id: "t_t2", text: "match two", createdAt: makeDate(2026, 6, 16, h: 9, min: 10)),
            Todo(id: "t_t3", text: "match three", createdAt: makeDate(2026, 6, 16, h: 9, min: 20)),
        ], at: today)
        let src = FakeInboxSource(id: "github", isConfigured: true)
        src.cannedItems = [
            InboxItem(id: "github:1", sourceID: "github", title: "match inbox",
                      url: "u1", timestamp: today, rawText: "raw"),
            InboxItem(id: "github:2", sourceID: "github", title: "",
                      url: "u2", timestamp: today, rawText: "nothing here"),
        ]
        let service = InboxService(sources: [src], state: try makeInboxState())
        await service.refresh()
        let list = makeList(store: store, now: today, inbox: service)
        let model = makeModel(list: list, now: today)
        model.prepareForOpen()
        // Historical: one matching earlier task + one non-matching day file
        // (its searchText "2026-06-15 Mon Jun 15 2026" has no "match" subsequence).
        let earlierDay = makeDate(2026, 6, 15, h: 9)
        model.merge(historical: [
            .earlierTask(Todo(id: "t_e1", text: "match earlier", createdAt: earlierDay),
                         day: earlierDay),
            .dayFile(day: earlierDay, taskCount: 1),
        ], generation: model.generation)

        model.query = "match"

        XCTAssertEqual(model.sections.map(\.kind),
                       [.actions, .today, .inbox, .earlier],
                       "fixed order Actions→Today→Inbox→Earlier→Days, empty (Days) hidden")
        XCTAssertEqual(model.sections[0].items.map(\.id),
                       ["action:\(Action.openTodayFile.rawValue)"],
                       "non-matching action (zebra zone) dropped")
        XCTAssertEqual(model.sections[1].items.count, 3)
        XCTAssertEqual(model.sections[2].items.map(\.id), ["inbox:github:1"],
                       "non-matching inbox item dropped")
        XCTAssertEqual(model.sections[3].items.count, 1)
    }

    func testEmptyQueryShowsNoSections() throws {
        let today = makeDate(2026, 6, 16, h: 9)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "a task", createdAt: today),
        ], at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        XCTAssertEqual(model.sections.count, 0,
                       "UI-SPEC pin: empty query → bare search row, NO sections")
        XCTAssertNil(model.selectedID)

        model.query = "task"
        XCTAssertFalse(model.sections.isEmpty)
        model.query = ""
        XCTAssertEqual(model.sections.count, 0, "clearing the query clears sections again")
        XCTAssertNil(model.selectedID)
    }

    // MARK: - Ranking: caps + determinism (part 1)

    func testTodaySectionCappedAtEightOrderedByRecencyDesc() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        // 10 identical-text tasks → identical scores → recency desc decides.
        let todos = (1...10).map { i in
            Todo(id: String(format: "t_%02d", i), text: "task item",
                 createdAt: makeDate(2026, 6, 16, h: 9, min: i))
        }
        try store.appendCapture(noteText: "", noteId: nil, tasks: todos, at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        model.query = "task"

        let todaySection = try XCTUnwrap(model.sections.first { $0.kind == .today })
        XCTAssertEqual(todaySection.items.map(\.id),
                       ["today:t_10", "today:t_09", "today:t_08", "today:t_07",
                        "today:t_06", "today:t_05", "today:t_04", "today:t_03"],
                       "capped at 8, most recent createdAt first")
    }

    func testOverallCapFortyRowsAcrossAllFiveSections() async throws {
        // >40 raw matches (50): 10 per kind, query "2026" hits every kind —
        // including Days, whose searchText carries the yyyy-MM-dd file name.
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        let todos = (1...10).map { i in
            Todo(id: String(format: "t_%02d", i), text: "2026 task \(i)",
                 createdAt: makeDate(2026, 6, 16, h: 9, min: i))
        }
        try store.appendCapture(noteText: "", noteId: nil, tasks: todos, at: today)
        let actions = Action.allCases.prefix(10).enumerated().map { i, a in
            CommandAction(action: a, label: "2026 action \(i)", symbol: "gear")
        }
        let src = FakeInboxSource(id: "github", isConfigured: true)
        src.cannedItems = (1...10).map { i in
            InboxItem(id: "github:\(i)", sourceID: "github", title: "2026 inbox \(i)",
                      url: "u", timestamp: today, rawText: "")
        }
        let service = InboxService(sources: [src], state: try makeInboxState())
        await service.refresh()
        let list = makeList(store: store, now: today, inbox: service)
        let model = makeModel(list: list, actions: Array(actions), now: today)
        model.prepareForOpen()
        var historical: [CommandItem] = []
        for i in 1...10 {
            let day = makeDate(2026, 5, i, h: 9)
            historical.append(.earlierTask(
                Todo(id: String(format: "t_e%02d", i), text: "2026 earlier \(i)",
                     createdAt: day), day: day))
            historical.append(.dayFile(day: day, taskCount: 1))
        }
        model.merge(historical: historical, generation: model.generation)

        model.query = "2026"

        XCTAssertEqual(model.visibleRows.count, 40,
                       "exactly 40 overall: 50 raw matches truncated to the cap")
        XCTAssertEqual(model.sections.map(\.kind),
                       [.actions, .today, .inbox, .earlier, .days],
                       "order preserved under truncation")
        for section in model.sections {
            XCTAssertLessThanOrEqual(section.items.count, 8, "per-section cap")
        }
    }

    func testRankingDeterministicTiebreaks() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        let nine = makeDate(2026, 6, 16, h: 9)
        // Identical text → identical score: recency desc first, then id asc.
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "same text", createdAt: nine),
            Todo(id: "t_ab", text: "same text", createdAt: nine),
            Todo(id: "t_new", text: "same text", createdAt: makeDate(2026, 6, 16, h: 10)),
            Todo(id: "t_aa", text: "same text", createdAt: nine),
        ], at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        model.query = "same"
        let first = model.visibleRows.map(\.id)
        XCTAssertEqual(first, ["today:t_new", "today:t_aa", "today:t_ab", "today:t_old"],
                       "score tie → recency desc; recency tie → id asc")

        // Re-running the identical query yields an identical snapshot.
        model.query = "sam"
        model.query = "same"
        XCTAssertEqual(model.visibleRows.map(\.id), first, "deterministic across re-scores")
    }

    // MARK: - Selection semantics (part 1)

    func testSelectionDefaultsToFirstRowAndMoveClamps() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_one", text: "match one", createdAt: makeDate(2026, 6, 16, h: 10)),
            Todo(id: "t_two", text: "match two", createdAt: makeDate(2026, 6, 16, h: 9)),
        ], at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        model.query = "match"
        // Rows: [action "match action", today t_one, today t_two]
        XCTAssertEqual(model.selectedID, model.visibleRows.first?.id,
                       "defaults to FIRST visible row on query change")

        model.moveSelection(-1)
        XCTAssertEqual(model.selectedID, model.visibleRows[0].id, "clamps at top (no wrap)")
        model.moveSelection(1)
        XCTAssertEqual(model.selectedID, model.visibleRows[1].id)
        model.moveSelection(100)
        XCTAssertEqual(model.selectedID, model.visibleRows.last?.id, "clamps at bottom")
        model.moveSelection(-100)
        XCTAssertEqual(model.selectedID, model.visibleRows[0].id)
    }

    func testSelectionIdentitySurvivesRescoreAndResetsWhenGone() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        let nine = makeDate(2026, 6, 16, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "task apple", createdAt: nine),
            Todo(id: "t_b", text: "task banana", createdAt: nine),
            Todo(id: "t_c", text: "task cherry", createdAt: nine),
        ], at: today)
        // Neither fake action matches "task"/"banana"/"apple" ("match action"
        // has no s/b/p subsequence; "zebra zone" has no t) — rows stay today-only.
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        model.query = "task"
        // Today order (equal score+recency): id asc → t_a, t_b, t_c.
        model.moveSelection(1) // → today:t_b
        XCTAssertEqual(model.selectedID, "today:t_b")

        model.query = "banana"
        XCTAssertEqual(model.visibleRows.map(\.id), ["today:t_b"])
        XCTAssertEqual(model.selectedID, "today:t_b",
                       "id still visible after re-score → selection kept")

        model.query = "apple"
        XCTAssertEqual(model.selectedID, "today:t_a",
                       "selected id disappeared → reset to first visible row")
    }

    func testActivateVisibleRowTargetsFlatIndexAcrossSections() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_one", text: "match one", createdAt: makeDate(2026, 6, 16, h: 10)),
            Todo(id: "t_two", text: "match two", createdAt: makeDate(2026, 6, 16, h: 9)),
        ], at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()

        model.query = "match"
        // Flat rows: [1: action "match action", 2: today t_one, 3: today t_two]
        model.activate(visibleRow: 2)
        XCTAssertEqual(model.selectedID, "today:t_one",
                       "⌘2 targets the 2nd FLAT row across the section boundary")

        model.activate(visibleRow: 99)
        XCTAssertEqual(model.selectedID, "today:t_one", "out-of-range row is a no-op")
        model.activate(visibleRow: 0)
        XCTAssertEqual(model.selectedID, "today:t_one", "rows are 1-based; 0 is a no-op")
    }

    // MARK: - Fixture helpers

    /// A fixed two-entry fake action list — NOT CommandActionRegistry.all — so
    /// every score in this suite is hand-computable and registry edits never
    /// ripple here.
    private let fakeActions = [
        CommandAction(action: .openTodayFile, label: "match action", symbol: "doc.text"),
        CommandAction(action: .replayOnboarding, label: "zebra zone", symbol: "sparkles"),
    ]

    private func makeList(store: Store, now: Date,
                          inbox: InboxService? = nil) -> MenubarListModel {
        MenubarListModel(store: store, timezone: tz, defaults: defaults,
                         now: { now }, inboxService: inbox)
    }

    private func makeModel(list: MenubarListModel,
                           actions: [CommandAction]? = nil,
                           dispatcher: ActionDispatcher = ActionDispatcher(),
                           openURL: @escaping (URL) -> Void = { _ in },
                           now: Date) -> CommandBarModel {
        CommandBarModel(list: list, dispatcher: dispatcher,
                        actions: actions ?? fakeActions,
                        openURL: openURL, now: { now })
    }

    private func makeInboxState() throws -> InboxStateStore {
        let path = folder.appendingPathComponent("inbox-state-\(UUID().uuidString).json")
        return try InboxStateStore(path: path)
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
