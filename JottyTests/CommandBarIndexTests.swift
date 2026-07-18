import XCTest
@testable import Jotty

/// CMDB-02 corpus layer: CommandItem id/searchText/recency pins + the two index
/// builders. `buildHistorical` is exercised against REAL day files written through
/// Store/MarkdownDoc serialize (never hand-built markdown — the serializer owns
/// token formatting), per the MenubarListModelTests temp-folder fixture idiom.
final class CommandBarIndexTests: XCTestCase {
    var folder: URL!

    /// Deliberately the PROCESS timezone, not a pinned fixture zone: CommandItem's
    /// day-key derivation (`id`/`searchText` yyyy-MM-dd strings) formats in
    /// `TimeZone.current` — matching the production Store construction, which is
    /// always `.current` (AppDelegate.swift:76/292) — so the fixtures must be
    /// written in the SAME zone for the suite to be self-consistent on ANY
    /// machine. Every step (file naming, enumeration parse, id formatting) flows
    /// one timezone, so no assertion here depends on WHICH zone the machine is in.
    /// Locale-independence is separately guaranteed: all machine-key formatting is
    /// en_US_POSIX/Gregorian-pinned (DailyFile.dayFormatter + the label formatter).
    let tz = TimeZone.current

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - buildHistorical: enumeration, order, counts

    func testHistoricalYieldsEarlierTasksAndDayFilesNewestDayFirst() throws {
        let store = Store(folder: folder, timezone: tz)
        let older = makeDate(2026, 6, 14, h: 9)
        let newer = makeDate(2026, 6, 15, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_o1", text: "older one", createdAt: older),
            Todo(id: "t_o2", text: "older two", createdAt: older),
            Todo(id: "t_o3", text: "older three", createdAt: older),
        ], at: older)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_n1", text: "newer one", createdAt: newer),
            Todo(id: "t_n2", text: "newer two", createdAt: newer),
        ], at: newer)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16, h: 8))

        // Newest day first: both the earlier-task stream and the day-file stream.
        let earlier = earlierItems(items)
        XCTAssertEqual(earlier.map(\.todoID), ["t_n1", "t_n2", "t_o1", "t_o2", "t_o3"])
        XCTAssertEqual(earlier.map { dayKey($0.day) },
                       ["2026-06-15", "2026-06-15", "2026-06-14", "2026-06-14", "2026-06-14"],
                       "each earlierTask carries its ORIGIN day")

        let days = dayFileItems(items)
        XCTAssertEqual(days.map { dayKey($0.day) }, ["2026-06-15", "2026-06-14"])
        XCTAssertEqual(days.map(\.taskCount), [2, 3])
    }

    // MARK: - Pitfall 5: rolled_to dedupe

    func testRolledTaskIsSkippedAndNotCounted() throws {
        // A rolled-forward task exists twice on disk: the origin line keeps
        // rolled_to:, the live copy sits in today's file. Indexing the origin line
        // would show every leftover twice (RESEARCH Pitfall 5). Fixture written
        // through MarkdownDoc serialize (appendCapture), so the rolled_to: token is
        // the serializer's own formatting.
        let store = Store(folder: folder, timezone: tz)
        let day = makeDate(2026, 6, 14, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_rolled", text: "rolled away", createdAt: day,
                 rolledTo: makeDate(2026, 6, 15)),
            Todo(id: "t_stays", text: "still here", createdAt: day),
        ], at: day)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16))

        XCTAssertEqual(earlierItems(items).map(\.todoID), ["t_stays"],
                       "rolledTo != nil lines must never index")
        XCTAssertEqual(dayFileItems(items).map(\.taskCount), [1],
                       "taskCount counts SURVIVORS only, not rolled lines")
    }

    func testRecurrenceTemplateIsIncluded() throws {
        // recur: templates are real user lines that persist on their origin day
        // forever — they ARE indexed (RESEARCH Open Q2 resolution); only rolled_to:
        // duplicates are skipped.
        let store = Store(folder: folder, timezone: tz)
        let day = makeDate(2026, 6, 14, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_tmpl", text: "standup", createdAt: day, recur: .daily),
        ], at: day)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16))

        XCTAssertEqual(earlierItems(items).map(\.todoID), ["t_tmpl"])
        XCTAssertEqual(dayFileItems(items).map(\.taskCount), [1])
    }

    // MARK: - Today exclusion (CR-03: today comes from the live partitions)

    func testExcludedDayAbsentFromBothStreams() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 15, h: 9)
        let today = makeDate(2026, 6, 16, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_hist", text: "historical", createdAt: yesterday),
        ], at: yesterday)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_live", text: "live today", createdAt: today),
        ], at: today)

        // excludingDay is an instant WITHIN the day (08:00), not midnight — the
        // exclusion matches on the dayFormatter STRING, not on Date equality.
        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16, h: 8))

        XCTAssertEqual(earlierItems(items).map(\.todoID), ["t_hist"],
                       "today's tasks come from the live menubar partitions, never the index")
        XCTAssertEqual(dayFileItems(items).map { dayKey($0.day) }, ["2026-06-15"],
                       "today's file is not a day-file result either")
    }

    func testFutureDatedDayFileIsExcluded() throws {
        // Review IN-03: era-shifted legacy filenames (e.g. `2569-07-03.md`) parse
        // as far-future days; without the `< today` filter they indexed as
        // top-ranked "Earlier" results with future recency.
        let store = Store(folder: folder, timezone: tz)
        let past = makeDate(2026, 6, 15, h: 9)
        let future = makeDate(2569, 7, 3, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_past", text: "real history", createdAt: past),
        ], at: past)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_future", text: "era-shifted ghost", createdAt: future),
        ], at: future)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16, h: 8))

        XCTAssertEqual(earlierItems(items).map(\.todoID), ["t_past"],
                       "only days strictly BEFORE today index")
        XCTAssertEqual(dayFileItems(items).map { dayKey($0.day) }, ["2026-06-15"])
    }

    // MARK: - Pinned id / searchText / recency derivations

    func testPinnedIDsSearchTextAndRecency() throws {
        let store = Store(folder: folder, timezone: tz)
        let day = makeDate(2026, 6, 15, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_a", text: "write report", createdAt: day),
        ], at: day)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16))

        let earlier = try XCTUnwrap(items.first { if case .earlierTask = $0 { return true }; return false })
        XCTAssertEqual(earlier.id, "earlier:t_a:2026-06-15")
        XCTAssertEqual(earlier.searchText, "write report")
        XCTAssertEqual(earlier.recency.map(dayKey), "2026-06-15",
                       "earlierTask recency == its ORIGIN day, not createdAt")

        let dayItem = try XCTUnwrap(items.first { if case .dayFile = $0 { return true }; return false })
        XCTAssertEqual(dayItem.id, "day:2026-06-15")
        // The searchText carries BOTH the raw file name (so "2026-06" hits) AND an
        // en_US_POSIX-formatted label (so "jun" hits) — the literal below pins the
        // POSIX locale: an unpinned formatter on a de_DE machine would render
        // "Mo." / "Juni" and fail here. 2026-06-15 is a Monday.
        XCTAssertTrue(dayItem.searchText.contains("2026-06-15"), dayItem.searchText)
        XCTAssertTrue(dayItem.searchText.contains("Mon Jun 15 2026"), dayItem.searchText)
        XCTAssertEqual(dayItem.recency.map(dayKey), "2026-06-15")

        // The in-memory kinds (no disk involved): pin their id/searchText/recency too.
        let createdAt = makeDate(2026, 6, 16, h: 10)
        let todayItem = CommandItem.todayTask(
            Todo(id: "t_today", text: "today task", createdAt: createdAt))
        XCTAssertEqual(todayItem.id, "today:t_today")
        XCTAssertEqual(todayItem.searchText, "today task")
        XCTAssertEqual(todayItem.recency, createdAt, "todayTask recency == createdAt")

        let action = CommandAction(action: .openTodayFile,
                                   label: "Open Today's File", symbol: "doc.text")
        let actionItem = CommandItem.action(action)
        XCTAssertEqual(actionItem.id, "action:\(Action.openTodayFile.rawValue)")
        XCTAssertEqual(actionItem.searchText, "Open Today's File")
        XCTAssertNil(actionItem.recency)

        let inbox = InboxItem(id: "github:42", sourceID: "github", title: "fix the bug",
                              url: "https://example.com", timestamp: createdAt,
                              rawText: "raw fallback")
        let inboxItem = CommandItem.inbox(inbox)
        XCTAssertEqual(inboxItem.id, "inbox:github:42")
        XCTAssertEqual(inboxItem.searchText, "fix the bug")
        XCTAssertNil(inboxItem.recency)
    }

    // MARK: - I4: day strings follow the STORE timezone, not the launch zone

    /// I4 (final review): the `.dayFile`/`.earlierTask` day key + label are formatted in
    /// `buildHistorical`'s PASSED timezone, so they round-trip the on-disk file name in the
    /// current zone. Building the SAME folder under an EAST (+14) and a WEST (−12) zone must
    /// yield the IDENTICAL day key (each round-trips its own file name). d8a9166 formatted
    /// with a process-static LAUNCH-zone formatter, so the two builds' 26h-apart midnight
    /// instants rendered as DIFFERENT days — the "east of launch shifts one day back" bug
    /// that made date searches hit the adjacent day and Enter open a file one day off.
    func testDayStringsFollowStoreTimezoneNotLaunchZone() throws {
        let east = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14
        let west = TimeZone(identifier: "Etc/GMT+12")!           // UTC−12
        let store = Store(folder: folder, timezone: east)
        let day = dateIn(2026, 6, 15, h: 9, tz: east)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_a", text: "ledger", createdAt: day)], at: day)

        let itemsEast = CommandBarIndex.buildHistorical(
            folder: folder, timezone: east, excludingDay: dateIn(2026, 6, 16, h: 8, tz: east))
        let itemsWest = CommandBarIndex.buildHistorical(
            folder: folder, timezone: west, excludingDay: dateIn(2026, 6, 16, h: 8, tz: west))

        // Both builds round-trip the file name in their own zone → identical id + key.
        XCTAssertEqual(dayFileItems2(itemsEast).map(\.id), ["day:2026-06-15"],
                       "east build formats the day key in the PASSED zone (I4)")
        XCTAssertEqual(dayFileItems2(itemsWest).map(\.id), ["day:2026-06-15"],
                       "west build round-trips the same file name — no launch-zone shift")

        // Label + searchText are the passed zone's forms; a date search hits the right day.
        let eastDayItem = try XCTUnwrap(itemsEast.first { if case .dayFile = $0 { return true }; return false })
        XCTAssertEqual(eastDayItem.searchText,
                       "2026-06-15 \(CommandItem.dayLabelFormatter(timezone: east).string(from: day))")
        XCTAssertTrue(eastDayItem.searchText.contains("2026-06-15"),
                      "the raw date search key must match the store-zone day")
        let earlierEast = try XCTUnwrap(itemsEast.first { if case .earlierTask = $0 { return true }; return false })
        XCTAssertEqual(earlierEast.id, "earlier:t_a:2026-06-15",
                       "the earlier-task id day component follows the store zone too")
    }

    private func dateIn(_ y: Int, _ m: Int, _ d: Int, h: Int, tz: TimeZone) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func dayFileItems2(_ items: [CommandItem]) -> [CommandItem] {
        items.filter { if case .dayFile = $0 { return true }; return false }
    }

    // MARK: - Fail-soft (Pattern 3)

    func testMissingFolderYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let items = CommandBarIndex.buildHistorical(
            folder: missing, timezone: tz, excludingDay: makeDate(2026, 6, 16))
        XCTAssertEqual(items.count, 0)
    }

    func testUnparseableDayFileIsFailSoftAndRemainingDaysStillIndex() throws {
        let store = Store(folder: folder, timezone: tz)
        let good = makeDate(2026, 6, 15, h: 9)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_good", text: "survives", createdAt: good),
        ], at: good)
        // A hand-corrupted file (no frontmatter date → MarkdownDoc.parse throws).
        // Store.readDoc degrades it to an EMPTY doc (readOrCreate swallows the
        // parse failure), so the corrupt day contributes no earlierTask items and
        // surfaces only as a taskCount-0 day file — still openable from the
        // palette, so the user can find and fix it. Never fatal; the good day is
        // fully indexed regardless. (buildHistorical's catch branch additionally
        // guards any future throwing read path.)
        try "not a jotty day file".write(
            to: folder.appendingPathComponent("2026-06-14.md"),
            atomically: true, encoding: .utf8)

        let items = CommandBarIndex.buildHistorical(
            folder: folder, timezone: tz, excludingDay: makeDate(2026, 6, 16))

        XCTAssertEqual(earlierItems(items).map(\.todoID), ["t_good"],
                       "the corrupt day must contribute no task items")
        let days = dayFileItems(items)
        XCTAssertEqual(days.map { dayKey($0.day) }, ["2026-06-15", "2026-06-14"])
        XCTAssertEqual(days.map(\.taskCount), [1, 0])
    }

    // MARK: - buildImmediate: pure, order-preserving mapping

    func testBuildImmediatePreservesOrderAndMapsSearchTextPerKind() {
        let actions = [
            CommandAction(action: .openTodayFile, label: "Open Today's File", symbol: "doc.text"),
            CommandAction(action: .replayOnboarding, label: "Replay Onboarding", symbol: "sparkles"),
        ]
        let t1 = Todo(id: "t_left", text: "leftover", createdAt: makeDate(2026, 6, 15))
        let t2 = Todo(id: "t_new", text: "fresh", createdAt: makeDate(2026, 6, 16))
        let i1 = InboxItem(id: "github:1", sourceID: "github", title: "titled item",
                           url: "u1", timestamp: makeDate(2026, 6, 16), rawText: "raw one")
        let i2 = InboxItem(id: "github:2", sourceID: "github", title: "",
                           url: "u2", timestamp: makeDate(2026, 6, 16), rawText: "raw two")

        let items = CommandBarIndex.buildImmediate(actions: actions,
                                                   today: [t1, t2], inbox: [i1, i2])

        XCTAssertEqual(items.map(\.id), [
            "action:\(Action.openTodayFile.rawValue)",
            "action:\(Action.replayOnboarding.rawValue)",
            "today:t_left", "today:t_new",
            "inbox:github:1", "inbox:github:2",
        ], "registry order, then leftovers+today order, then suggestions order — verbatim")
        XCTAssertEqual(items.map(\.searchText), [
            "Open Today's File", "Replay Onboarding",
            "leftover", "fresh",
            "titled item", "raw two",
        ], "inbox falls back to rawText when title is empty (SuggestedSection idiom)")
    }

    // MARK: - Scale (correctness-only; A1 risk absorbed by 09-04's off-main build)

    func testScale200DaysCorrectnessOnly() throws {
        let store = Store(folder: folder, timezone: tz)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = makeDate(2026, 1, 1, h: 9)
        for i in 0..<200 {
            let day = cal.date(byAdding: .day, value: i, to: start)!
            try store.appendCapture(noteText: "", noteId: nil, tasks: [
                Todo(id: "t_d\(i)_1", text: "task one day \(i)", createdAt: day),
                Todo(id: "t_d\(i)_2", text: "task two day \(i)", createdAt: day),
                Todo(id: "t_d\(i)_3", text: "task three day \(i)", createdAt: day),
            ], at: day)
        }

        let clock = ContinuousClock()
        var items: [CommandItem] = []
        let elapsed = clock.measure {
            items = CommandBarIndex.buildHistorical(
                folder: folder, timezone: tz, excludingDay: makeDate(2026, 12, 31))
        }
        // Logged for the record, NEVER asserted — CI variance makes a time bound
        // flaky; the off-main detached build in 09-04 absorbs the A1 risk.
        NSLog("[Jotty] CommandBarIndex scale: 200 days indexed in \(elapsed)")

        XCTAssertEqual(earlierItems(items).count, 600)
        XCTAssertEqual(dayFileItems(items).count, 200)
    }

    // MARK: - Helpers

    private func dayKey(_ date: Date) -> String {
        DailyFile.dayFormatter(timezone: tz).string(from: date)
    }

    private func earlierItems(_ items: [CommandItem]) -> [(todoID: String, day: Date)] {
        items.compactMap {
            if case let .earlierTask(todo, day, _) = $0 { return (todo.id, day) }
            return nil
        }
    }

    private func dayFileItems(_ items: [CommandItem]) -> [(day: Date, taskCount: Int)] {
        items.compactMap {
            if case let .dayFile(day, count, _, _) = $0 { return (day, count) }
            return nil
        }
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
