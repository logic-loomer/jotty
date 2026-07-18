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
            earlier(Todo(id: "t_e1", text: "match earlier", createdAt: earlierDay),
                    day: earlierDay),
            dayFile(day: earlierDay, taskCount: 1),
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
            historical.append(earlier(
                Todo(id: String(format: "t_e%02d", i), text: "2026 earlier \(i)",
                     createdAt: day), day: day))
            historical.append(dayFile(day: day, taskCount: 1))
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

    // MARK: - Enter routing (part 2) — every effect AFTER onRequestClose

    func testEnterOnActionDispatchesAfterClose() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        var events: [String] = []
        let dispatcher = ActionDispatcher()
        dispatcher.register(.replayOnboarding) { events.append("action") }
        let model = makeModel(list: makeList(store: store, now: today),
                              dispatcher: dispatcher, now: today)
        model.onRequestClose = { events.append("close") }
        model.prepareForOpen()

        model.query = "zebra"   // matches ONLY the "zebra zone" fake action
        XCTAssertEqual(model.visibleRows.map(\.id),
                       ["action:\(Action.replayOnboarding.rawValue)"])
        model.activateSelection()

        XCTAssertEqual(events, ["close", "action"],
                       "dispatcher.dispatch runs AFTER onRequestClose (Pitfall 8)")
    }

    func testEnterOnTodayTaskOpensMenubarAfterClose() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_x", text: "buy groceries", createdAt: today),
        ], at: today)
        var events: [String] = []
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.onRequestClose = { events.append("close") }
        model.onOpenMenubar = { events.append("menubar:\($0)") }
        model.prepareForOpen()

        model.query = "groceries"
        model.activateSelection()

        XCTAssertEqual(events, ["close", "menubar:t_x"],
                       "today task routes the TODO id to onOpenMenubar, after close")
    }

    func testActivateSelectionWithNoRowsIsNoOp() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        var events: [String] = []
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.onRequestClose = { events.append("close") }
        model.onOpenMenubar = { events.append("menubar:\($0)") }
        model.prepareForOpen()

        model.activateSelection()   // empty query → no rows

        XCTAssertEqual(events, [], "no rows → no close, no effect")
    }

    func testEnterOnInboxAcceptsIntoTodaysFileAfterClose() async throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_pre", text: "existing task", createdAt: today),
        ], at: today)
        let src = FakeInboxSource(id: "github", isConfigured: true)
        src.cannedItems = [
            InboxItem(id: "github:9", sourceID: "github", title: "fix the login bug",
                      url: "https://example.test/9", timestamp: today, rawText: ""),
        ]
        let service = InboxService(sources: [src], state: try makeInboxState())
        await service.refresh()
        let list = makeList(store: store, now: today, inbox: service)
        let model = makeModel(list: list, now: today)
        var tasksAtClose = -1
        model.onRequestClose = {
            tasksAtClose = (try? store.readDoc(on: today).tasks.count) ?? -1
        }
        model.prepareForOpen()

        model.query = "login"
        XCTAssertEqual(model.visibleRows.map(\.id), ["inbox:github:9"])
        model.activateSelection()

        XCTAssertEqual(tasksAtClose, 1,
                       "close fires BEFORE the accept write (Pitfall 8 ordering)")
        let written = try store.readDoc(on: today).tasks
        XCTAssertEqual(written.count, 2, "acceptSuggestion's WR-01 path wrote today's file")
        let accepted = try XCTUnwrap(written.first { $0.source == "github:9" })
        XCTAssertEqual(accepted.text, "fix the login bug")
        XCTAssertEqual(accepted.sourceURL, "https://example.test/9")
    }

    func testEarlierAndDayFileOpenURLInCurrentStoreFolder() throws {
        // Pitfall 9 regression guard: after replaceStore(newFolder), activation
        // must route into the NEW folder — list.store resolved at ACTIVATION time.
        let today = makeDate(2026, 6, 16, h: 12)
        let storeA = Store(folder: folder, timezone: tz)
        var opened: [URL] = []
        var closes = 0
        let model = makeModel(list: makeList(store: storeA, now: today),
                              openURL: { opened.append($0) }, now: today)
        model.onRequestClose = { closes += 1 }
        model.prepareForOpen()
        let earlierDay = makeDate(2026, 3, 5, h: 9)
        let fileDay = makeDate(2026, 3, 4, h: 9)
        model.merge(historical: [
            earlier(Todo(id: "t_v", text: "vintage ledger", createdAt: earlierDay),
                    day: earlierDay),
            dayFile(day: fileDay, taskCount: 3),
        ], generation: model.generation)

        // Live store swap AFTER the corpus was built.
        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }
        let storeB = Store(folder: folderB, timezone: tz)
        model.list.replaceStore(storeB)

        model.query = "vintage"
        model.activateSelection()
        XCTAssertEqual(opened, [DailyFile.url(in: folderB, on: earlierDay, timezone: tz)],
                       "earlierTask opens its ORIGIN day in the CURRENT (swapped) folder")

        model.query = "2026-03-04"
        XCTAssertEqual(model.visibleRows.map(\.id), ["day:2026-03-04"])
        model.activateSelection()
        XCTAssertEqual(opened.last, DailyFile.url(in: folderB, on: fileDay, timezone: tz),
                       "dayFile opens in the CURRENT folder too")
        XCTAssertEqual(closes, 2, "each activation closed the panel first")
    }

    // MARK: - prepareForOpen lifecycle (part 2)

    func testPrepareForOpenResetsStateAndBuildsImmediateSynchronously() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "match me", createdAt: today),
        ], at: today)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()
        model.query = "match"
        model.moveSelection(1)
        let firstToken = model.openToken

        model.prepareForOpen()

        XCTAssertEqual(model.query, "", "query resets on every open")
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.sections.count, 0)
        XCTAssertNotEqual(model.openToken, firstToken,
                          "a NEW openToken re-focuses the field per show")

        // Immediate sections (actions/today/inbox) are available SYNCHRONOUSLY.
        model.query = "match"
        XCTAssertEqual(model.sections.map(\.kind), [.actions, .today])
        XCTAssertTrue(model.visibleRows.map(\.id).contains("today:t_a"))
    }

    func testMergeDropsStaleGenerationAndAppliesCurrentOne() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        let model = makeModel(list: makeList(store: store, now: today), now: today)
        model.prepareForOpen()
        let staleGeneration = model.generation
        model.prepareForOpen()   // close/reopen: bumps the generation

        model.query = "vintage"
        let day = makeDate(2026, 3, 5, h: 9)
        let items: [CommandItem] = [
            earlier(Todo(id: "t_v", text: "vintage ledger", createdAt: day), day: day),
        ]

        model.merge(historical: items, generation: staleGeneration)
        XCTAssertEqual(model.sections.count, 0,
                       "a build from a PREVIOUS open is dropped silently")

        model.merge(historical: items, generation: model.generation)
        XCTAssertEqual(model.sections.map(\.kind), [.earlier],
                       "the current open's build merges into the live query")
        XCTAssertEqual(model.visibleRows.map(\.id), ["earlier:t_v:2026-03-05"])
    }

    func testPrepareForOpenNeverTriggersInboxRefresh() throws {
        let today = makeDate(2026, 6, 16, h: 12)
        let store = Store(folder: folder, timezone: tz)
        let src = FakeInboxSource(id: "github", isConfigured: true)
        src.cannedItems = [
            InboxItem(id: "github:1", sourceID: "github", title: "never fetched",
                      url: "u", timestamp: today, rawText: ""),
        ]
        let service = InboxService(sources: [src], state: try makeInboxState())
        let list = makeList(store: store, now: today, inbox: service)
        let model = makeModel(list: list, now: today)

        model.prepareForOpen()

        XCTAssertEqual(src.fetchCallCount, 0,
                       "⌘K reads suggestions from memory — the zero-network lock")
    }

    // MARK: - prepareForOpen corpus freshness (review WR-05)

    func testExternallyAppendedTodayTaskAppearsOnNextOpen() throws {
        let today = makeDate(2026, 6, 16, h: 9)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "match original", createdAt: today),
        ], at: today)
        let list = makeList(store: store, now: today)
        let model = makeModel(list: list, now: today)
        model.prepareForOpen()
        model.query = "match"
        XCTAssertTrue(model.visibleRows.map(\.id).contains("today:t_a"))

        // External edit: today's FILE gains a task (Obsidian etc.) — the list
        // model's in-memory partitions know nothing until something reloads.
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_b", text: "match external",
                 createdAt: makeDate(2026, 6, 16, h: 10)),
        ], at: today)

        model.prepareForOpen()   // next ⌘K open
        model.query = "match"
        XCTAssertTrue(model.visibleRows.map(\.id).contains("today:t_b"),
                      "WR-05: prepareForOpen must refresh today's partitions from disk")
    }

    func testDayRolloverBetweenOpensRepartitions() throws {
        let day1 = makeDate(2026, 6, 16, h: 9)
        let day2 = makeDate(2026, 6, 17, h: 0, min: 30)   // just past midnight
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "match task", createdAt: day1),
        ], at: day1)

        var current = day1
        let list = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                    now: { current })
        let model = CommandBarModel(list: list, dispatcher: ActionDispatcher(),
                                    actions: fakeActions, openURL: { _ in },
                                    now: { current })
        model.prepareForOpen()
        model.query = "match"
        XCTAssertTrue(model.visibleRows.map(\.id).contains("today:t_a"),
                      "on day 1 the task is a live Today row")

        current = day2   // midnight crossed while the retained bar sat closed
        model.prepareForOpen()
        model.query = "match"
        XCTAssertFalse(model.visibleRows.map(\.id).contains("today:t_a"),
                       "WR-05: 'today' derives at OPEN time — day 1's task is no longer a Today row")
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

    /// The precomputed `yyyy-MM-dd` day key for the suite timezone (I4 payloads).
    private func dk(_ day: Date) -> String { DailyFile.dayFormatter(timezone: tz).string(from: day) }
    /// The precomputed human day label for the suite timezone (I4 payloads).
    private func dl(_ day: Date) -> String {
        CommandItem.dayLabelFormatter(timezone: tz).string(from: day)
    }
    /// `.earlierTask` with its day strings precomputed in the suite timezone.
    private func earlier(_ todo: Todo, day: Date) -> CommandItem {
        .earlierTask(todo, day: day, dayKey: dk(day))
    }
    /// `.dayFile` with its day strings precomputed in the suite timezone.
    private func dayFile(day: Date, taskCount: Int) -> CommandItem {
        .dayFile(day: day, taskCount: taskCount, dayKey: dk(day), dayLabel: dl(day))
    }
}
