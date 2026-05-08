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
}
