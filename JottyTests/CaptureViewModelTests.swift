import XCTest
@testable import Jotty

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
        try await Task.sleep(nanoseconds: 50_000_000)   // allow autosave debounce
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
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [task], noteBody: "")))
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "**Standup**", timeBlock: tb),
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
        fake.errorToThrow = .underlying(message: "EKEventStore save failed")
        let vm = await makeVMInReview(with: ExtractedTask(title: "deep work", timeBlock: tb),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        // Disk wins: the task is on disk despite the calendar failure.
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "deep work" }))
        XCTAssertNil(task.calEventID, "no cal_event on write failure")
        XCTAssertEqual(vm.calendarNotice, .writeFailed(message: "EKEventStore save failed"))
        // Capture is unblocked (returned to input, draft cleared).
        if case .input = vm.state {} else { XCTFail("commit must not leave us stuck in review") }
    }

    // Graceful degradation: access denied → commit proceeds, no createEvent, degraded notice.
    func testDeniedAccessCommitsWithoutEventAndDegrades() async throws {
        let now = dateFor("2026-06-13T08:00:00+10:00")
        let tb = TimeBlock(start: dateFor("2026-06-13T13:00:00+10:00"),
                           end: dateFor("2026-06-13T14:00:00+10:00"))
        let fake = FakeCalendarService()
        fake.accessToReturn = .denied
        let vm = await makeVMInReview(with: ExtractedTask(title: "lunch block", timeBlock: tb),
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "review PR", timeBlock: tb),
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "gym", timeBlock: tb),
                                      calendar: nil, now: now)
        await vm.commitAndWait()

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "gym" }))
        XCTAssertNil(task.calEventID, "no calendar → no cal_event")
        XCTAssertNil(vm.calendarNotice)
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb),
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb),
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "Planning", timeBlock: tb),
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
        let vm = await makeVMInReview(with: ExtractedTask(title: "afternoon focus", timeBlock: tb),
                                      calendar: fake, now: now)
        await vm.commitAndWait()

        XCTAssertNil(vm.pendingConflict, "no overlap → no conflict")
        XCTAssertEqual(fake.createdEvents.count, 1)
        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first(where: { $0.text == "afternoon focus" }))
        XCTAssertEqual(task.calEventID, "fake-event-1")
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
