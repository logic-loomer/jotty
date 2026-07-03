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

    // MARK: - Recurrence instancing (Phase 8 SC2 / CALX-02)

    /// A .daily template due on the new day produces exactly one FRESH instance
    /// on today: new id, recur preserved, recurSrc marker, done=false,
    /// createdAt=startOfDay(today), unscheduled + unlinked (no time/cal_event).
    func testDailyTemplateInstancesFreshOnNewDay() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)   // Thursday
        let today = makeDate(2026, 5, 8)          // Friday
        let block = TimeBlock(start: makeDate(2026, 5, 7, h: 9),
                              end: makeDate(2026, 5, 7, h: 9, m: 30))
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin,
                                             timeBlock: block, calEventID: "evt_1",
                                             recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: today)

        let todayDoc = try store.readDoc(on: today)
        let instances = todayDoc.tasks.filter { $0.recurSrc != nil }
        XCTAssertEqual(instances.count, 1)
        let inst = try XCTUnwrap(instances.first)
        XCTAssertNotEqual(inst.id, "t_tpl")
        XCTAssertEqual(inst.recur, .daily)
        XCTAssertEqual(inst.recurSrc, "t_tpl:2026-05-08")
        XCTAssertFalse(inst.done)
        XCTAssertNil(inst.completedAt)
        XCTAssertEqual(inst.createdAt, startOfDay(today))
        XCTAssertNil(inst.rolledTo)
        XCTAssertNil(inst.timeBlock)
        XCTAssertNil(inst.calEventID)
        XCTAssertEqual(inst.text, "water plants")
    }

    /// Launch + midnight both call run(now:) for the same today. The
    /// first-run-of-day gate (CR-02) skips instancing on the same-day re-run,
    /// with the recur_src marker as second belt — a double run must yield
    /// exactly ONE instance.
    func testSameDayDoubleRunIsIdempotent() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)   // Thursday
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 8, h: 9))       // launch run
        try svc.run(now: makeDate(2026, 5, 8, h: 23, m: 59)) // same-day re-run

        let todayDoc = try store.readDoc(on: makeDate(2026, 5, 8))
        let instances = todayDoc.tasks.filter { $0.recurSrc == "t_tpl:2026-05-08" }
        XCTAssertEqual(instances.count, 1)
    }

    /// CR-02 regression: deleting today's instance must STICK. The delete
    /// removes the recur_src marker with the line, and run() re-fires on every
    /// app activation — without the first-run-of-day gate the instance was
    /// re-created (undeletable).
    func testDeletedInstanceStaysDeletedOnSameDayRerun() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        let today = makeDate(2026, 5, 8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 8, h: 0, m: 1))   // first run of the day

        let instance = try XCTUnwrap(
            try store.readDoc(on: today).tasks.first { $0.recurSrc == "t_tpl:2026-05-08" })
        try store.deleteTodo(id: instance.id, on: today)     // user deletes the instance

        try svc.run(now: makeDate(2026, 5, 8, h: 9))         // activation catch-up re-run
        XCTAssertTrue(try store.readDoc(on: today).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-05-08" }.isEmpty,
                      "a deleted instance must not resurrect on a same-day re-run")

        // The NEXT day still instances normally (gate re-opens on the day boundary).
        try svc.run(now: makeDate(2026, 5, 9, h: 9))
        XCTAssertEqual(try store.readDoc(on: makeDate(2026, 5, 9)).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-05-09" }.count, 1)
    }

    /// CR-02 regression: moving today's instance to tomorrow takes the marker
    /// with it — a same-day re-run must not instance a duplicate onto today.
    func testMovedInstanceDoesNotDuplicateOnSameDayRerun() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        let today = makeDate(2026, 5, 8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 8, h: 0, m: 1))

        let instance = try XCTUnwrap(
            try store.readDoc(on: today).tasks.first { $0.recurSrc == "t_tpl:2026-05-08" })
        try store.moveTodoToTomorrow(id: instance.id, from: today,
                                     now: makeDate(2026, 5, 8, h: 9))

        try svc.run(now: makeDate(2026, 5, 8, h: 10))        // same-day re-run
        XCTAssertTrue(try store.readDoc(on: today).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-05-08" }.isEmpty,
                      "the moved instance must not re-instance onto today")
        XCTAssertEqual(try store.readDoc(on: makeDate(2026, 5, 9)).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-05-08" }.count, 1,
                       "exactly the one moved copy lives on tomorrow")
    }

    /// .weekday rule: no instance on Saturday, one on Monday.
    func testWeekdayTemplateSkipsSaturdayInstancesMonday() throws {
        let store = Store(folder: folder, timezone: tz)
        let friday = makeDate(2026, 5, 8, h: 9)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_wd", text: "standup",
                                             createdAt: friday, recur: .weekday)],
                                at: friday)
        try statePath.write(string: "2026-05-08")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 9))  // Saturday
        let saturdayDoc = try store.readDoc(on: makeDate(2026, 5, 9))
        XCTAssertTrue(saturdayDoc.tasks.filter { $0.recurSrc != nil }.isEmpty)

        try svc.run(now: makeDate(2026, 5, 11)) // Monday
        let mondayDoc = try store.readDoc(on: makeDate(2026, 5, 11))
        let instances = mondayDoc.tasks.filter { $0.recurSrc == "t_wd:2026-05-11" }
        XCTAssertEqual(instances.count, 1)
    }

    /// .weekly rule: instances only on the template's createdAt weekday (Wed).
    func testWeeklyTemplateInstancesOnlyOnTemplateWeekday() throws {
        let store = Store(folder: folder, timezone: tz)
        let wednesday = makeDate(2026, 5, 6, h: 9)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_wk", text: "weekly review",
                                             createdAt: wednesday, recur: .weekly)],
                                at: wednesday)
        try statePath.write(string: "2026-05-06")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 8))  // Friday — not due
        let fridayDoc = try store.readDoc(on: makeDate(2026, 5, 8))
        XCTAssertTrue(fridayDoc.tasks.filter { $0.recurSrc != nil }.isEmpty)

        try svc.run(now: makeDate(2026, 5, 13)) // next Wednesday — due
        let wedDoc = try store.readDoc(on: makeDate(2026, 5, 13))
        let instances = wedDoc.tasks.filter { $0.recurSrc == "t_wk:2026-05-13" }
        XCTAssertEqual(instances.count, 1)
    }

    /// custom:1,5 rule: instances only on Sunday (1) and Thursday (5).
    func testCustomTemplateInstancesOnlyOnListedWeekdays() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)   // Thursday
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_cus", text: "call home",
                                             createdAt: origin,
                                             recur: .custom([1, 5]))],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 5, 8))  // Friday (6) — not due
        let fridayDoc = try store.readDoc(on: makeDate(2026, 5, 8))
        XCTAssertTrue(fridayDoc.tasks.filter { $0.recurSrc != nil }.isEmpty)

        try svc.run(now: makeDate(2026, 5, 10)) // Sunday (1) — due
        let sundayDoc = try store.readDoc(on: makeDate(2026, 5, 10))
        XCTAssertEqual(sundayDoc.tasks.filter { $0.recurSrc == "t_cus:2026-05-10" }.count, 1)

        try svc.run(now: makeDate(2026, 5, 14)) // Thursday (5) — due
        let thursdayDoc = try store.readDoc(on: makeDate(2026, 5, 14))
        XCTAssertEqual(thursdayDoc.tasks.filter { $0.recurSrc == "t_cus:2026-05-14" }.count, 1)
    }

    /// The template is NOT consumed: it stays on its origin day with
    /// rolledTo == nil, and its id never appears on today.
    func testTemplatePersistsOnOriginDayNotConsumed() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        let today = makeDate(2026, 5, 8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: today)

        let originDoc = try store.readDoc(on: origin)
        let template = try XCTUnwrap(originDoc.tasks.first { $0.id == "t_tpl" })
        XCTAssertNil(template.rolledTo)
        XCTAssertEqual(template.recur, .daily)
        XCTAssertNil(template.recurSrc)

        let todayDoc = try store.readDoc(on: today)
        XCTAssertFalse(todayDoc.tasks.contains { $0.id == "t_tpl" })
    }

    /// CR-01 regression: recurrence must NOT die when the template's origin day
    /// falls out of the (collect-loop) lookback window. Templates persist on
    /// their origin day forever, so the template scan is unbounded — 20+
    /// consecutive daily runs later, a .daily template still instances.
    func testDailyTemplateStillInstancesTwentyDaysAfterCreation() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        // Run every consecutive day: 2026-05-08 … 2026-05-27 (day 20 > the
        // 14-day collect window).
        for offset in 1...20 {
            var c = Calendar(identifier: .gregorian); c.timeZone = tz
            let day = c.date(byAdding: .day, value: offset, to: makeDate(2026, 5, 7, h: 9))!
            try svc.run(now: day)
        }

        let day20 = makeDate(2026, 5, 27)
        let day20Doc = try store.readDoc(on: day20)
        XCTAssertEqual(day20Doc.tasks.filter { $0.recurSrc == "t_tpl:2026-05-27" }.count, 1,
                       "the template must still instance on day 20")
        // And the template still sits untouched on its origin day.
        let originDoc = try store.readDoc(on: origin)
        let template = try XCTUnwrap(originDoc.tasks.first { $0.id == "t_tpl" })
        XCTAssertEqual(template.recur, .daily)
        XCTAssertNil(template.rolledTo)
    }

    /// CR-01: the app may simply not run for weeks — a single rollover after a
    /// long gap must still find the (now far-out-of-window) template.
    func testTemplateInstancesAfterMultiWeekGapInRuns() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_tpl", text: "water plants",
                                             createdAt: origin, recur: .daily)],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: makeDate(2026, 6, 8, h: 9))   // 32 days later

        let doc = try store.readDoc(on: makeDate(2026, 6, 8))
        XCTAssertEqual(doc.tasks.filter { $0.recurSrc == "t_tpl:2026-06-08" }.count, 1,
                       "a template older than any bounded window must still instance")
    }

    /// Regression guard: an ordinary incomplete task rolls forward exactly as
    /// before, even when a template shares its day.
    func testNonRecurringRollUnchangedAlongsideTemplate() throws {
        let store = Store(folder: folder, timezone: tz)
        let origin = makeDate(2026, 5, 7, h: 9)
        let today = makeDate(2026, 5, 8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [
                                    Todo(id: "t_norm", text: "leftover", createdAt: origin),
                                    Todo(id: "t_tpl", text: "water plants",
                                         createdAt: origin, recur: .daily)
                                ],
                                at: origin)
        try statePath.write(string: "2026-05-07")

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: today)

        let todayDoc = try store.readDoc(on: today)
        let rolled = try XCTUnwrap(todayDoc.tasks.first { $0.id == "t_norm" })
        XCTAssertFalse(rolled.done)
        XCTAssertNil(rolled.rolledTo)

        let originDoc = try store.readDoc(on: origin)
        XCTAssertEqual(originDoc.tasks.first(where: { $0.id == "t_norm" })?.rolledTo
                       .flatMap(dateOnly), "2026-05-08")
        XCTAssertNil(originDoc.tasks.first(where: { $0.id == "t_tpl" })?.rolledTo)

        XCTAssertEqual(todayDoc.tasks.filter { $0.recurSrc == "t_tpl:2026-05-08" }.count, 1)
    }

    private func startOfDay(_ d: Date) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.startOfDay(for: d)
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
