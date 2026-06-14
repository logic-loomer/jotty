import Foundation
import Synchronization
@testable import Jotty

/// In-memory `InboxSource` test double for the Phase 7 suite.
///
/// Returns canned `InboxItem`s, can be flipped to throw a configured error, and records its
/// `fetchItems()` call count. It makes NO network call, so no test ever touches a real
/// third-party API (RESEARCH "Wave 0 Gaps"). Downstream plan 07-02 uses `errorToThrow` to
/// assert `InboxService`'s tolerant fan-out (one failing source doesn't block others) and
/// `fetchCallCount` to assert no-network-when-unconfigured.
///
/// `InboxSource` is `Sendable`, so this fake must be `Sendable` too. All mutable state lives
/// behind a single `Mutex` (mirroring `FakeCalendarService`), giving genuine `Sendable`
/// conformance while exposing plain synchronous getters/setters.
final class FakeInboxSource: InboxSource {

    private struct State {
        var cannedItems: [InboxItem] = []
        var errorToThrow: Error?
        var fetchCallCount = 0
    }

    private let state = Mutex(State())

    let id: String
    let displayName: String
    let endpointURL: String

    /// Backing store for the mutable `isConfigured` flag (a source can be toggled on/off
    /// between tests without rebuilding it).
    private let configured = Mutex(true)

    init(id: String = "fake",
         displayName: String = "Fake",
         endpointURL: String = "https://example.test",
         isConfigured: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.configured.withLock { $0 = isConfigured }
    }

    // MARK: Configurable behavior (synchronous, mutex-guarded)

    /// Returned by `fetchItems()` when not throwing.
    var cannedItems: [InboxItem] {
        get { state.withLock { $0.cannedItems } }
        set { state.withLock { $0.cannedItems = newValue } }
    }
    /// When non-nil, `fetchItems()` throws this instead of returning `cannedItems`.
    var errorToThrow: Error? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    // MARK: Recorded state (assertions for later plans)

    /// Number of times `fetchItems()` was invoked (no-network-when-unconfigured assertions).
    var fetchCallCount: Int { state.withLock { $0.fetchCallCount } }

    // MARK: InboxSource

    var isConfigured: Bool { configured.withLock { $0 } }

    func fetchItems() async throws -> [InboxItem] {
        try state.withLock {
            $0.fetchCallCount += 1
            if let error = $0.errorToThrow { throw error }
            return $0.cannedItems
        }
    }
}
