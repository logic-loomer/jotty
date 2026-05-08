import XCTest
@testable import Jotty

// MARK: - MockAIProvider

actor MockAIProvider: AIProvider {
    enum Mode {
        case succeed(ExtractionResult)
        case throwError(AIProviderError)
    }
    var callCount: Int = 0
    var mode: Mode

    init(mode: Mode) { self.mode = mode }

    func extractTasks(from text: String, now: Date, timezone: TimeZone) async throws -> ExtractionResult {
        callCount += 1
        switch mode {
        case .succeed(let r): return r
        case .throwError(let e): throw e
        }
    }
}

// MARK: - Tests

@MainActor
final class CaptureViewModelAIPathTests: XCTestCase {
    var folder: URL!
    var draftURL: URL!
    var store: Store!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        draftURL = folder.appendingPathComponent("draft.txt")
        store = Store(folder: folder, timezone: .current)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - testManualFallback_withDashSyntax_skipsAI

    func testManualFallback_withDashSyntax_skipsAI() async throws {
        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "")))
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "- [ ] do laundry"
        await vm.submitAndWait()
        let count = await mock.callCount
        XCTAssertEqual(count, 0, "manual syntax must bypass AI")
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let today = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(today.contains("- [ ] do laundry"))
    }

    // MARK: - testManualFallback_storeError_surfacesLastError

    func testManualFallback_storeError_surfacesLastError() async throws {
        // Point store at a read-only location to force appendCapture to throw.
        let readOnlyFolder = folder.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: true)
        // Remove write permission.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))],
            ofItemAtPath: readOnlyFolder.path
        )
        let readOnlyStore = Store(folder: readOnlyFolder, timezone: .current)

        let mock = MockAIProvider(mode: .succeed(ExtractionResult(tasks: [], noteBody: "")))
        let vm = CaptureViewModel(store: readOnlyStore, draftURL: draftURL, provider: mock, clock: { Date() })
        vm.text = "- [ ] task"
        await vm.submitAndWait()

        let count = await mock.callCount
        XCTAssertEqual(count, 0, "manual syntax must bypass AI")
        if case .underlying = vm.lastError {
            // good — error surfaced
        } else {
            XCTFail("Expected lastError to be .underlying(...), got \(String(describing: vm.lastError))")
        }
        XCTAssertEqual(vm.state, .input, "user must stay in input mode to retry")

        // Restore permissions for teardown.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: readOnlyFolder.path
        )
    }

    // MARK: - testAIPath_extractedTasksEnterReview

    func testAIPath_extractedTasksEnterReview() async throws {
        let task1 = ExtractedTask(title: "email Jamie about Q2 plan")
        let result = ExtractionResult(tasks: [task1], noteBody: "email Jamie about Q2 plan by Friday")
        let mock = MockAIProvider(mode: .succeed(result))
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { Date() })
        vm.text = "email Jamie about Q2 plan by Friday"
        await vm.submitAndWait()

        let count = await mock.callCount
        XCTAssertEqual(count, 1, "AI must be called for prose input")
        if case .review(let tasks, _, _) = vm.state {
            XCTAssertEqual(tasks.count, 1)
            XCTAssertEqual(tasks[0].title, "email Jamie about Q2 plan")
        } else {
            XCTFail("Expected review state, got \(vm.state)")
        }
    }

    // MARK: - testAIPath_commitFromReview_writesTasksAndNote

    func testAIPath_commitFromReview_writesTasksAndNote() async throws {
        let task1 = ExtractedTask(title: "email Jamie about Q2 plan")
        let noteBody = "email Jamie about Q2 plan by Friday"
        let result = ExtractionResult(tasks: [task1], noteBody: noteBody)
        let mock = MockAIProvider(mode: .succeed(result))
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = noteBody
        await vm.submitAndWait()

        // Verify we're in review.
        guard case .review = vm.state else {
            XCTFail("Expected review state"); return
        }

        vm.commitFromReview()

        XCTAssertEqual(vm.state, .input)
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let content = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(content.contains("email Jamie about Q2 plan"), "task should be in file")
        XCTAssertTrue(content.contains("source_note:n_"), "task should carry source_note link")
    }

    // MARK: - testAIPath_unselectedRow_isNotCommitted

    func testAIPath_unselectedRow_isNotCommitted() async throws {
        let tasks = [
            ExtractedTask(title: "task one"),
            ExtractedTask(title: "task two"),
            ExtractedTask(title: "task three"),
        ]
        let result = ExtractionResult(tasks: tasks, noteBody: "some input")
        let mock = MockAIProvider(mode: .succeed(result))
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "some input"
        await vm.submitAndWait()

        // Deselect row 1 (task two).
        vm.toggleRow(1)
        vm.commitFromReview()

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let content = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(content.contains("task one"))
        XCTAssertFalse(content.contains("task two"), "deselected task must not appear")
        XCTAssertTrue(content.contains("task three"))
    }

    // MARK: - testFailure_guardrail_savesAsPlainNote

    func testFailure_guardrail_savesAsPlainNote() async throws {
        let mock = MockAIProvider(mode: .throwError(.guardrail(message: nil)))
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "some prose input"
        await vm.submitAndWait()

        XCTAssertEqual(vm.lastError, .guardrail(message: nil))
        if case .review(let tasks, let noteBody, _) = vm.state {
            XCTAssertEqual(tasks.count, 0, "degraded review must have 0 tasks")
            XCTAssertEqual(noteBody, "some prose input", "raw capture must be preserved in noteBody")
        } else {
            XCTFail("Expected review state after guardrail error, got \(vm.state)")
        }

        // Committing the degraded review saves raw text as plain note.
        vm.commitFromReview()
        XCTAssertEqual(vm.state, .input)
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let content = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(content.contains("some prose input"), "raw capture must be saved as note")
    }

    // MARK: - testFailure_modelUnavailable_savesAsPlainNote

    func testFailure_modelUnavailable_savesAsPlainNote() async throws {
        let mock = MockAIProvider(mode: .throwError(.modelUnavailable(reason: "Apple Intelligence is off")))
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: mock, clock: { now })
        vm.text = "remember to call dentist"
        await vm.submitAndWait()

        XCTAssertEqual(vm.lastError, .modelUnavailable(reason: "Apple Intelligence is off"))
        if case .review(let tasks, let noteBody, _) = vm.state {
            XCTAssertEqual(tasks.count, 0)
            XCTAssertEqual(noteBody, "remember to call dentist")
        } else {
            XCTFail("Expected review state after modelUnavailable error, got \(vm.state)")
        }

        vm.commitFromReview()
        XCTAssertEqual(vm.state, .input)
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let content = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(content.contains("remember to call dentist"))
    }
}
