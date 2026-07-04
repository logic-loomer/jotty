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

    // WR-09: after a storage-folder change, replaceStore must swap the backing Store
    // and reload — the visible list reflects the NEW folder, not the launch-time one.
    func testReplaceStoreReloadsFromNewFolder() throws {
        let today = makeDate(2026, 6, 12, h: 8)
        let storeA = Store(folder: folder, timezone: tz)
        try storeA.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old_folder", text: "old folder task", createdAt: today)
        ], at: today)
        let model = MenubarListModel(store: storeA, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertEqual(model.tasks.map(\.id), ["t_old_folder"])

        // The user picks a new folder in Settings → Storage.
        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }
        let storeB = Store(folder: folderB, timezone: tz)
        try storeB.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_new_folder", text: "new folder task", createdAt: today)
        ], at: today)

        model.replaceStore(storeB)

        XCTAssertEqual(model.tasks.map(\.id), ["t_new_folder"],
                       "the list must read the NEW folder after replaceStore")
        XCTAssertEqual(model.store.folder, folderB,
                       "the backing store must be the swapped-in instance")
    }

    // A store swap is never an explicit calendar action: the Settings willClose observer
    // calls replaceStore, so its reload must NOT re-issue the one-time TCC calendar
    // prompt while access is notDetermined (same class as WR-06).
    func testReplaceStoreDoesNotPromptForCalendarAccess() async throws {
        let today = makeDate(2026, 6, 12, h: 8)
        let store = Store(folder: folder, timezone: tz)
        let fake = FakeCalendarService()
        fake.accessToReturn = .notDetermined

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()
        // Init's reload keeps the popover-open default (prompt allowed); whatever it
        // recorded is the baseline — the swap below must add NOTHING to it.
        let baseline = fake.requestAccessCallCount

        model.replaceStore(store)
        await model.awaitCalendarRefresh()

        XCTAssertEqual(fake.requestAccessCallCount, baseline,
                       "store-swap reload must never re-issue the TCC calendar prompt")
        XCTAssertFalse(model.calendarAccessDenied,
                       "unprompted notDetermined must not flag denial (a later user action can still ask)")
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

    func testMoveStaleLeftoverToTomorrowLandsOnRealTomorrowNotInThePast() throws {
        // CR-01 + IN-03 regression: a rolled leftover (createdAt 3 days ago,
        // visible copy in TODAY's file — the only state the menubar can show)
        // must move FROM today's file TO today+1 (the REAL tomorrow, computed
        // from now()) and stop being a leftover — NOT leave the visible copy
        // behind, NOT land in a past-day file.
        let store = Store(folder: folder, timezone: tz)
        let threeDaysAgo = makeDate(2026, 6, 9, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        // Post-rollover state: hidden rolled_to:-marked origin line…
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_stale", text: "ancient leftover", createdAt: threeDaysAgo,
                 rolledTo: makeDate(2026, 6, 12, h: 0, min: 0))
        ], at: threeDaysAgo)
        // …and the visible copy in today's file (createdAt keeps the origin day).
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_stale", text: "ancient leftover", createdAt: threeDaysAgo)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        // The row the user acts on comes from the model's partitions (IN-03).
        let task = try XCTUnwrap(model.leftovers.first { $0.id == "t_stale" })
        model.moveToTomorrow(task)

        // The visible copy left today's file (no duplicate stays behind).
        XCTAssertFalse(try store.readDoc(on: today).tasks.contains { $0.id == "t_stale" },
                       "the visible today copy is the one that moves")
        XCTAssertFalse(model.leftovers.contains { $0.id == "t_stale" })
        // Landed on the REAL tomorrow (today+1 = 2026-06-13), not 2 days in the past.
        let realTomorrow = makeDate(2026, 6, 13, h: 8)
        let landed = try XCTUnwrap(try store.readDoc(on: realTomorrow).tasks.first { $0.id == "t_stale" })
        XCTAssertEqual(landed.text, "ancient leftover")
        // It is no longer a leftover (its createdAt is now tomorrow's startOfDay, future).
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        XCTAssertGreaterThan(cal.startOfDay(for: landed.createdAt), cal.startOfDay(for: today),
                             "moved task's createdAt is in the future, so it stops being a leftover")
        // It did NOT silently land in a past day file (2026-06-10 = today-2).
        let twoDaysAgo = makeDate(2026, 6, 10, h: 8)
        XCTAssertFalse(try store.readDoc(on: twoDaysAgo).tasks.contains { $0.id == "t_stale" },
                       "must NOT land in a past-day file")
        // The hidden origin line keeps its rolled_to: history marker untouched.
        let originLine = try XCTUnwrap(try store.readDoc(on: threeDaysAgo).tasks.first { $0.id == "t_stale" })
        XCTAssertNotNil(originLine.rolledTo)
    }

    func testMoveLinkedTaskToTomorrowMovesEventAndAvoidsFalseMissing() async throws {
        // Sweep WR: the store re-anchors a linked task's time block to TOMORROW's slot on
        // move; the calendar event must move with it. Otherwise next day's day-filtered
        // fetch can't find the (still-on-original-day) event and falsely classifies the
        // task missing — orphaning the live event on confirm.
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
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_linked" })

        model.moveToTomorrow(task)
        await model.awaitCalendarRefresh()   // awaits the event move (editTask) + reload refresh

        // The linked event moved with the task (red on the old no-op behavior).
        XCTAssertEqual(fake.updatedEventIDs, ["evt-1"], "the linked event must move with the task")
        // The moved task on tomorrow keeps a VALID link + its re-anchored block.
        let tomorrow = makeDate(2026, 6, 13, h: 8)
        let moved = try XCTUnwrap(try store.readDoc(on: tomorrow).tasks.first { $0.id == "t_linked" })
        XCTAssertEqual(moved.calEventID, "evt-1", "the link stays valid across the move")
        XCTAssertEqual(moved.timeBlock,
                       TimeBlock(start: makeDate(2026, 6, 13, h: 14), end: makeDate(2026, 6, 13, h: 15)))

        // Next-day open: the event now lives on tomorrow, so the fetch finds it -> no
        // false missing-link classification.
        fake.cannedEvents = [
            CalendarEvent(id: "evt-1", title: "review",
                          start: makeDate(2026, 6, 13, h: 14),
                          end: makeDate(2026, 6, 13, h: 15), calendarTitle: "Work")
        ]
        let nextModel = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                         now: { tomorrow }, calendar: fake)
        await nextModel.awaitCalendarRefresh()
        XCTAssertNil(nextModel.missingLinkPrompt,
                     "a moved linked task whose event still exists must not surface a false missing-link")
    }

    func testRenameRolledLeftoverEditsVisibleCopyNotHiddenOriginLine() throws {
        // IN-03: renaming a rolled leftover must rewrite the visible today copy;
        // writing the hidden origin line let the reload revert the user's edit.
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old text", createdAt: yesterday,
                 rolledTo: makeDate(2026, 6, 12, h: 0, min: 0))
        ], at: yesterday)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old text", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let leftover = try XCTUnwrap(model.leftovers.first { $0.id == "t_left" })
        model.rename(leftover, to: "new text")

        XCTAssertEqual(try store.readDoc(on: today).tasks.first { $0.id == "t_left" }?.text,
                       "new text", "the visible copy is renamed")
        XCTAssertEqual(model.leftovers.first { $0.id == "t_left" }?.text, "new text",
                       "the reload keeps (not reverts) the edit")
        XCTAssertEqual(try store.readDoc(on: yesterday).tasks.first { $0.id == "t_left" }?.text,
                       "old text", "the hidden origin line is history — untouched")
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

    // MARK: - Phase 8 SC3: snooze visibility filter (CALX-03)

    func testFutureSnoozedTaskHiddenFromBothPartitionsNilSnoozeUnaffected() throws {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        let snoozeDay = makeDate(2026, 6, 13, h: 0, min: 0)
        // All four live in TODAY's file (rolled copies keep their createdAt).
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_snzToday", text: "later", createdAt: today, snooze: snoozeDay),
            Todo(id: "t_snzLeftover", text: "old later", createdAt: yesterday, snooze: snoozeDay),
            Todo(id: "t_visible", text: "now", createdAt: today),
            Todo(id: "t_visibleLeftover", text: "old now", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        // Future-snoozed tasks hidden from BOTH partitions; nil-snooze unaffected.
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_visible"])
        XCTAssertEqual(model.leftovers.map(\.id), ["t_visibleLeftover"])
        // The @Published source array stays the FULL list (doneCount + calendar
        // drift linkage read it) — the filter applies to the partitions only.
        XCTAssertEqual(model.tasks.count, 4, "source tasks array keeps snoozed tasks")
    }

    func testSnoozedTaskReappearsOnSnoozeDateTokenLeftInPlace() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        let snoozeDay = makeDate(2026, 6, 13, h: 0, min: 0)
        // The task lives in today's file AND (as the rollover would land it) in
        // tomorrow's file — same id, createdAt, snooze token carried along.
        let task = Todo(id: "t_snz", text: "later", createdAt: today, snooze: snoozeDay)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [task], at: today)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [task],
                                at: makeDate(2026, 6, 13, h: 8))

        var current = today
        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { current })
        // Before the snooze date: hidden from both partitions.
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_snz" })
        XCTAssertFalse(model.leftovers.contains { $0.id == "t_snz" })

        // On the snooze date: reappears automatically (snooze <= todayStart).
        current = makeDate(2026, 6, 13, h: 8)
        model.reload()
        XCTAssertTrue(model.leftovers.contains { $0.id == "t_snz" },
                      "createdAt yesterday + not done -> reappears as a leftover")
        // The token is left in place on disk, merely ignored on/after the date.
        let stored = try XCTUnwrap(try store.readDoc(on: current).tasks.first { $0.id == "t_snz" })
        XCTAssertNotNil(stored.snooze, "reappear never clears the snooze token")
    }

    func testPastSnoozeNeverHides() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_pastSnz", text: "was snoozed", createdAt: today,
                 snooze: makeDate(2026, 6, 11, h: 0, min: 0))
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertEqual(model.todayTasks.map(\.id), ["t_pastSnz"],
                       "snooze <= todayStart must never hide the task")
    }

    func testDoneCountCountsSnoozedDoneTask() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_doneSnz", text: "done then snoozed", createdAt: today,
                 done: true, completedAt: today,
                 snooze: makeDate(2026, 6, 13, h: 0, min: 0)),
            Todo(id: "t_open", text: "open", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        // Hidden from the partitions...
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_doneSnz" })
        // ...but doneCount reads the FULL tasks array, so it still counts.
        XCTAssertEqual(model.doneCount, 1, "snooze filter must not skew doneCount")
        XCTAssertEqual(model.tasks.count, 2)
    }

    // MARK: - Phase 8 SC2/SC3: model snooze/setRecurrence methods

    func testModelSnoozePersistsViaStoreAndVanishesFromList() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_snz", text: "later", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_snz" })
        model.snooze(task, to: makeDate(2026, 6, 13, h: 0, min: 0))

        // Persisted (snooze: is date-only, round-trips to the day's midnight)...
        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_snz" })
        XCTAssertEqual(stored.snooze, makeDate(2026, 6, 13, h: 0, min: 0))
        // ...and the reload dropped it from today's partitions.
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_snz" })
        XCTAssertFalse(model.leftovers.contains { $0.id == "t_snz" })
    }

    func testModelSetRecurrencePersistsViaStoreAndReloads() throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_rec", text: "standup", createdAt: today)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let task = try XCTUnwrap(model.todayTasks.first { $0.id == "t_rec" })
        model.setRecurrence(task, to: .daily)

        var stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_rec" })
        XCTAssertEqual(stored.recur, .daily)
        // Recurrence never hides the task; the reload reflects the new rule.
        XCTAssertEqual(model.todayTasks.first { $0.id == "t_rec" }?.recur, .daily)

        // The Repeat "None" choice clears the rule.
        model.setRecurrence(task, to: nil)
        stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_rec" })
        XCTAssertNil(stored.recur)
    }

    func testSnoozeOnRolledLeftoverWritesTodayCopyAndHidesIt() throws {
        // CR-03: after rollover a leftover exists as TWO lines sharing one id —
        // the hidden rolled_to:-marked origin line and the visible copy in
        // TODAY's file (the one reload() loads). Snooze must stamp the visible
        // copy, not the hidden origin line (which made "Snooze to Tomorrow" on
        // any leftover a silent no-op).
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        // Origin line: rolled_to today (never displayed).
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old thing", createdAt: yesterday,
                 rolledTo: makeDate(2026, 6, 12, h: 0, min: 0))
        ], at: yesterday)
        // Rolled copy in today's file (createdAt keeps the origin day).
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old thing", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let leftover = try XCTUnwrap(model.leftovers.first { $0.id == "t_left" })
        model.snooze(leftover, to: makeDate(2026, 6, 13, h: 0, min: 0))

        // The VISIBLE copy in today's file carries the token…
        let todayCopy = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_left" })
        XCTAssertEqual(todayCopy.snooze, makeDate(2026, 6, 13, h: 0, min: 0))
        // …the hidden origin line is untouched…
        let originLine = try XCTUnwrap(try store.readDoc(on: yesterday).tasks.first { $0.id == "t_left" })
        XCTAssertNil(originLine.snooze)
        // …and the leftover actually disappears from the list until the date.
        XCTAssertFalse(model.leftovers.contains { $0.id == "t_left" })
        XCTAssertFalse(model.todayTasks.contains { $0.id == "t_left" })
    }

    func testSetRecurrenceOnRolledLeftoverWritesTodayCopy() throws {
        // CR-03 (Repeat half): the rule must land on the visible today copy so
        // the checkmark reflects it — not on the hidden rolled-away origin line.
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old thing", createdAt: yesterday,
                 rolledTo: makeDate(2026, 6, 12, h: 0, min: 0))
        ], at: yesterday)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_left", text: "old thing", createdAt: yesterday)
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let leftover = try XCTUnwrap(model.leftovers.first { $0.id == "t_left" })
        model.setRecurrence(leftover, to: .daily)

        let todayCopy = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_left" })
        XCTAssertEqual(todayCopy.recur, .daily, "rule lands on the visible copy")
        let originLine = try XCTUnwrap(try store.readDoc(on: yesterday).tasks.first { $0.id == "t_left" })
        XCTAssertNil(originLine.recur, "hidden origin line stays rule-free")
        XCTAssertEqual(model.leftovers.first { $0.id == "t_left" }?.recur, .daily,
                       "the reloaded row shows the rule (checkmark reflects reality)")
    }

    // MARK: - Phase 8 CR-04: Repeat menu on an INSTANCE edits its TEMPLATE

    func testSetRecurrenceNoneOnInstanceStopsFutureInstancing() throws {
        // Day 1: template. Day 2: instance. "None" from the instance. Day 3:
        // NO new instance — and the cancelled template must not roll forward
        // as a leftover either.
        let store = Store(folder: folder, timezone: tz)
        let statePath = folder.appendingPathComponent("last-rollover.txt")
        let day1 = makeDate(2026, 6, 11, h: 9)
        let day2 = makeDate(2026, 6, 12, h: 8)
        let day3 = makeDate(2026, 6, 13, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_tpl", text: "water plants", createdAt: day1, recur: .daily)
        ], at: day1)
        try "2026-06-11".write(to: statePath, atomically: true, encoding: .utf8)

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: day2)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { day2 })
        let instance = try XCTUnwrap(model.todayTasks.first { $0.recurSrc == "t_tpl:2026-06-12" })
        XCTAssertEqual(instance.recur, .daily, "the instance shows the inherited rule")
        model.setRecurrence(instance, to: nil)   // the user's "stop repeating"

        // The TEMPLATE rule is cleared and the line can never roll forward.
        let template = try XCTUnwrap(try store.readDoc(on: day1).tasks.first { $0.id == "t_tpl" })
        XCTAssertNil(template.recur, "None on an instance clears the template rule")
        XCTAssertNotNil(template.rolledTo, "the rule-less template must never resurface as a leftover")
        // The visible instance's checkmark reflects the choice.
        let visible = try XCTUnwrap(try store.readDoc(on: day2).tasks.first { $0.id == instance.id })
        XCTAssertNil(visible.recur)

        // Day 3: no NEW instance, no resurrected template line. (The day-2
        // instance itself is now an ordinary task; if left not-done it rolls
        // forward as a leftover carrying its old day-2 marker — by design.)
        try svc.run(now: day3)
        let day3Doc = try store.readDoc(on: day3)
        XCTAssertTrue(day3Doc.tasks.filter { $0.recurSrc == "t_tpl:2026-06-13" }.isEmpty,
                      "the recurrence is genuinely cancelled — no fresh day-3 instance")
        XCTAssertFalse(day3Doc.tasks.contains { $0.id == "t_tpl" },
                       "the cancelled template must not roll forward as a leftover")
    }

    func testSetRecurrenceRuleChangeOnInstanceEditsTemplate() throws {
        // Changing the rule from an instance redirects FUTURE instancing.
        let store = Store(folder: folder, timezone: tz)
        let statePath = folder.appendingPathComponent("last-rollover.txt")
        let day1 = makeDate(2026, 6, 11, h: 9)   // Thursday
        let day2 = makeDate(2026, 6, 12, h: 8)   // Friday
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_tpl", text: "standup", createdAt: day1, recur: .daily)
        ], at: day1)
        try "2026-06-11".write(to: statePath, atomically: true, encoding: .utf8)

        let svc = RolloverService(store: store, statePath: statePath, timezone: tz)
        try svc.run(now: day2)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { day2 })
        let instance = try XCTUnwrap(model.todayTasks.first { $0.recurSrc == "t_tpl:2026-06-12" })
        // Daily -> only Mondays (2).
        model.setRecurrence(instance, to: .custom([2]))

        let template = try XCTUnwrap(try store.readDoc(on: day1).tasks.first { $0.id == "t_tpl" })
        XCTAssertEqual(template.recur, .custom([2]), "the template carries the new rule")
        XCTAssertNil(template.rolledTo, "a rule CHANGE keeps the template alive on its day")
        XCTAssertEqual(try store.readDoc(on: day2).tasks.first { $0.id == instance.id }?.recur,
                       .custom([2]), "the visible instance mirrors the new rule")

        // Saturday: no FRESH instance under the new rule (the day-2 instance
        // may roll forward as an ordinary leftover — by design); Monday: due.
        try svc.run(now: makeDate(2026, 6, 13, h: 8))
        XCTAssertTrue(try store.readDoc(on: makeDate(2026, 6, 13)).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-06-13" }.isEmpty)
        try svc.run(now: makeDate(2026, 6, 15, h: 8))
        XCTAssertEqual(try store.readDoc(on: makeDate(2026, 6, 15)).tasks
                        .filter { $0.recurSrc == "t_tpl:2026-06-15" }.count, 1)
    }

    func testSetRecurrenceOnOrphanInstancePromotesItToTemplate() throws {
        // Fallback: the marker points at a template that no longer exists —
        // choosing a rule promotes the visible line to a template so the
        // choice actually takes effect.
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_inst", text: "orphan", createdAt: today,
                 recur: .daily, recurSrc: "t_gone:2026-06-12")
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        let instance = try XCTUnwrap(model.todayTasks.first { $0.id == "t_inst" })
        model.setRecurrence(instance, to: .weekly(nil))

        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_inst" })
        XCTAssertEqual(stored.recur, .weekly(nil))
        XCTAssertNil(stored.recurSrc, "promoted to a template (scannable from tomorrow)")
    }

    /// Sweep INFO: the "Weekly" menu choice anchors on the weekday the user PICKS
    /// it (`model.currentWeekday`), so a task created on a Thursday but set Weekly
    /// on a Tuesday persists `weekly:<tuesday>` and fires on Tuesdays. Here now() is
    /// Tuesday 2026-06-16 (weekday 3) though the task was created Thursday 2026-06-11.
    func testWeeklyChoiceCapturesCurrentWeekdayNotCreatedWeekday() throws {
        let store = Store(folder: folder, timezone: tz)
        let createdThursday = makeDate(2026, 6, 11, h: 9)   // Thursday (weekday 5)
        let setTuesday = makeDate(2026, 6, 16, h: 8)        // Tuesday (weekday 3)
        // The task is a leftover created Thursday, visible in today's (Tuesday) file.
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_wk", text: "sync", createdAt: createdThursday)
        ], at: setTuesday)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { setTuesday })
        XCTAssertEqual(model.currentWeekday, 3, "now() is a Tuesday → weekday 3")
        let task = try XCTUnwrap(model.leftovers.first { $0.id == "t_wk" })
        // Mirror what the Weekly menu item does.
        model.setRecurrence(task, to: .weekly(model.currentWeekday))

        let stored = try XCTUnwrap(try store.readDoc(on: setTuesday).tasks.first { $0.id == "t_wk" })
        XCTAssertEqual(stored.recur, .weekly(3),
                       "Weekly must capture the chosen (Tuesday) weekday, not the createdAt (Thursday) one")
    }

    func testSnoozeConvenienceDatesAnchorOnNowNotCreatedAt() throws {
        // CR-01: Tomorrow / Next week are computed from now(), never task.createdAt.
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })
        XCTAssertEqual(model.snoozeTomorrowDate, makeDate(2026, 6, 13, h: 0, min: 0))
        XCTAssertEqual(model.snoozeNextWeekDate, makeDate(2026, 6, 19, h: 0, min: 0))
    }

    // MARK: - Phase 8 SC1: drag-to-time-block dropTask (CALX-01)

    /// The model's default drop duration (RESEARCH A2: 30 min).
    private var dropDuration: TimeInterval { 30 * 60 }

    func testDropTaskSetsTimeBlockCreatesSanitizedEventAndWritesCalEventBack() async throws {
        // Markdown emphasis in the text must be sanitized OUT of the event title (T-8-08).
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "**write** report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        let slot = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot)
        await model.awaitDropWork()

        let expected = TimeBlock(start: slot, end: slot.addingTimeInterval(dropDuration))
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.timeBlock, expected, "time: block = slot + default duration")
        // Exactly ONE event, created via the Phase-5 path with the SANITIZED title.
        XCTAssertEqual(fake.createdEvents.count, 1)
        XCTAssertEqual(fake.createdEvents.first?.title, "write report")
        XCTAssertEqual(fake.createdEvents.first?.start, slot)
        XCTAssertEqual(fake.createdEvents.first?.end, expected.end)
        // cal_event: written back onto the markdown line after the async completes.
        XCTAssertEqual(stored.calEventID, "fake-event-1")
    }

    func testDropTaskCalendarCreateFailureLeavesTimeBlockOnDiskNoCalEvent() async throws {
        // Best-effort (T-8-09): a create failure never rolls back the disk write.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "write report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "boom")
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        let slot = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot)
        await model.awaitDropWork()

        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.timeBlock,
                       TimeBlock(start: slot, end: slot.addingTimeInterval(dropDuration)),
                       "disk wins: the time: block stays despite the calendar failure")
        XCTAssertNil(stored.calEventID, "no cal_event on a failed create")
    }

    func testDropTaskConflictCancelSkipsCreateKeepsTimeBlock() async throws {
        // Conflict gate (T-8-10): an overlapping event must consult the decision;
        // cancel skips the create but the time: block is already on disk (disk wins).
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "write report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-x", title: "Existing Standup",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        let slot = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot)
        try await waitUntil { model.pendingDropConflict != nil }
        XCTAssertEqual(model.pendingDropConflict?.conflictTitle, "Existing Standup")
        model.resolveDropConflict(commitAnyway: false)
        await model.awaitDropWork()

        XCTAssertTrue(fake.createdEvents.isEmpty, "cancel must skip the create")
        XCTAssertNil(model.pendingDropConflict, "conflict state clears after decision")
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.timeBlock,
                       TimeBlock(start: slot, end: slot.addingTimeInterval(dropDuration)),
                       "the disk-first time: block survives a cancel")
        XCTAssertNil(stored.calEventID)
    }

    func testDropTaskConflictCommitAnywayCreatesEvent() async throws {
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "write report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-x", title: "Existing Standup",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        let slot = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot)
        try await waitUntil { model.pendingDropConflict != nil }
        model.resolveDropConflict(commitAnyway: true)
        await model.awaitDropWork()

        XCTAssertEqual(fake.createdEvents.count, 1, "commit anyway creates the event")
        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.calEventID, "fake-event-1")
    }

    func testDropTaskOnScheduledTaskMovesBlockWithoutDuplicateCreate() async throws {
        // CONTEXT "unscheduled only": a drop on an already-scheduled task is a MOVE —
        // the linked event is updated in place, never created a second time.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "write report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        // First drop: schedules + creates fake-event-1.
        let slot1 = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot1)
        await model.awaitDropWork()
        XCTAssertEqual(fake.createdEvents.count, 1)

        // Second drop on the SAME (now scheduled + linked) task: a move.
        let slot2 = makeDate(2026, 6, 12, h: 16)
        model.dropTask(id: "t_drop", atSlot: slot2)
        await model.awaitDropWork()

        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.timeBlock,
                       TimeBlock(start: slot2, end: slot2.addingTimeInterval(dropDuration)),
                       "the move writes the new block")
        XCTAssertEqual(fake.createdEvents.count, 1, "no duplicate create beyond the one event")
        XCTAssertEqual(fake.updatedEventIDs, ["fake-event-1"],
                       "the move updates the linked event in place")
        XCTAssertEqual(stored.calEventID, "fake-event-1")
    }

    func testConcurrentDropsPreemptEarlierConflictAsCancelNeverLeak() async throws {
        // WR-02: a second drop reaching the conflict gate while the first is
        // still pending must PRE-EMPT the first (auto-cancel) instead of
        // overwriting — and leaking — its continuation. Exactly one decision
        // is pending at a time; only the second drop's decision creates.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_a", text: "first", createdAt: makeDate(2026, 6, 12, h: 8)),
            Todo(id: "t_b", text: "second", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            CalendarEvent(id: "evt-x", title: "First Meeting",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        // Drop A reaches the gate and suspends.
        let slotA = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_a", atSlot: slotA)
        try await waitUntil { model.pendingDropConflict?.conflictTitle == "First Meeting" }

        // Retitle the canned overlap so drop B's pending conflict is
        // distinguishable from A's, then drop B while A is still pending.
        fake.cannedEvents = [
            CalendarEvent(id: "evt-x", title: "Second Meeting",
                          start: makeDate(2026, 6, 12, h: 14),
                          end: makeDate(2026, 6, 12, h: 15), calendarTitle: "Work")
        ]
        let slotB = makeDate(2026, 6, 12, h: 14, min: 30)
        model.dropTask(id: "t_b", atSlot: slotB)
        try await waitUntil { model.pendingDropConflict?.conflictTitle == "Second Meeting" }

        // Only B pends now; resolving commits B. A was pre-empted as cancel —
        // its resumption can never create (its decision was already false).
        model.resolveDropConflict(commitAnyway: true)
        await model.awaitDropWork()

        try await waitUntil { fake.createdEvents.count == 1 }
        XCTAssertEqual(fake.createdEvents.first?.start, slotB,
                       "only the second (still-pending) drop's event is created")
        let doc = try store.readDoc(on: today)
        let taskA = try XCTUnwrap(doc.tasks.first { $0.id == "t_a" })
        XCTAssertEqual(taskA.timeBlock?.start, slotA,
                       "the pre-empted drop keeps its disk-first time: block")
        XCTAssertNil(taskA.calEventID, "pre-empted-as-cancel: no event for drop A")
        let taskB = try XCTUnwrap(doc.tasks.first { $0.id == "t_b" })
        XCTAssertEqual(taskB.calEventID, "fake-event-1")
        XCTAssertNil(model.pendingDropConflict, "no orphaned pending decision remains")
    }

    func testDropNearMidnightClampsBlockInsideDay() async throws {
        // WR-03: the drop layer reaches 24:00, but the time: token serializes
        // wall-clock only — a 23:45–00:15 block re-parses inverted (end 00:00
        // < start on the same day). The slot is clamped so the block's end
        // stays strictly before midnight and the start stays grid-aligned:
        // with a 30-min duration and 15-min snap, the latest block is
        // 23:15–23:45.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_late", text: "night owl", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        model.dropTask(id: "t_late", atSlot: makeDate(2026, 6, 12, h: 23, min: 45))
        await model.awaitDropWork()

        let expected = TimeBlock(start: makeDate(2026, 6, 12, h: 23, min: 15),
                                 end: makeDate(2026, 6, 12, h: 23, min: 45))
        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_late" })
        XCTAssertEqual(stored.timeBlock, expected, "clamped to the latest block that fits the day")
        // The ROUND-TRIP is the point: re-reading the serialized time: token
        // must never yield an inverted block.
        let tb = try XCTUnwrap(stored.timeBlock)
        XCTAssertGreaterThan(tb.end, tb.start)
        // The calendar event matches the clamped (persisted) block exactly.
        XCTAssertEqual(fake.createdEvents.first?.start, expected.start)
        XCTAssertEqual(fake.createdEvents.first?.end, expected.end)
    }

    func testDropAtExactDayEndClampsSameAsLateSlot() async throws {
        // The 24:00 edge (a block entirely on the next day) clamps identically.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_late", text: "night owl", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today })

        model.dropTask(id: "t_late", atSlot: makeDate(2026, 6, 13, h: 0, min: 0))
        await model.awaitDropWork()

        let stored = try XCTUnwrap(try store.readDoc(on: today).tasks.first { $0.id == "t_late" })
        XCTAssertEqual(stored.timeBlock,
                       TimeBlock(start: makeDate(2026, 6, 12, h: 23, min: 15),
                                 end: makeDate(2026, 6, 12, h: 23, min: 45)))
    }

    func testDropTaskUnknownIdIsNoOp() async throws {
        let (store, today) = try seed(tasks: [
            Todo(id: "t_other", text: "unrelated", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let fake = FakeCalendarService()
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, calendar: fake)
        await model.awaitCalendarRefresh()

        model.dropTask(id: "t_missing", atSlot: makeDate(2026, 6, 12, h: 14))
        await model.awaitDropWork()

        XCTAssertTrue(fake.createdEvents.isEmpty)
        let doc = try store.readDoc(on: today)
        XCTAssertNil(try XCTUnwrap(doc.tasks.first { $0.id == "t_other" }).timeBlock,
                     "an unknown id must write nothing")
    }

    func testDropTaskWithNoCalendarStillWritesTimeBlock() async throws {
        // Pure task tool path: no calendar injected — the block lands on disk, no event.
        let (store, today) = try seed(tasks: [
            Todo(id: "t_drop", text: "write report", createdAt: makeDate(2026, 6, 12, h: 8))
        ])
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today })

        let slot = makeDate(2026, 6, 12, h: 14)
        model.dropTask(id: "t_drop", atSlot: slot)
        await model.awaitDropWork()

        let doc = try store.readDoc(on: today)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_drop" })
        XCTAssertEqual(stored.timeBlock,
                       TimeBlock(start: slot, end: slot.addingTimeInterval(dropDuration)))
        XCTAssertNil(stored.calEventID)
        // The synchronous reload reflects the new block in the visible list.
        XCTAssertEqual(model.todayTasks.first { $0.id == "t_drop" }?.timeBlock?.start, slot)
    }

    // MARK: - Phase 8 SC1: unscheduledTasks (canvas rail source)

    func testUnscheduledTasksListsVisibleTasksWithoutTimeBlock() throws {
        let today = makeDate(2026, 6, 12, h: 8)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let store = Store(folder: folder, timezone: tz)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            // Unscheduled leftover: visible + draggable.
            Todo(id: "t_left", text: "leftover", createdAt: yesterday),
            // Unscheduled today task: visible + draggable.
            Todo(id: "t_plain", text: "plain", createdAt: today),
            // Already scheduled: excluded from the rail.
            Todo(id: "t_blocked", text: "blocked", createdAt: today,
                 timeBlock: TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                                      end: makeDate(2026, 6, 12, h: 15))),
            // Done: nothing left to schedule.
            Todo(id: "t_done", text: "done", createdAt: today, done: true),
            // Future-snoozed: hidden from today entirely (CALX-03).
            Todo(id: "t_snoozed", text: "snoozed", createdAt: today,
                 snooze: makeDate(2026, 6, 20))
        ], at: today)

        let model = MenubarListModel(store: store, timezone: tz,
                                     defaults: defaults, now: { today })

        XCTAssertEqual(model.unscheduledTasks.map(\.id), ["t_left", "t_plain"],
                       "visible, not-done, timeBlock==nil tasks only")
    }

    // MARK: - Helpers

    /// Polls until `condition` is true or fails after `timeout` (mirrors
    /// CaptureViewModelTests.waitUntil — for the pending-drop-conflict suspension).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)   // 5ms
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

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

    // MARK: - Unified inbox: Accept / Dismiss / lazy refresh (Phase 7, SC2/SC3)

    /// A temp-path InboxStateStore (dedupe state), cleaned with the suite's `folder`.
    private func makeInboxState() throws -> InboxStateStore {
        let path = folder.appendingPathComponent("inbox-state-\(UUID().uuidString).json")
        return try InboxStateStore(path: path)
    }

    private func inboxItem(_ id: String, source: String = "github",
                           title: String = "org/repo #1 — fix bug",
                           url: String = "https://github.com/org/repo/issues/1") -> InboxItem {
        InboxItem(id: id, sourceID: source, title: title, url: url,
                  timestamp: Date(timeIntervalSince1970: 0), rawText: title)
    }

    /// SC2: accepting a suggestion writes a Todo to today's file carrying the
    /// `source`/`sourceURL` provenance (round-trips through MarkdownDoc), records the id
    /// so a later refresh never re-suggests it, and drops it from the live suggestion list.
    func testAcceptWritesSourceTokenTaskRecordsIdAndDropsSuggestion() async throws {
        let today = makeDate(2026, 6, 12, h: 8)
        let store = Store(folder: folder, timezone: tz)
        let src = FakeInboxSource(id: "github", isConfigured: true)
        let item = inboxItem("github:42")
        src.cannedItems = [item]
        let service = InboxService(sources: [src], state: try makeInboxState())
        await service.refresh()
        XCTAssertEqual(service.suggestions.map(\.id), ["github:42"])

        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, inboxService: service)

        model.acceptSuggestion(item)

        // Written to today's file with source:/source_url: provenance (round-trip).
        let doc = try store.readDoc(on: today)
        let written = try XCTUnwrap(doc.tasks.first { $0.text == item.title })
        XCTAssertEqual(written.source, "github:42")
        XCTAssertEqual(written.sourceURL, "https://github.com/org/repo/issues/1")

        // Dropped from suggestions + recorded so a re-refresh never re-suggests it.
        XCTAssertFalse(service.suggestions.contains { $0.id == "github:42" })
        await service.refresh()
        XCTAssertFalse(service.suggestions.contains { $0.id == "github:42" },
                       "accepted id must never be re-suggested (SC2)")
    }

    /// SC2: dismissing a suggestion records the id (never re-suggested) and removes it
    /// from the list WITHOUT writing any task to the Store.
    func testDismissRecordsIdAndWritesNoTask() async throws {
        let today = makeDate(2026, 6, 12, h: 8)
        let store = Store(folder: folder, timezone: tz)
        let src = FakeInboxSource(id: "github", isConfigured: true)
        let item = inboxItem("github:7")
        src.cannedItems = [item]
        let service = InboxService(sources: [src], state: try makeInboxState())
        await service.refresh()

        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today }, inboxService: service)

        model.dismissSuggestion(item)

        // No task written by a dismiss.
        let doc = try store.readDoc(on: today)
        XCTAssertFalse(doc.tasks.contains { $0.source == "github:7" })
        // Dropped + never re-suggested.
        XCTAssertFalse(service.suggestions.contains { $0.id == "github:7" })
        await service.refresh()
        XCTAssertFalse(service.suggestions.contains { $0.id == "github:7" },
                       "dismissed id must never be re-suggested (SC2)")
    }

    /// SC3: the open-time refresh hook makes NO network call when no source is
    /// configured — the privacy default. Asserted through the wiring path
    /// (`refreshInbox()` → `InboxService.refresh()`) via the fake's call count.
    func testRefreshInboxMakesNoFetchWhenUnconfigured() async throws {
        let store = Store(folder: folder, timezone: tz)
        let src = FakeInboxSource(id: "github", isConfigured: false)
        src.cannedItems = [inboxItem("github:1")]
        let service = InboxService(sources: [src], state: try makeInboxState())

        let today = makeDate(2026, 6, 12, h: 8)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today },
                                     inboxService: service)

        await model.refreshInbox()

        XCTAssertEqual(src.fetchCallCount, 0, "no network on default/unconfigured config (SC3)")
        XCTAssertTrue(service.suggestions.isEmpty)
    }

    /// A nil inbox service (no wiring) is a no-op: refreshInbox/accept/dismiss must not crash.
    func testNilInboxServiceIsNoOp() async throws {
        let store = Store(folder: folder, timezone: tz)
        let today = makeDate(2026, 6, 12, h: 8)
        let model = MenubarListModel(store: store, timezone: tz, defaults: defaults,
                                     now: { today })
        await model.refreshInbox()                       // no crash
        model.acceptSuggestion(inboxItem("github:1"))    // no crash, no write
        model.dismissSuggestion(inboxItem("github:1"))   // no crash
        XCTAssertTrue(model.tasks.isEmpty)
    }

    // MARK: - Command bar highlight seam (Phase 9, SC3)

    /// Builds the standard two-partition fixture: one leftover ("t_old") and one
    /// today task ("t_new"), model anchored on 2026-06-12.
    private func makeHighlightModel() throws -> MenubarListModel {
        let store = Store(folder: folder, timezone: tz)
        let yesterday = makeDate(2026, 6, 11, h: 9)
        let today = makeDate(2026, 6, 12, h: 8)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_old", text: "leftover", createdAt: yesterday),
            Todo(id: "t_new", text: "fresh", createdAt: today)
        ], at: today)
        return MenubarListModel(store: store, timezone: tz,
                                defaults: defaults, now: { today })
    }

    func testHighlightSetsHighlightedTaskID() throws {
        let model = try makeHighlightModel()
        model.highlight(taskID: "t_new")
        XCTAssertEqual(model.highlightedTaskID, "t_new")
    }

    func testReloadClearsHighlight() throws {
        // The controller sets the highlight AFTER reload; any later reload
        // (accept, toggle, next open) must clear it so it never sticks.
        let model = try makeHighlightModel()
        model.highlight(taskID: "t_new")
        model.reload()
        XCTAssertNil(model.highlightedTaskID)
    }

    func testHighlightLeftoverAutoExpandsCollapsedSection() throws {
        let model = try makeHighlightModel()
        model.setCollapsed(true)
        XCTAssertTrue(model.leftoversCollapsed)

        model.highlight(taskID: "t_old")

        XCTAssertFalse(model.leftoversCollapsed,
                       "a highlighted leftover must be visible — collapsed section auto-expands")
        XCTAssertEqual(model.highlightedTaskID, "t_old")
    }

    func testHighlightTodayTaskLeavesCollapseStateAlone() throws {
        let model = try makeHighlightModel()
        model.setCollapsed(true)

        model.highlight(taskID: "t_new")

        XCTAssertTrue(model.leftoversCollapsed,
                      "highlighting a today task must not touch the leftovers collapse state")
        XCTAssertEqual(model.highlightedTaskID, "t_new")
    }

    func testClearHighlightNilsID() throws {
        let model = try makeHighlightModel()
        model.highlight(taskID: "t_new")
        model.clearHighlight()
        XCTAssertNil(model.highlightedTaskID)
    }

    func testHighlightUnknownIDStillSets() throws {
        // Harmless by design: the view simply finds no row to scroll to, and the
        // next reload clears the id.
        let model = try makeHighlightModel()
        model.highlight(taskID: "t_ghost")
        XCTAssertEqual(model.highlightedTaskID, "t_ghost")
        XCTAssertFalse(model.leftoversCollapsed, "an unknown id never flips collapse state")
    }

    // MARK: - Highlight fade race (review WR-04)

    func testStaleFadeTimerCannotClearNewerHighlight() throws {
        // Two overlapping triggers: the FIRST trigger's 1.5 s timer fires after
        // the SECOND highlight began — its generation-scoped clear must be a
        // no-op, leaving the newer highlight alone. Only the second trigger's
        // own timer may clear it.
        let model = try makeHighlightModel()

        model.highlight(taskID: "t_old")
        let firstGeneration = model.highlightGeneration
        model.highlight(taskID: "t_new")        // supersedes within the fade window
        let secondGeneration = model.highlightGeneration

        model.clearHighlight(ifGeneration: firstGeneration)   // stale timer fires
        XCTAssertEqual(model.highlightedTaskID, "t_new",
                       "an older trigger's timer must never wipe the newer highlight")

        model.clearHighlight(ifGeneration: secondGeneration)  // its own timer fires
        XCTAssertNil(model.highlightedTaskID,
                     "the current trigger's timer still clears exactly once")
    }

    func testEveryHighlightTriggerMintsANewGeneration() throws {
        let model = try makeHighlightModel()
        let before = model.highlightGeneration
        model.highlight(taskID: "t_new")
        let first = model.highlightGeneration
        model.highlight(taskID: "t_new")        // same id — still a NEW trigger
        let second = model.highlightGeneration

        XCTAssertNotEqual(before, first)
        XCTAssertNotEqual(first, second,
                          "re-highlighting the same task is a new trigger with its own token")
    }
}
