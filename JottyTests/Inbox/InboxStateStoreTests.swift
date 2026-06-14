import XCTest
@testable import Jotty

/// Round-trip + graceful-fallback coverage for `InboxStateStore`, the persisted
/// accepted+dismissed dedupe state behind `InboxService`. Mirrors the temp-path
/// idiom of `KeybindingsStoreTests` / `ConfigStoreTests`: every test writes under a
/// unique `temporaryDirectory` path cleaned in `tearDown`, so `inbox-state.json` is
/// never written outside the injected path (the default App Support file is untouched).
final class InboxStateStoreTests: XCTestCase {

    private var path: URL!

    override func setUp() {
        super.setUp()
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("inbox-state.json")
    }

    override func tearDown() {
        if let path { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        super.tearDown()
    }

    func testAcceptPersistsAndSurvivesReload() throws {
        let store = try InboxStateStore(path: path)
        try store.accept("github:1")
        XCTAssertTrue(store.state.accepted.contains("github:1"))

        // A fresh store at the same path reloads the persisted accepted id.
        let reloaded = try InboxStateStore(path: path)
        XCTAssertTrue(reloaded.state.accepted.contains("github:1"))
    }

    func testDismissPersistsAndSurvivesReload() throws {
        let store = try InboxStateStore(path: path)
        try store.dismiss("github:2")
        XCTAssertTrue(store.state.dismissed.contains("github:2"))

        let reloaded = try InboxStateStore(path: path)
        XCTAssertTrue(reloaded.state.dismissed.contains("github:2"))
    }

    func testMissingFileDecodesToEmptyState() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let store = try InboxStateStore(path: path)
        XCTAssertEqual(store.state, InboxState())
        XCTAssertTrue(store.state.accepted.isEmpty)
        XCTAssertTrue(store.state.dismissed.isEmpty)
    }

    func testCorruptFileDecodesToEmptyState() throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not valid json".data(using: .utf8)!.write(to: path)

        // Construction never throws on a corrupt file — it falls back to empty state.
        let store = try InboxStateStore(path: path)
        XCTAssertEqual(store.state, InboxState())
    }

    func testAcceptIsIdempotent() throws {
        let store = try InboxStateStore(path: path)
        try store.accept("github:1")
        try store.accept("github:1")
        // Set semantics: a single membership, no duplicate, no error.
        XCTAssertEqual(store.state.accepted, ["github:1"])

        let reloaded = try InboxStateStore(path: path)
        XCTAssertEqual(reloaded.state.accepted, ["github:1"])
    }
}
