import Foundation

/// `@MainActor` coordinator for the unified inbox: it registers the configured
/// `InboxSource`s, runs a tolerant fan-out `refresh()`, dedupes the result against the
/// `accepted ∪ dismissed` set, and exposes `accept`/`dismiss`.
///
/// It is a `@MainActor` `ObservableObject` (NOT an `actor`, RESEARCH Pitfall 5): all
/// per-source networking happens off-actor inside `InboxSource.fetchItems()`; only the
/// final `suggestions` assignment runs on the main actor so SwiftUI observes a coherent
/// update. `InboxService` owns ONLY the suggestion set + dedupe state — the actual Store
/// write of an accepted item's `source:` / `source_url:` task is plan 04's UI wiring
/// (Architectural Responsibility Map), so `accept` here just records the id + drops it.
@MainActor
final class InboxService: ObservableObject {
    /// The currently suggested (not-yet-accepted, not-dismissed) items, recomputed by
    /// each `refresh()` and pruned in place by `accept`/`dismiss`.
    @Published private(set) var suggestions: [InboxItem] = []

    private let state: InboxStateStore
    private let sources: [any InboxSource]

    /// Injects the sources (real concrete sources in the app; `FakeInboxSource`s in
    /// tests) and the persisted dedupe `state` (a temp-path store in tests).
    init(sources: [any InboxSource], state: InboxStateStore) {
        self.sources = sources
        self.state = state
    }

    /// Tolerant fan-out refresh (RESEARCH Pattern 3).
    ///
    /// 1. SC3 privacy gate: if NO source is configured, early-return — no network is
    ///    attempted at all (asserted by the zero-fetch test).
    /// 2. Fan out over the configured sources concurrently; each task swallows its own
    ///    failure (`(try? await ...) ?? []`) so one source's 401/429 cannot blank the
    ///    others' results (T-7-04, tolerant fan-out).
    /// 3. Dedupe the collected items against `accepted ∪ dismissed` (SC2): an id in
    ///    either set is never re-suggested.
    func refresh() async {
        guard sources.contains(where: { $0.isConfigured }) else {
            suggestions = []
            return
        }
        var collected: [InboxItem] = []
        await withTaskGroup(of: [InboxItem].self) { group in
            for src in sources where src.isConfigured {
                group.addTask { (try? await src.fetchItems()) ?? [] }
            }
            for await items in group { collected += items }
        }
        let dedupeState = state.state
        let excluded = dedupeState.accepted.union(dedupeState.dismissed)
        suggestions = collected.filter { !excluded.contains($0.id) }
    }

    /// Records `item.id` as accepted (persisted) and drops it from `suggestions` so it is
    /// never re-suggested (SC2). The Store write of the accepted task is plan 04's wiring.
    func accept(_ item: InboxItem) throws {
        try state.accept(item.id)
        suggestions.removeAll { $0.id == item.id }
    }

    /// Records `item.id` as dismissed (persisted) and drops it from `suggestions` so it is
    /// never re-suggested (SC2).
    func dismiss(_ item: InboxItem) throws {
        try state.dismiss(item.id)
        suggestions.removeAll { $0.id == item.id }
    }
}
