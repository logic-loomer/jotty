import XCTest
@testable import Jotty

/// A fallback provider whose extraction BLOCKS until `release()`. Lets a test hold
/// the VM in `isExtracting` while it drives ⌘↩/⌫ against the in-flight fallback
/// (Cluster-2 WR: in-flight Apple FM fallback must not be raced by a Review action).
actor GatedAIProvider: AIProvider {
    private let result: ExtractionResult
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    init(result: ExtractionResult) { self.result = result }

    func extractTasks(from text: String, now: Date, timezone: TimeZone) async throws -> ExtractionResult {
        if !releaseRequested {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.continuation = c
            }
        }
        return result
    }

    func release() {
        releaseRequested = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class CaptureViewModelTests: XCTestCase {
    var folder: URL!
    var draftURL: URL!
    var store: Store!

    /// No-op provider for tests. Returns empty ExtractionResult (AI path leads to empty review).
    private func makeNoOpProvider() -> MockAIProvider {
        MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "")))
    }

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        draftURL = folder.appendingPathComponent("draft.txt")
        store = Store(folder: folder, timezone: .current)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    func testDraftPersistsOnTextChange() async throws {
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.text = "in progress"
        // IN-08: poll instead of a fixed sleep — the 30ms debounce plus CI
        // scheduler load made a hard 50ms wait a flake magnet.
        try await waitUntil {
            (try? String(contentsOf: self.draftURL, encoding: .utf8)) == "in progress"
        }
        let saved = try String(contentsOf: draftURL, encoding: .utf8)
        XCTAssertEqual(saved, "in progress")
    }

    func testNewVMRestoresDraft() throws {
        try "leftover".write(to: draftURL, atomically: true, encoding: .utf8)
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        XCTAssertEqual(vm.text, "leftover")
    }

    // Plain prose goes through AI path → review state. Commit to write to disk.
    func testSubmitWritesNoteAndClearsDraft() async throws {
        let now = Date()
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "hello")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "hello"
        await vm.submitAndWait()

        // AI path yields review state; commit it.
        if case .review = vm.state {
            vm.commitFromReview()
        }

        XCTAssertEqual(vm.text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("hello"))
    }

    func testSubmitDoesNothingForEmptyText() async throws {
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.text = "   "
        await vm.submitAndWait()
        // No file written.
        let dayFile = DailyFile.url(in: folder, on: Date(), timezone: .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile.path))
    }

    // Plain prose → AI path → review; commit clears draft.
    func testSubmitCancelsPendingAutosave() async throws {
        let now = Date()
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "should not persist as draft")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "should not persist as draft"
        // Submit immediately while the 30ms autosave debounce is still pending.
        await vm.submitAndWait()
        // Commit the review to clear the draft.
        if case .review = vm.state {
            vm.commitFromReview()
        }
        // Wait well past the debounce window so any in-flight task would have fired by now.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "Draft must not exist after submit and commit, even if autosave was pending")
    }

    // Mixed input (tasks + prose): manual `- [ ] ` lines parse directly,
    // remaining prose goes through AI; both meet in the Review state.
    func testSubmitSplitsTasksAndNote() async throws {
        let now = Date()
        // Mock returns the prose as noteBody so the test can assert on it after commit.
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(
            tasks: [],
            noteBody: "quick brain-dump\nfollow-up: check prod logs after lunch"
        )))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = """
        quick brain-dump
        - [ ] call mom
        - [ ] renew domain
        follow-up: check prod logs after lunch
        """
        await vm.submitAndWait()
        // Per-line routing: mixed input → Review state with manual tasks + AI noteBody.
        guard case .review(let tasks, _, _) = vm.state else {
            return XCTFail("expected Review state, got \(vm.state)")
        }
        XCTAssertEqual(tasks.count, 2, "expected 2 manual tasks in review")
        XCTAssertTrue(tasks.contains { $0.title == "call mom" })
        XCTAssertTrue(tasks.contains { $0.title == "renew domain" })
        vm.commitFromReview()

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] call mom"))
        XCTAssertTrue(body.contains("- [ ] renew domain"))
        XCTAssertTrue(body.contains("quick brain-dump"))
        XCTAssertTrue(body.contains("follow-up: check prod logs after lunch"))
    }

    // Only task lines → manual path.
    func testSubmitOnlyTasksWritesNoNote() async throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { now })
        vm.text = """
        - [ ] one
        - [ ] two
        """
        await vm.submitAndWait()
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] one"))
        XCTAssertTrue(body.contains("- [ ] two"))
        XCTAssertFalse(body.contains("### "))
    }

    // Plain note (no tasks) → AI path → review → commit.
    func testSubmitOnlyNoteWritesNoTasks() async throws {
        let now = Date()
        let inputText = "just a note, no tasks"
        // Provider returns the raw text as noteBody (simulating the AI passing it through).
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: inputText)))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = inputText
        await vm.submitAndWait()
        // AI path → enters review with noteBody from mock.
        if case .review = vm.state {
            vm.commitFromReview()
        }
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("just a note"))
        XCTAssertFalse(body.contains("- [ ]"))
        XCTAssertFalse(body.contains("- [x]"))
    }

    // MARK: - Calendar commit path (Phase 5, plan 05-05)

    /// Fixed Australia/Sydney wall-clock instant (matches the tz-pinned idiom elsewhere).
    private func dateFor(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// Drives the AI path so an ExtractedTask (optionally time-blocked) lands in review.
    private func makeVMInReview(
        with task: ExtractedTask,
        calendar: FakeCalendarService?,
        now: Date
    ) async -> CaptureViewModel {
        await makeVMInReview(withTasks: [task], calendar: calendar, now: now)
    }

    /// Multi-task variant: lands several ExtractedTasks (all accepted) in review.
    private func makeVMInReview(
        withTasks tasks: [ExtractedTask],
        calendar: FakeCalendarService?,
        now: Date
    ) async -> CaptureViewModel {
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: tasks, noteBody: "")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: mock, calendar: calendar, clock: { now })
        vm.text = "anything (prose routed to AI)"
        await vm.submitAndWait()
        return vm
    }

    // SC1: time-blocked commit, authorized + no overlaps → createEvent once + cal_event written.
    func testTimeBlockedCommitCreatesEventAndWritesCalEventID() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                           end: dateFor("2026-06-13T10:00:00+10:00"))
        let fake = FakeCalendarService()
        let vm = await makeVMInReview(with: ExtractedTask(title: "**Standup**", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertEqual(fake.createdEvents.count, 1, "createEvent must be called exactly once")
        XCTAssertEqual(fake.createdEvents.first?.title, "Standup", "title must be sanitized")
        XCTAssertEqual(fake.createdEvents.first?.start, tb.start)
        XCTAssertEqual(fake.createdEvents.first?.end, tb.end)

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "**Standup**" }))
        XCTAssertEqual(task.calEventID, "fake-event-1", "cal_event:<id> must be written back")
    }

    // SC1: a task WITHOUT a timeBlock → createEvent NOT called, no cal_event.
    func testNonTimeBlockedCommitDoesNotCreateEvent() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let fake = FakeCalendarService()
        let vm = await makeVMInReview(with: ExtractedTask(title: "buy milk"),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertTrue(fake.createdEvents.isEmpty, "no timeBlock → no event")
        XCTAssertFalse(fake.calls.contains(.createEvent))
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "buy milk" }))
        XCTAssertNil(task.calEventID)
    }

    // Graceful degradation: createEvent throws → task still committed, no cal_event, notice set.
    func testCreateEventFailureKeepsMarkdownAndDoesNotBlock() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T11:00:00+10:00"),
                           end: dateFor("2026-06-13T12:00:00+10:00"))
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "calendar save failed")
        let vm = await makeVMInReview(with: ExtractedTask(title: "deep work", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        // Disk wins: the task is on disk despite the calendar failure.
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "deep work" }))
        XCTAssertNil(task.calEventID, "no cal_event on write failure")
        XCTAssertEqual(vm.calendarNotice, .writeFailed(message: "calendar save failed"))
        // Capture is unblocked (returned to input, draft cleared).
        if case .input = vm.state {} else { XCTFail("commit must not leave us stuck in review") }
    }

    // WR-01: multiple write failures accumulate into one count, not last-writer-wins.
    func testMultipleWriteFailuresReportAggregateCount() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let t1 = ExtractedTask(title: "task one",
                               timeBlock: TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                                                    end: dateFor("2026-06-13T10:00:00+10:00")),
                               calendarBlock: true)
        let t2 = ExtractedTask(title: "task two",
                               timeBlock: TimeBlock(start: dateFor("2026-06-13T11:00:00+10:00"),
                                                    end: dateFor("2026-06-13T12:00:00+10:00")),
                               calendarBlock: true)
        let t3 = ExtractedTask(title: "task three",
                               timeBlock: TimeBlock(start: dateFor("2026-06-13T13:00:00+10:00"),
                                                    end: dateFor("2026-06-13T14:00:00+10:00")),
                               calendarBlock: true)
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "save failed")   // every createEvent fails
        let vm = await makeVMInReview(withTasks: [t1, t2, t3], calendar: fake, now: now)
        await vm.commitAndWait()

        // All three still committed to disk (disk wins), none with a cal_event.
        let doc = try store.readDoc(on: now)
        for title in ["task one", "task two", "task three"] {
            XCTAssertNil(try XCTUnwrap(doc.tasks.first { $0.text == title }).calEventID)
        }
        // The notice reports ALL failures, not just the last one.
        XCTAssertEqual(vm.calendarNotice, .writeFailed(message: "3 events couldn't be created"))
    }

    // WR-01: a single failure still keeps its exact underlying message (no regression).
    func testSingleWriteFailureKeepsExactMessage() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                           end: dateFor("2026-06-13T10:00:00+10:00"))
        let fake = FakeCalendarService()
        fake.errorToThrow = .underlying(message: "calendar save failed")
        let vm = await makeVMInReview(with: ExtractedTask(title: "solo", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()
        XCTAssertEqual(vm.calendarNotice, .writeFailed(message: "calendar save failed"))
    }

    // Graceful degradation: access denied → commit proceeds, no createEvent, degraded notice.
    func testDeniedAccessCommitsWithoutEventAndDegrades() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T13:00:00+10:00"),
                           end: dateFor("2026-06-13T14:00:00+10:00"))
        let fake = FakeCalendarService()
        fake.accessToReturn = .denied
        let vm = await makeVMInReview(with: ExtractedTask(title: "lunch block", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertTrue(fake.createdEvents.isEmpty, "denied access → no event")
        XCTAssertFalse(fake.calls.contains(.requestAccess), "denied is terminal; no re-request")
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "lunch block" }))
        XCTAssertNil(task.calEventID)
        XCTAssertEqual(vm.calendarNotice, .accessDenied)
    }

    // notDetermined → requestAccess is invoked lazily exactly once on first calendar action.
    func testNotDeterminedRequestsAccessLazily() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T15:00:00+10:00"),
                           end: dateFor("2026-06-13T16:00:00+10:00"))
        let fake = FakeCalendarService()
        fake.accessToReturn = .notDetermined   // requestAccess() also returns .notDetermined → !authorized
        let vm = await makeVMInReview(with: ExtractedTask(title: "review PR", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertEqual(fake.requestAccessCallCount, 1, "must lazily request once")
        XCTAssertTrue(fake.createdEvents.isEmpty, "not granted → no event")
        XCTAssertEqual(vm.calendarNotice, .accessDenied)
    }

    // Back-compat: no CalendarService injected → behaves exactly as before (no calendar touch).
    func testNoCalendarInjectedPreservesExistingBehavior() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T17:00:00+10:00"),
                           end: dateFor("2026-06-13T18:00:00+10:00"))
        // calendar: nil (default).
        let vm = await makeVMInReview(with: ExtractedTask(title: "gym", timeBlock: tb, calendarBlock: true),
                                      calendar: nil, now: now)
        await vm.commitAndWait()

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "gym" }))
        XCTAssertNil(task.calEventID, "no calendar → no cal_event")
        XCTAssertNil(vm.calendarNotice)
    }

    // MARK: - Per-row calendar toggle (UX-06, plan 07.1-09)

    // UX-06: enterReview seeds the toggle set from each task's calendarBlock —
    // a row starts ON iff the AI flagged it for calendar blocking.
    func testEnterReviewSeedsCalendarEnabledRowIDsFromCalendarBlock() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb1 = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                            end: dateFor("2026-06-13T10:00:00+10:00"))
        let tb2 = TimeBlock(start: dateFor("2026-06-13T11:00:00+10:00"),
                            end: dateFor("2026-06-13T12:00:00+10:00"))
        let tasks = [
            ExtractedTask(title: "blocked one", timeBlock: tb1, calendarBlock: true),
            ExtractedTask(title: "plain task"),
            ExtractedTask(title: "blocked two", timeBlock: tb2, calendarBlock: true),
        ]
        let vm = await makeVMInReview(withTasks: tasks, calendar: FakeCalendarService(), now: now)
        XCTAssertEqual(vm.calendarEnabledRowIDs, [0, 2],
                       "rows seed ON iff their task's calendarBlock is true")
    }

    // UX-06: toggled OFF → the time-blocked task still commits WITH its timeBlock,
    // but the calendar service is never asked to create an event.
    func testCalendarToggleOffCommitsTimeBlockWithoutEvent() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                           end: dateFor("2026-06-13T10:00:00+10:00"))
        let fake = FakeCalendarService()
        let vm = await makeVMInReview(
            with: ExtractedTask(title: "quiet block", timeBlock: tb, calendarBlock: true),
            calendar: fake, now: now)
        vm.toggleCalendarRow(0)   // user opts this row out of calendar creation
        XCTAssertFalse(vm.calendarEnabledRowIDs.contains(0))
        await vm.commitAndWait()

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "quiet block" }))
        XCTAssertEqual(task.timeBlock, tb, "toggled-off commit keeps the time block")
        XCTAssertNil(task.calEventID, "toggled-off commit writes no cal_event")
        XCTAssertTrue(fake.createdEvents.isEmpty, "toggle OFF → zero events created")
        XCTAssertFalse(fake.calls.contains(.createEvent))
    }

    // UX-06: toggled ON (the seeded default for AI time-blocked tasks) → exactly
    // one event is created, as before the toggle existed.
    func testCalendarToggleOnCreatesExactlyOneEvent() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                           end: dateFor("2026-06-13T10:00:00+10:00"))
        let fake = FakeCalendarService()
        let vm = await makeVMInReview(
            with: ExtractedTask(title: "loud block", timeBlock: tb, calendarBlock: true),
            calendar: fake, now: now)
        XCTAssertTrue(vm.calendarEnabledRowIDs.contains(0), "seeded ON from calendarBlock")
        await vm.commitAndWait()

        XCTAssertEqual(fake.createdEvents.count, 1, "toggle ON → exactly one event")
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "loud block" }))
        XCTAssertEqual(task.calEventID, "fake-event-1")
    }

    // MARK: - Review edit-in-place rename (UX-10, plan 07.1-11)

    // UX-10: rename rewrites ONLY the target row's title; every other field on that
    // row (dueDate, timeBlock, calendarBlock) and every other row carry over intact.
    func testRenameReviewRowChangesOnlyTargetTitle() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let due = dateFor("2026-06-14T00:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                           end: dateFor("2026-06-13T10:00:00+10:00"))
        let original = [
            ExtractedTask(title: "blocked one", dueDate: due, timeBlock: tb, calendarBlock: true),
            ExtractedTask(title: "plain task"),
        ]
        let vm = await makeVMInReview(withTasks: original, calendar: nil, now: now)
        vm.renameReviewRow(0, title: "renamed block")

        guard case .review(let tasks, _, _) = vm.state else {
            return XCTFail("expected Review state, got \(vm.state)")
        }
        XCTAssertEqual(tasks[0].title, "renamed block")
        XCTAssertEqual(tasks[0].dueDate, due, "dueDate must carry over")
        XCTAssertEqual(tasks[0].timeBlock, tb, "timeBlock must carry over")
        XCTAssertTrue(tasks[0].calendarBlock, "calendarBlock must carry over")
        XCTAssertEqual(tasks[1], original[1], "untouched rows are identical")
    }

    // UX-10 / Pitfall 6: a row the user UNchecked stays unchecked across a rename —
    // renameReviewRow must never route through enterReview (which re-checks all rows).
    func testRenamePreservesUncheckedAcceptedRows() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tasks = [
            ExtractedTask(title: "keep me"),
            ExtractedTask(title: "unchecked row"),
            ExtractedTask(title: "rename me"),
        ]
        let vm = await makeVMInReview(withTasks: tasks, calendar: nil, now: now)
        vm.toggleRow(1)   // user unchecks row 1
        XCTAssertEqual(vm.acceptedRowIDs, [0, 2])

        vm.renameReviewRow(2, title: "renamed")

        XCTAssertEqual(vm.acceptedRowIDs, [0, 2],
                       "rename must not reset the accepted set (Pitfall 6)")
    }

    // UX-10: calendarEnabledRowIDs (plan 07.1-09) is a separate published property —
    // a rename's state reassignment must leave the user's calendar toggles untouched.
    func testRenamePreservesCalendarEnabledRowIDs() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb1 = TimeBlock(start: dateFor("2026-06-13T09:00:00+10:00"),
                            end: dateFor("2026-06-13T10:00:00+10:00"))
        let tb2 = TimeBlock(start: dateFor("2026-06-13T11:00:00+10:00"),
                            end: dateFor("2026-06-13T12:00:00+10:00"))
        let tasks = [
            ExtractedTask(title: "blocked one", timeBlock: tb1, calendarBlock: true),
            ExtractedTask(title: "blocked two", timeBlock: tb2, calendarBlock: true),
        ]
        let vm = await makeVMInReview(withTasks: tasks, calendar: FakeCalendarService(), now: now)
        vm.toggleCalendarRow(1)   // user opts row 1 out of calendar creation
        XCTAssertEqual(vm.calendarEnabledRowIDs, [0])

        vm.renameReviewRow(0, title: "renamed block")

        XCTAssertEqual(vm.calendarEnabledRowIDs, [0],
                       "rename must not re-seed the calendar toggles")
    }

    // UX-10: whitespace-only titles revert — nothing changes (menubar empty-after-trim rule).
    func testRenameWithWhitespaceOnlyTitleIsNoOp() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let vm = await makeVMInReview(with: ExtractedTask(title: "original"),
                                      calendar: nil, now: now)
        vm.renameReviewRow(0, title: "   \n  ")

        guard case .review(let tasks, _, _) = vm.state else {
            return XCTFail("expected Review state, got \(vm.state)")
        }
        XCTAssertEqual(tasks[0].title, "original", "whitespace-only rename reverts")
    }

    // UX-10: an out-of-bounds index is a safe no-op (nothing mutates, nothing crashes).
    func testRenameWithOutOfBoundsIndexIsNoOp() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let vm = await makeVMInReview(with: ExtractedTask(title: "only row"),
                                      calendar: nil, now: now)
        vm.renameReviewRow(5, title: "ghost")
        vm.renameReviewRow(-1, title: "ghost")

        guard case .review(let tasks, _, _) = vm.state else {
            return XCTFail("expected Review state, got \(vm.state)")
        }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "only row", "out-of-bounds rename is a no-op")
    }

    // MARK: - Conflict gate (SC5, plan 05-05 task 2)

    private func cannedEvent(_ title: String, _ startISO: String, _ endISO: String) -> CalendarEvent {
        CalendarEvent(id: "existing-\(title)", title: title,
                      start: dateFor(startISO), end: dateFor(endISO), calendarTitle: "Work")
    }

    // Overlap surfaces a conflict carrying the existing event's title BEFORE createEvent.
    func testOverlapSurfacesConflictBeforeCreate() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()
        // Spin until the conflict is published (the calendar task suspends on it).
        try await waitUntil { vm.pendingConflict != nil }

        XCTAssertEqual(vm.pendingConflict?.conflictTitle, "Existing Standup")
        XCTAssertTrue(fake.createdEvents.isEmpty, "must not create before the user confirms")

        vm.resolveConflict(commitAnyway: false)   // tidy up the awaiting task
        await vm.awaitCalendarWork()
    }

    // Confirm → createEvent IS called, cal_event written, task committed.
    func testConflictConfirmCommitsBoth() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()
        try await waitUntil { vm.pendingConflict != nil }
        vm.resolveConflict(commitAnyway: true)
        await vm.awaitCalendarWork()

        XCTAssertEqual(fake.createdEvents.count, 1, "confirm must create the event")
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "Planning" }))
        XCTAssertEqual(task.calEventID, "fake-event-1")
        XCTAssertNil(vm.pendingConflict, "conflict state clears after decision")
    }

    // Cancel → createEvent NOT called and the task is ABSENT from markdown (uncommitted).
    func testConflictCancelLeavesTaskUncommitted() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()
        try await waitUntil { vm.pendingConflict != nil }
        vm.resolveConflict(commitAnyway: false)
        await vm.awaitCalendarWork()

        XCTAssertTrue(fake.createdEvents.isEmpty, "cancel must not create")
        let doc = try store.readDoc(on: now)
        XCTAssertFalse(doc.tasks.contains(where: { $0.text == "Planning" }),
                       "cancelled time-blocked task must be absent from markdown")
    }

    // No overlap → no conflict surfaced, commits silently with an event.
    func testNoOverlapCommitsSilently() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T14:00:00+10:00"),
                           end: dateFor("2026-06-13T15:00:00+10:00"))
        let fake = FakeCalendarService()
        // Canned event is in the morning; the task is in the afternoon → no overlap.
        fake.cannedEvents = []   // overlappingEvents returns [] (FakeCalendarService returns canned)
        let vm = await makeVMInReview(with: ExtractedTask(title: "afternoon focus", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertNil(vm.pendingConflict, "no overlap → no conflict")
        XCTAssertEqual(fake.createdEvents.count, 1)
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "afternoon focus" }))
        XCTAssertEqual(task.calEventID, "fake-event-1")
    }

    // MARK: - Continuation teardown on window close (CQ-02, plan 07.1-05)

    // Window close with a conflict prompt PENDING: teardown() resumes the suspended
    // calendar pass with cancel — awaitCalendarWork() must return (not hang) and the
    // time-blocked task must stay uncommitted (the continuation must not leak).
    func testTeardownWithPendingConflictResumesCancelAndLeavesTaskUncommitted() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()
        try await waitUntil { vm.pendingConflict != nil }

        vm.teardown()                    // window going away with the prompt showing
        await vm.awaitCalendarWork()     // must complete — continuation resumed with cancel

        XCTAssertNil(vm.pendingConflict, "teardown must clear the pending conflict")
        XCTAssertTrue(fake.createdEvents.isEmpty, "cancel default must not create an event")
        let doc = try store.readDoc(on: now)
        XCTAssertFalse(doc.tasks.contains(where: { $0.text == "Planning" }),
                       "cancelled time-blocked task must be absent from markdown")
    }

    // User-initiated close (Esc / red button) racing the calendar pass: teardown()
    // can fire BEFORE the pass raises its conflict. A conflict raised after teardown
    // auto-cancels (no UI exists to resolve it) instead of suspending forever.
    // NOTE (CR-01): the NORMAL commit flow can no longer reach this leg — dismissal
    // is deferred until the calendar pass resolves (see the regression test below) —
    // so this covers only a genuine user-close while the pass is in flight, where
    // cancel remains the safe default for a truly-closed window.
    func testConflictRaisedAfterTeardownAutoCancels() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()
        vm.teardown()                    // window closed post-commit, before the pass ran
        await vm.awaitCalendarWork()     // must complete — conflict auto-cancels

        XCTAssertNil(vm.pendingConflict, "no prompt may surface after teardown")
        XCTAssertTrue(fake.createdEvents.isEmpty, "auto-cancel must not create an event")
        let doc = try store.readDoc(on: now)
        XCTAssertFalse(doc.tasks.contains(where: { $0.text == "Planning" }),
                       "conflicted task raised after close must stay uncommitted")
    }

    // CR-01 regression: the commit-path dismissal must WAIT for the calendar pass.
    // A conflicted, user-accepted time-blocked task surfaces its prompt while the
    // window is still owned by the VM (dismissRequested stays false), and confirming
    // commits the task. The old design armed a 0.6s close BEFORE the pass ran, so the
    // window closed over the prompt and teardown silently dropped the accepted task.
    func testCommitDismissalDefersUntilConflictResolvedAndTaskSurvives() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T09:30:00+10:00"),
                           end: dateFor("2026-06-13T10:30:00+10:00"))
        let fake = FakeCalendarService()
        fake.cannedEvents = [cannedEvent("Existing Standup",
                                         "2026-06-13T09:00:00+10:00",
                                         "2026-06-13T10:00:00+10:00")]
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb, calendarBlock: true),
                                      calendar: fake, now: now)
        vm.commitFromReview()

        XCTAssertTrue(vm.showSavedConfirmation, "the synchronous commit still confirms")
        XCTAssertFalse(vm.dismissRequested,
                       "dismissal must NOT be requested while the calendar pass is pending (CR-01)")

        try await waitUntil { vm.pendingConflict != nil }
        XCTAssertFalse(vm.dismissRequested,
                       "a pending conflict owns the window — no dismissal may be armed")

        vm.resolveConflict(commitAnyway: true)   // the user accepts the overlap
        await vm.awaitCalendarWork()

        XCTAssertTrue(vm.dismissRequested,
                      "dismissal resumes once the calendar pass has fully resolved")
        XCTAssertEqual(fake.createdEvents.count, 1, "confirm must create the event")
        let doc = try store.readDoc(on: now)
        XCTAssertTrue(doc.tasks.contains(where: { $0.text == "Planning" }),
                      "the user-accepted conflicted task must survive the commit (CR-01)")
    }

    // CR-01 companion: with NO conflict (and no calendar work at all) the dismissal
    // still fires promptly — deferral applies only while calendar work is in flight.
    func testCommitDismissalFiresImmediatelyWithoutCalendarWork() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let vm = await makeVMInReview(with: ExtractedTask(title: "plain task"),
                                      calendar: nil, now: now)
        vm.commitFromReview()
        XCTAssertTrue(vm.dismissRequested,
                      "no calendar pass → dismissal is requested synchronously")
    }

    // MARK: - Manual fast-path saved signal + draft-restored affordance (UX-03/UX-08, plan 07.1-06)

    // UX-03: pure-manual capture commits synchronously and must signal success so
    // the view can show "Saved" and close the window (same feel as the prose path).
    func testManualFastPathSignalsSavedAndRequestsDismissal() throws {
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.text = "- [ ] call mom"
        vm.submit()   // pure-manual fast path is synchronous
        XCTAssertTrue(vm.showSavedConfirmation, "successful manual commit must show Saved")
        XCTAssertTrue(vm.dismissRequested, "successful manual commit must request window dismissal")
        XCTAssertEqual(vm.text, "")
        XCTAssertNil(vm.lastError)
    }

    // UX-03: a manual commit that FAILS to write must not claim success.
    func testFailedManualSubmitDoesNotSignalSaved() throws {
        // A parent path that is a regular FILE makes Store.appendCapture's
        // createDirectory(withIntermediateDirectories:) throw.
        let blocker = folder.appendingPathComponent("blocker")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let badStore = Store(folder: blocker.appendingPathComponent("sub"), timezone: .current)
        let vm = CaptureViewModel(store: badStore, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.text = "- [ ] doomed"
        vm.submit()
        XCTAssertNotNil(vm.lastError, "disk failure must surface as lastError")
        XCTAssertFalse(vm.showSavedConfirmation, "failed commit must not show Saved")
        XCTAssertFalse(vm.dismissRequested, "failed commit must not dismiss the window")
    }

    // UX-03: prose input routes to review — no Saved signal until the review commits.
    func testProseSubmitSignalsSavedOnlyAfterReviewCommit() async throws {
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "a note")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { Date() })
        vm.text = "a note"
        await vm.submitAndWait()
        XCTAssertFalse(vm.showSavedConfirmation, "entering review must not claim Saved yet")
        XCTAssertFalse(vm.dismissRequested)
        vm.commitFromReview()
        XCTAssertTrue(vm.showSavedConfirmation, "review commit is the other Saved path")
        XCTAssertTrue(vm.dismissRequested)
    }

    // UX-08: restoring a non-empty draft is announced.
    func testInitWithSavedDraftSetsDraftWasRestored() throws {
        try "leftover".write(to: draftURL, atomically: true, encoding: .utf8)
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        XCTAssertTrue(vm.draftWasRestored)
        XCTAssertEqual(vm.text, "leftover")
    }

    // UX-08: no draft on disk → no announcement.
    func testInitWithoutDraftLeavesDraftWasRestoredFalse() {
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        XCTAssertFalse(vm.draftWasRestored)
    }

    // UX-08: Clear empties the editor, resets the flag, and removes the on-disk
    // draft so a relaunch cannot resurrect what the user explicitly discarded.
    func testClearRestoredDraftEmptiesTextAndResetsFlag() async throws {
        try "leftover".write(to: draftURL, atomically: true, encoding: .utf8)
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.clearRestoredDraft()
        XCTAssertEqual(vm.text, "")
        XCTAssertFalse(vm.draftWasRestored)
        // Wait past the autosave debounce: the cancelled write must not recreate the file.
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
    }

    // UX-08: editing the restored draft down to nothing also clears the flag.
    func testEditingTextToEmptyClearsDraftWasRestored() throws {
        try "leftover".write(to: draftURL, atomically: true, encoding: .utf8)
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: makeNoOpProvider(), clock: { Date() })
        vm.text = ""
        XCTAssertFalse(vm.draftWasRestored)
    }

    // MARK: - Cluster-2 WR: in-flight Apple FM fallback must not be raced (CaptureViewModel:377)

    // A ⌘↩/⌫ arriving while an extraction is in flight must be swallowed — neither
    // commitFromReview() nor returnToInput() may act while `isExtracting` is true.
    func testCommitAndReturnToInputAreNoOpsWhileExtracting() async throws {
        let now = Date()
        let vm = await makeVMInReview(with: ExtractedTask(title: "pending"), calendar: nil, now: now)
        guard case .review = vm.state else { return XCTFail("expected review") }
        vm.isExtracting = true   // simulate an in-flight fallback extraction

        vm.commitFromReview()
        XCTAssertFalse(vm.showSavedConfirmation, "commit must be ignored while extracting")
        XCTAssertFalse(vm.dismissRequested)
        if case .review = vm.state {} else { XCTFail("commit must not leave review while extracting") }

        vm.returnToInput()
        if case .review = vm.state {} else { XCTFail("returnToInput must be ignored while extracting") }

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile.path),
                       "a swallowed commit must not touch disk")
    }

    // Integration: a real in-flight fallback. ⌘↩ mid-await is ignored, the fallback's
    // tasks land in Review (not dropped), and the prose is appended exactly once (no
    // double-commit) on the subsequent genuine commit.
    func testInFlightFallbackIgnoresCommitAndLandsTasksExactlyOnce() async throws {
        let now = Date()
        let primary = MockAIProvider(mode: .throwError(.guardrail(message: nil)))
        let fallback = GatedAIProvider(result: ExtractionResult(
            tasks: [ExtractedTask(title: "recovered task")], noteBody: "prose note"))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary, fallbackProvider: fallback, clock: { now })
        vm.text = "prose note"
        await vm.submitAndWait()
        // Primary failed → degraded review holding the raw prose.
        XCTAssertEqual(vm.lastError, .guardrail(message: nil))
        guard case .review = vm.state else { return XCTFail("expected degraded review") }

        // Kick the fallback; it blocks inside the provider mid-extraction.
        let retry = Task { await vm.retryWithAppleFM() }
        try await waitUntil { vm.isExtracting }

        // ⌘↩ and ⌫ mid-await must be ignored (guard !isExtracting).
        vm.commitFromReview()
        vm.returnToInput()
        XCTAssertFalse(vm.showSavedConfirmation, "⌘↩ during fallback must not commit")
        XCTAssertFalse(vm.dismissRequested)
        XCTAssertTrue(vm.isExtracting, "still extracting; the Review action was swallowed")

        // Release the fallback; its tasks must land in review, not be dropped.
        await fallback.release()
        await retry.value

        guard case .review(let tasks, let noteBody, _) = vm.state else {
            return XCTFail("fallback result must land in review")
        }
        XCTAssertEqual(tasks.map(\.title), ["recovered task"], "fallback tasks must survive")
        XCTAssertEqual(noteBody, "prose note")
        XCTAssertNil(vm.lastError, "successful fallback clears the error")

        // A real commit now writes the prose exactly once (no double-append).
        vm.commitFromReview()
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertEqual(body.components(separatedBy: "prose note").count - 1, 1,
                       "prose note must be appended exactly once")
    }

    // MARK: - Cluster-2 WR: commit-time disk failure surfaces an honest save-failure (ReviewListView:34)

    // A failed appendCapture at commit must raise the distinct `saveError` channel with
    // honest copy — NOT `lastError` (whose Review banner falsely claims "saved as a plain
    // note"). The user stays in Review with their draft intact.
    func testCommitDiskFailureSurfacesHonestSaveErrorNotAIFallback() async throws {
        let now = Date()
        // A parent path that is a regular FILE makes Store.appendCapture's
        // createDirectory(withIntermediateDirectories:) throw at commit time.
        let blocker = folder.appendingPathComponent("blocker")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let badStore = Store(folder: blocker.appendingPathComponent("sub"), timezone: .current)
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "keep my note")))
        let vm = CaptureViewModel(store: badStore, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "keep my note"
        await vm.submitAndWait()
        guard case .review = vm.state else { return XCTFail("expected review") }

        vm.commitFromReview()

        XCTAssertNotNil(vm.saveError, "a commit-time disk failure must surface a save-failure notice")
        XCTAssertNil(vm.lastError, "a disk-save failure must NOT masquerade as an AI-extraction error")
        // Honest copy — must not claim anything was saved.
        XCTAssertFalse(vm.saveError?.lowercased().contains("saved") ?? false,
                       "save-failure copy must not falsely claim the capture was saved")
        // User stays in review with their data intact.
        if case .review = vm.state {} else { XCTFail("must stay in review on save failure") }
        XCTAssertEqual(vm.text, "keep my note", "draft text must be preserved")
        XCTAssertFalse(vm.showSavedConfirmation)
        XCTAssertFalse(vm.dismissRequested)
    }

    // MARK: - Cluster-2 INFO: manual `- [x]` mixed with prose commits as done (CaptureViewModel:169)

    func testMixedManualDoneCheckboxCommitsAsDone() async throws {
        let now = Date()
        // Prose returned as noteBody so the input is genuinely "mixed" (routes through AI).
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "brain dump line")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = """
        brain dump line
        - [x] done thing
        - [ ] open thing
        """
        await vm.submitAndWait()
        guard case .review(let tasks, _, _) = vm.state else { return XCTFail("expected review") }
        XCTAssertEqual(tasks.count, 2, "both manual lines enter review")
        vm.commitFromReview()

        let doc = try store.readDoc(on: now)
        let done = try XCTUnwrap(doc.tasks.first { $0.text == "done thing" })
        let open = try XCTUnwrap(doc.tasks.first { $0.text == "open thing" })
        XCTAssertTrue(done.done, "manual - [x] must commit as done")
        XCTAssertNotNil(done.completedAt, "a done task carries a completion time")
        XCTAssertFalse(open.done, "manual - [ ] stays open")
    }

    /// Polls `condition` on the main actor up to ~2s; fails the test if it never becomes true.
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
}
