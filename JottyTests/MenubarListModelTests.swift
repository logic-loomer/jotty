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

    func testReloadRemovesAllStaleCollapseKeys() throws {
        // MI-03: housekeeping must clear EVERY earlier day's key, not just
        // exactly-yesterday's (the app may not run every day).
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        defaults.set(true, forKey: "leftoversCollapsed-2026-06-10")
        defaults.set(false, forKey: "leftoversCollapsed-2026-06-08")
        defaults.set(true, forKey: "leftoversCollapsed-2026-06-12")

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })

        XCTAssertNil(defaults.object(forKey: "leftoversCollapsed-2026-06-10"))
        XCTAssertNil(defaults.object(forKey: "leftoversCollapsed-2026-06-08"))
        XCTAssertTrue(defaults.bool(forKey: "leftoversCollapsed-2026-06-12"))
        XCTAssertTrue(model.leftoversCollapsed)
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
        let now = makeDate(2026, 6, 12, h: 0, min: 1)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_lateNight", text: "just before midnight",
                 createdAt: makeDate(2026, 6, 11, h: 23, min: 59)),
            Todo(id: "t_earlyToday", text: "just after midnight",
                 createdAt: makeDate(2026, 6, 12, h: 0, min: 1))
        ], at: now)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { now })
        XCTAssertEqual(model.leftovers.map(\.id), ["t_lateNight"])
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_earlyToday"])
    }

    func testSydneyDSTTransitionBoundary() throws {
        // 2026-10-04: AEST -> AEDT in Sydney, clocks skip 02:00-03:00
        // (a 23-hour day). Calendar.startOfDay must still partition correctly.
        let store = Store(folder: folder, timezone: tz)
        let now = makeDate(2026, 10, 4, h: 7)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_beforeDST", text: "late on the 3rd",
                 createdAt: makeDate(2026, 10, 3, h: 23, min: 59)),
            Todo(id: "t_afterDST", text: "after the skipped hour",
                 createdAt: makeDate(2026, 10, 4, h: 3, min: 1))
        ], at: now)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { now })
        XCTAssertEqual(model.leftovers.map(\.id), ["t_beforeDST"])
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_afterDST"])
    }

    // MARK: - Calendar section (SC2)

    func testCalendarEventsPopulateWhenAuthorized() async throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)

        let fake = FakeCalendarService()
        fake.accessToReturn = .authorized
        // Service already filters all-day + sorts by start (plan 03); feed two timed events.
        let e1 = CalendarEvent(id: "ev1", title: "Standup",
                               start: makeDate(2026, 6, 12, h: 9),
                               end: makeDate(2026, 6, 12, h: 9, min: 15),
                               calendarTitle: "Work")
        let e2 = CalendarEvent(id: "ev2", title: "Lunch",
                               start: makeDate(2026, 6, 12, h: 12),
                               end: makeDate(2026, 6, 12, h: 13),
                               calendarTitle: "Personal")
        fake.cannedEvents = [e1, e2]

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        XCTAssertEqual(model.calendarEvents, [e1, e2])
        XCTAssertFalse(model.calendarAccessDenied)
        // Fetch range is today's [startOfDay, endOfDay) in the model's timezone.
        XCTAssertTrue(fake.calls.contains(.eventsInRange))
    }

    func testCalendarDeniedEmptiesAndFlagsWithoutCrash() async throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)

        let fake = FakeCalendarService()
        fake.accessToReturn = .denied
        fake.cannedEvents = [
            CalendarEvent(id: "ev1", title: "Should not show",
                          start: makeDate(2026, 6, 12, h: 9),
                          end: makeDate(2026, 6, 12, h: 10), calendarTitle: nil)
        ]

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        XCTAssertEqual(model.calendarEvents, [])
        XCTAssertTrue(model.calendarAccessDenied)
        // Denied path must NOT read events (no eventsInRange call).
        XCTAssertFalse(fake.calls.contains(.eventsInRange))
    }

    func testNoCalendarServiceStaysEmptyAndBackCompat() async throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_new", text: "fresh", createdAt: today)
        ], at: today)

        // Default init (no calendar service injected).
        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        await model.awaitCalendarRefresh()

        XCTAssertEqual(model.calendarEvents, [])
        XCTAssertFalse(model.calendarAccessDenied)
        // Existing task partitioning still works (back-compat).
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_new"])
    }

    // MARK: - SC3: toggle leaves the event

    func testToggleLinkedTaskDoesNotTouchTheEvent() async throws {
        // SC3: a done task is still a real commitment — toggle must NOT update or delete the event.
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_linked", text: "review", createdAt: today,
                 timeBlock: TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                                      end: makeDate(2026, 6, 12, h: 15)),
                 calEventID: "evt-1")
        ], at: today)

        let fake = FakeCalendarService()
        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        let linked = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })
        model.toggle(linked)
        await model.awaitCalendarRefresh()

        XCTAssertFalse(fake.calls.contains(.updateEvent), "toggle must not update the event")
        XCTAssertFalse(fake.calls.contains(.deleteEvent), "toggle must not delete the event")
        // Task is still flipped done in markdown.
        let doc = try store.readDoc(on: today)
        XCTAssertTrue(try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" }).done)
    }

    // MARK: - SC3: delete with remembered preference

    func testDeleteUnlinkedTaskNeverPromptsOrTouchesCalendar() async throws {
        let (store, today) = try seed(tasks: [
            Todo(id: "t_plain", text: "no event", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        let cfg = try config(deletePref: nil)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_plain" })
        model.delete(task)
        await model.awaitCalendarRefresh()

        XCTAssertNil(model.deletePrompt, "unlinked delete never prompts")
        XCTAssertFalse(fake.calls.contains(.deleteEvent))
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_plain" })
    }

    func testDeleteLinkedWithNilPrefPromptsThenYesDeletesAndRemembersTrue() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let cfg = try config(deletePref: nil)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.delete(task)
        // Markdown removal happens immediately; only the calendar event is gated by the prompt.
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_linked" })
        let prompt = try XCTUnwrap(model.deletePrompt, "nil pref must surface a prompt")
        XCTAssertEqual(prompt.task.id, "t_linked")

        model.resolveDeletePrompt(deleteEvent: true)
        await model.awaitDeleteWork()

        XCTAssertNil(model.deletePrompt, "prompt cleared after resolution")
        XCTAssertEqual(fake.deletedEventIDs, ["evt-1"])
        XCTAssertEqual(cfg.config.deleteCalendarEventWithTask, true, "answer is remembered")
    }

    func testDeleteLinkedWithNilPrefPromptThenNoSkipsDeleteAndRemembersFalse() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let cfg = try config(deletePref: nil)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.delete(task)
        _ = try XCTUnwrap(model.deletePrompt)
        model.resolveDeletePrompt(deleteEvent: false)
        await model.awaitDeleteWork()

        XCTAssertNil(model.deletePrompt)
        XCTAssertTrue(fake.deletedEventIDs.isEmpty, "no must not delete the event")
        XCTAssertEqual(cfg.config.deleteCalendarEventWithTask, false)
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_linked" })
    }

    func testDeleteLinkedWithRememberedTrueDeletesSilently() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let cfg = try config(deletePref: true)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.delete(task)
        await model.awaitDeleteWork()

        XCTAssertNil(model.deletePrompt, "remembered choice -> no prompt")
        XCTAssertEqual(fake.deletedEventIDs, ["evt-1"])
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_linked" })
    }

    func testDeleteLinkedWithRememberedFalseSkipsSilently() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let cfg = try config(deletePref: false)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.delete(task)
        await model.awaitDeleteWork()

        XCTAssertNil(model.deletePrompt)
        XCTAssertTrue(fake.deletedEventIDs.isEmpty)
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_linked" })
    }

    func testDeleteEventFailureStillRemovesTaskFromMarkdown() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "boom")
        let cfg = try config(deletePref: true)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake, configStore: cfg)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.delete(task)
        await model.awaitDeleteWork()

        // Best-effort: deleteEvent attempted, threw, but the task is gone from markdown (T-5-09).
        XCTAssertTrue(fake.calls.contains(.deleteEvent))
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_linked" })
    }

    // MARK: - SC3: edit time updates the event (recreate if missing)

    func testEditTimeUpdatesLinkedEventByIdAndPreservesCalEvent() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        // The linked event exists in the open-time fetch, so CR-02's self-heal does not
        // classify it missing and clear the link before the edit runs.
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        let newBlock = TimeBlock(start: makeDate(2026, 6, 12, h: 16),
                                 end: makeDate(2026, 6, 12, h: 17))
        model.editTime(task, to: newBlock)
        await model.awaitCalendarRefresh()

        // Event updated in place by id; not recreated.
        XCTAssertEqual(fake.updatedEventIDs, ["evt-1"])
        XCTAssertTrue(fake.createdEvents.isEmpty)
        // Markdown time: token updated, cal_event unchanged.
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(stored.timeBlock, newBlock)
        XCTAssertEqual(stored.calEventID, "evt-1")
    }

    func testEditTimeRecreatesAndRewritesIdWhenEventMissing() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-gone")])
        let fake = FakeCalendarService()
        // updateEvent throws .eventNotFound; createEvent then succeeds -> "fake-event-1".
        fake.updateErrorToThrow = .eventNotFound
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        let newBlock = TimeBlock(start: makeDate(2026, 6, 12, h: 16),
                                 end: makeDate(2026, 6, 12, h: 17))
        model.editTime(task, to: newBlock)
        await model.awaitCalendarRefresh()

        // Tried update (got .eventNotFound), then recreated.
        XCTAssertEqual(fake.updatedEventIDs, ["evt-gone"])
        XCTAssertEqual(fake.createdEvents.count, 1)
        // New id rewritten onto the markdown line (assert via readDoc).
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(stored.calEventID, "fake-event-1")
        XCTAssertEqual(stored.timeBlock, newBlock)
    }

    // MARK: - WR-03: edit + concurrent reload don't drop each other's in-flight work

    func testEditTimeThenConcurrentReloadBothComplete() async throws {
        // editTime spawns editTask; a reload() fired right after spawns refreshTask. With
        // distinct handles, awaitCalendarRefresh awaits BOTH — the edit's updateEvent must
        // still land and not be dropped by the reload overwriting a shared handle (WR-03).
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        // The linked event exists in the fetch (matches the task's pre-edit block), so the
        // concurrent reload's open-time self-heal does not classify it missing.
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        let newBlock = TimeBlock(start: makeDate(2026, 6, 12, h: 16),
                                 end: makeDate(2026, 6, 12, h: 17))
        model.editTime(task, to: newBlock)   // spawns editTask
        model.reload()                       // spawns a fresh refreshTask concurrently
        await model.awaitCalendarRefresh()

        // The edit's update was not lost despite the concurrent reload.
        XCTAssertEqual(fake.updatedEventIDs, ["evt-1"], "edit-time update must not be dropped")
        let doc = try store.readDoc(on: today)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" }).timeBlock, newBlock)
    }

    // MARK: - SC4: drift sync on open

    func testDriftedLinkedTaskSurfacesPromptOnOpen() async throws {
        // Task says "review 14:00-15:00 evt-1"; calendar event drifted (title + time).
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review (moved)",
                          start: makeDate(2026, 6, 12, h: 16),
                          end: makeDate(2026, 6, 12, h: 17), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        let prompt = try XCTUnwrap(model.driftPrompt, "drift on open must surface a prompt")
        XCTAssertEqual(prompt.drifted.map(\.task.id), ["t_linked"])
        XCTAssertEqual(prompt.drifted.map(\.event.id), ["evt-1"])
    }

    func testConfirmDriftSyncRewritesMarkdownCalendarWins() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let evStart = makeDate(2026, 6, 12, h: 16)
        let evEnd = makeDate(2026, 6, 12, h: 17)
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review (moved)",
                          start: evStart, end: evEnd, calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.driftPrompt)

        model.confirmDriftSync()

        // Calendar wins: task text + time block rewritten to match the event.
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(stored.text, "review (moved)")
        XCTAssertEqual(stored.timeBlock, TimeBlock(start: evStart, end: evEnd))
        XCTAssertNil(model.driftPrompt, "prompt cleared after sync")
    }

    func testDismissDriftLeavesMarkdownUnchanged() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review (moved)",
                          start: makeDate(2026, 6, 12, h: 16),
                          end: makeDate(2026, 6, 12, h: 17), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.driftPrompt)

        model.dismissDriftPrompt()

        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(stored.text, "review", "declining keeps the user's markdown")
        XCTAssertNil(model.driftPrompt)
    }

    func testNoDriftNoPrompt() async throws {
        // Event matches the task exactly -> no drift, no prompt.
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        XCTAssertNil(model.driftPrompt)
    }

    // MARK: - CR-02: missing event (deleted in Calendar) surfaced + cleared on confirm

    func testMissingLinkedEventSurfacesPromptOnOpen() async throws {
        // Task is linked to evt-gone, but the calendar fetch returns NO matching event
        // (deleted in Calendar.app). On open it is SURFACED (not silently dropped); the dead
        // link is not mutated until the user confirms.
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-gone")])
        let fake = FakeCalendarService()
        fake.cannedEvents = []   // event deleted in Calendar -> not in the fetched range
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        XCTAssertEqual(model.missingLinkCount, 1, "deleted linked event must be surfaced")
        XCTAssertEqual(model.missingLinkPrompt?.tasks.map(\.id), ["t_linked"])
        XCTAssertNil(model.driftPrompt, "missing != drift")
        // Not yet mutated on disk — surfacing alone never clobbers the link.
        let doc = try store.readDoc(on: today)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" }).calEventID, "evt-gone")
    }

    func testConfirmClearMissingLinkClearsDeadLinkKeepsTimeBlock() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-gone")])
        let fake = FakeCalendarService()
        fake.cannedEvents = []
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.missingLinkPrompt)

        model.confirmClearMissingLinks()

        // Calendar wins: dead link cleared, time block preserved (unlinked time-blocked task).
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertNil(stored.calEventID, "dead cal_event link must be cleared on confirm")
        XCTAssertNotNil(stored.timeBlock, "time block is preserved")
        XCTAssertNil(model.missingLinkPrompt, "prompt cleared after confirm")
    }

    func testDismissMissingLinkKeepsDeadLink() async throws {
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-gone")])
        let fake = FakeCalendarService()
        fake.cannedEvents = []
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.missingLinkPrompt)

        model.dismissMissingLinkPrompt()

        let doc = try store.readDoc(on: today)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" }).calEventID, "evt-gone",
                       "dismiss keeps the link")
        XCTAssertNil(model.missingLinkPrompt)
    }

    func testPresentLinkedEventDoesNotSurfaceMissing() async throws {
        // The linked event still exists -> no missing prompt.
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        XCTAssertNil(model.missingLinkPrompt)
        let doc = try store.readDoc(on: today)
        XCTAssertEqual(try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" }).calEventID, "evt-1")
    }

    // MARK: - WR-04: drift sync stores the sanitized event title

    func testConfirmDriftSyncStoresSanitizedTitle() async throws {
        // Event title carries markdown; sync must store the SANITIZED form so the next open
        // does not re-drift (sanitize(stored) == event.title) and the task line stays parser-safe.
        let (store, today) = try seed(tasks: [linkedTask(id: "t_linked", eventID: "evt-1")])
        let fake = FakeCalendarService()
        let evStart = makeDate(2026, 6, 12, h: 16)
        let evEnd = makeDate(2026, 6, 12, h: 17)
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "**Deep** `work`",
                          start: evStart, end: evEnd, calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.driftPrompt)

        model.confirmDriftSync()

        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(stored.text, "Deep work", "stored text is sanitized, not raw")
        // Round-trip stability: re-running drift against the same event finds NO drift.
        let result = CalendarDrift.driftedTasks([stored], against: fake.cannedEvents)
        XCTAssertTrue(result.drifted.isEmpty, "sanitized store must not re-drift on next open")
    }

    func testHistoricalLinkedTaskNotCheckedForDrift() async throws {
        // A linked task that lives in YESTERDAY's file must never drive a drift prompt
        // when Jotty opens today: reload() reads only today's file, so historical
        // linked tasks are structurally out of scope (CONTEXT: only today+future).
        let yesterday = makeDate(2026, 6, 11, h: 8)
        let today = makeDate(2026, 6, 12, h: 8)
        let store = Store(folder: folder, timezone: tz)
        // Seed a linked task into YESTERDAY's file.
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "old meeting", createdAt: yesterday,
                 timeBlock: TimeBlock(start: makeDate(2026, 6, 11, h: 14),
                                      end: makeDate(2026, 6, 11, h: 15)),
                 calEventID: "evt-old")
        ], at: yesterday)
        let fake = FakeCalendarService()
        // Even if a drifted event id matched, the historical task is out of scope.
        fake.cannedEvents = [
            CalendarEvent(id: "evt-old", title: "old meeting (moved)",
                          start: makeDate(2026, 6, 11, h: 16),
                          end: makeDate(2026, 6, 11, h: 17), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        XCTAssertNil(model.driftPrompt, "historical linked tasks are not drift-checked")
    }

    // MARK: - SC4: move to tomorrow (row affordance)

    func testMoveToTomorrowRemovesFromTodayAndReloads() async throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_move", text: "ship it", createdAt: today),
            Todo(id: "t_stay", text: "stays", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_move" })
        model.moveToTomorrow(task)

        // Left today's list (reloaded) and is gone from today's file on disk.
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_move" }, "moved task leaves today's list")
        XCTAssertTrue(model.todayTasks.contains { $0.id == "t_stay" })
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_move" })
        // Landed on tomorrow's file.
        let tomorrow = makeDate(2026, 6, 13, h: 8)
        XCTAssertTrue(try store.readDoc(on: tomorrow).tasks.contains { $0.id == "t_move" })
    }

    // MARK: - SC4: inline rename (row affordance)

    func testRenameCallsStoreAndReflectsNewText() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_rename", text: "old text", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_rename" })
        model.rename(task, to: "new text")

        // Store rewrote the text in place (id preserved); the reload reflects it.
        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_rename" })
        XCTAssertEqual(stored.text, "new text")
        XCTAssertEqual(model.todayTasks.first { $0.id == "t_rename" }?.text, "new text")
    }

    func testRenameEmptyAfterTrimRevertsToOriginal() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_rename", text: "keep me", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_rename" })
        model.rename(task, to: "   ")   // empty-after-trim → Store rejects (no write)

        // Disk unchanged; the reload reverts the UI to the persisted text.
        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_rename" })
        XCTAssertEqual(stored.text, "keep me", "empty rename is rejected, original preserved")
        XCTAssertEqual(model.todayTasks.first { $0.id == "t_rename" }?.text, "keep me")
    }

    // MARK: - SC1: Send to Claude (row affordance)

    func testSendToClaudeRoutesWrappedPromptThroughHandoff() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_claude", text: "draft the email", createdAt: today)
        ], at: today)

        let fake = FakeClaudeHandoff()   // binaryAvailable = true by default
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, claudeHandoff: fake)
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_claude" })
        model.sendToClaude(task)

        // Routes the WRAPPED prompt (template applied once at the call site).
        XCTAssertEqual(fake.sendCallCount, 1)
        XCTAssertEqual(fake.lastPrompt, ClaudePrompt.wrapped("draft the email"))
        XCTAssertNil(model.claudeNotice, "binary present → no notice")
    }

    func testSendToClaudeNoBinarySetsNotice() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_claude", text: "draft the email", createdAt: today)
        ], at: today)

        let fake = FakeClaudeHandoff()
        fake.binaryAvailable = false   // Code mode, no binary → send returns false
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, claudeHandoff: fake)
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_claude" })
        model.sendToClaude(task)

        XCTAssertEqual(fake.sendCallCount, 1)
        XCTAssertNotNil(model.claudeNotice, "no binary → one-line notice")
    }

    func testSendToClaudeNoHandoffIsNoOp() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_claude", text: "draft the email", createdAt: today)
        ], at: today)

        // No handoff injected (back-compat construction).
        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_claude" })
        model.sendToClaude(task)   // must not crash, no notice
        XCTAssertNil(model.claudeNotice)
    }

    // MARK: - Helpers

    /// Seeds today's file with the given tasks and returns (store, today).
    private func seed(tasks: [Todo], at today: Date? = nil) throws -> (Store, Date) {
        let day = today ?? makeDate(2026, 6, 12, h: 8)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: tasks, at: day)
        return (store, day)
    }

    /// A linked (timeBlock + calEventID) today task.
    private func linkedTask(id: String, eventID: String,
                            text: String = "review",
                            start: Date? = nil, end: Date? = nil) -> Todo {
        let s = start ?? makeDate(2026, 6, 12, h: 14)
        let e = end ?? makeDate(2026, 6, 12, h: 15)
        return Todo(id: id, text: text, createdAt: makeDate(2026, 6, 12, h: 8),
                    timeBlock: TimeBlock(start: s, end: e), calEventID: eventID)
    }

    /// A ConfigStore backed by a fresh temp file, primed with the delete preference.
    private func config(deletePref: Bool?) throws -> ConfigStore {
        let path = folder.appendingPathComponent("config-\(UUID().uuidString).json")
        let cfg = try ConfigStore(path: path)
        try cfg.update { $0.deleteCalendarEventWithTask = deletePref }
        return cfg
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
