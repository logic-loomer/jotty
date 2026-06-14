import XCTest
@testable import Jotty

/// Behavioral coverage for `InboxService`, the `@MainActor` coordinator: tolerant
/// fan-out (SC3 no-network-when-unconfigured + one-bad-source resilience) and
/// accept/dismiss dedupe (SC2 never-re-suggest). Every source is a `FakeInboxSource`,
/// so the suite makes zero network calls; the dedupe `InboxStateStore` writes under a
/// unique temp path cleaned in `tearDown`.
@MainActor
final class InboxServiceTests: XCTestCase {

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

    // MARK: Helpers

    private func makeStore() throws -> InboxStateStore { try InboxStateStore(path: path) }

    private func item(_ id: String, source: String = "fake", title: String = "t") -> InboxItem {
        InboxItem(id: id, sourceID: source, title: title, url: "https://x.test/\(id)",
                  timestamp: Date(timeIntervalSince1970: 0), rawText: title)
    }

    // MARK: SC3 — no network when unconfigured

    func testRefreshWithZeroSourcesMakesNoFetchAndLeavesSuggestionsEmpty() async throws {
        let service = InboxService(sources: [], state: try makeStore())
        await service.refresh()
        XCTAssertTrue(service.suggestions.isEmpty)
    }

    func testRefreshSkipsUnconfiguredSource() async throws {
        let off = FakeInboxSource(isConfigured: false)
        off.cannedItems = [item("fake:1")]
        let service = InboxService(sources: [off], state: try makeStore())

        await service.refresh()

        // No configured source → no network on the unconfigured one, empty suggestions.
        XCTAssertEqual(off.fetchCallCount, 0)
        XCTAssertTrue(service.suggestions.isEmpty)
    }

    // MARK: Tolerant fan-out — one source throwing must not blank the others

    func testOneSourceThrowingDoesNotBlankOthers() async throws {
        struct Boom: Error {}
        let good = FakeInboxSource(id: "good")
        good.cannedItems = [item("good:1", source: "good")]
        let bad = FakeInboxSource(id: "bad")
        bad.errorToThrow = Boom()

        let service = InboxService(sources: [good, bad], state: try makeStore())
        await service.refresh()

        XCTAssertEqual(service.suggestions.map(\.id), ["good:1"],
                       "the throwing source must not sink the healthy source's items")
        XCTAssertEqual(bad.fetchCallCount, 1, "the bad source was still attempted")
    }

    // MARK: SC2 dedupe — accepted/dismissed ids excluded from suggestions

    func testAcceptedAndDismissedIdsAreExcludedFromSuggestions() async throws {
        let store = try makeStore()
        try store.accept("fake:accepted")
        try store.dismiss("fake:dismissed")

        let src = FakeInboxSource()
        src.cannedItems = [
            item("fake:accepted"), item("fake:dismissed"), item("fake:fresh"),
        ]
        let service = InboxService(sources: [src], state: store)

        await service.refresh()

        XCTAssertEqual(service.suggestions.map(\.id), ["fake:fresh"])
    }

    // MARK: SC2 accept — persists, drops from suggestions, never re-suggested

    func testAcceptPersistsDropsAndNeverReSuggests() async throws {
        let store = try makeStore()
        let src = FakeInboxSource()
        let target = item("fake:1")
        src.cannedItems = [target, item("fake:2")]
        let service = InboxService(sources: [src], state: store)

        await service.refresh()
        XCTAssertEqual(service.suggestions.map(\.id), ["fake:1", "fake:2"])

        try service.accept(target)
        // Dropped from the live suggestion set immediately.
        XCTAssertFalse(service.suggestions.contains { $0.id == "fake:1" })
        // Persisted to the accepted set.
        XCTAssertTrue(store.state.accepted.contains("fake:1"))

        // A subsequent refresh does not re-suggest the accepted item.
        await service.refresh()
        XCTAssertEqual(service.suggestions.map(\.id), ["fake:2"])
    }

    // MARK: SC2 dismiss — persists, drops from suggestions, never re-suggested

    func testDismissPersistsDropsAndNeverReSuggests() async throws {
        let store = try makeStore()
        let src = FakeInboxSource()
        let target = item("fake:1")
        src.cannedItems = [target, item("fake:2")]
        let service = InboxService(sources: [src], state: store)

        await service.refresh()
        XCTAssertEqual(service.suggestions.map(\.id), ["fake:1", "fake:2"])

        try service.dismiss(target)
        XCTAssertFalse(service.suggestions.contains { $0.id == "fake:1" })
        XCTAssertTrue(store.state.dismissed.contains("fake:1"))

        await service.refresh()
        XCTAssertEqual(service.suggestions.map(\.id), ["fake:2"])
    }
}
