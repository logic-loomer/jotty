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
}
