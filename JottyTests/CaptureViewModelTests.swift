import XCTest
@testable import Jotty

@MainActor
final class CaptureViewModelTests: XCTestCase {
    var folder: URL!
    var draftURL: URL!
    var store: Store!

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
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { Date() })
        vm.text = "in progress"
        try await Task.sleep(nanoseconds: 50_000_000)   // allow autosave debounce
        let saved = try String(contentsOf: draftURL, encoding: .utf8)
        XCTAssertEqual(saved, "in progress")
    }

    func testNewVMRestoresDraft() throws {
        try "leftover".write(to: draftURL, atomically: true, encoding: .utf8)
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { Date() })
        XCTAssertEqual(vm.text, "leftover")
    }

    func testSubmitWritesNoteAndClearsDraft() throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { now })
        vm.text = "hello"
        try vm.submit()

        XCTAssertEqual(vm.text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("hello"))
    }

    func testSubmitDoesNothingForEmptyText() throws {
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { Date() })
        vm.text = "   "
        try vm.submit()
        // No file written.
        let dayFile = DailyFile.url(in: folder, on: Date(), timezone: .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile.path))
    }

    func testSubmitCancelsPendingAutosave() async throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { now })
        vm.text = "should not persist as draft"
        // Submit immediately while the 30ms autosave debounce is still pending.
        try vm.submit()
        // Wait well past the debounce window so any in-flight task would have fired by now.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "Draft must not exist after submit, even if autosave was pending")
    }

    func testSubmitSplitsTasksAndNote() throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { now })
        vm.text = """
        quick brain-dump
        - [ ] call mom
        - [ ] renew domain
        follow-up: check prod logs after lunch
        """
        try vm.submit()

        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] call mom"))
        XCTAssertTrue(body.contains("- [ ] renew domain"))
        XCTAssertTrue(body.contains("quick brain-dump"))
        XCTAssertTrue(body.contains("follow-up: check prod logs after lunch"))
        XCTAssertFalse(body.contains("- [ ] call mom <!-- id:t_") == false)
    }

    func testSubmitOnlyTasksWritesNoNote() throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { now })
        vm.text = """
        - [ ] one
        - [ ] two
        """
        try vm.submit()
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] one"))
        XCTAssertTrue(body.contains("- [ ] two"))
        XCTAssertFalse(body.contains("### "))
    }

    func testSubmitOnlyNoteWritesNoTasks() throws {
        let now = Date()
        let vm = CaptureViewModel(store: store, draftURL: draftURL, clock: { now })
        vm.text = "just a note, no tasks"
        try vm.submit()
        let dayFile = DailyFile.url(in: folder, on: now, timezone: .current)
        let body = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertTrue(body.contains("just a note"))
        XCTAssertFalse(body.contains("- [ ]"))
        XCTAssertFalse(body.contains("- [x]"))
    }
}
