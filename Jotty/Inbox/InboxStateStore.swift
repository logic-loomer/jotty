import Foundation

/// Persisted dedupe state for the unified inbox: the ids the user has already
/// `accept`ed (written into today's `## Tasks`) or `dismiss`ed (declined). Both sets
/// feed `InboxService`'s dedupe predicate so neither is ever re-suggested (SC2).
///
/// `Set<String>` gives free idempotency (re-accepting an id is a no-op) and O(1)
/// membership for the per-refresh `accepted ∪ dismissed` filter.
struct InboxState: Codable, Equatable {
    var accepted: Set<String> = []
    var dismissed: Set<String> = []
}

/// Mutable, persisted inbox dedupe-state store.
///
/// Same App Support JSON idiom as `ConfigStore` / `KeybindingsStore`
/// (`Application Support/Jotty/inbox-state.json`): an injectable `path` (tests pass a
/// temp file), parent dir created `withIntermediateDirectories`, atomic writes, and a
/// graceful decode that NEVER throws on construction — a missing or corrupt file falls
/// back to an empty `InboxState()` rather than crashing (threat T-7-05: local
/// single-user file, low value, prefer resilience over hard failure).
///
/// `accept(_:)` / `dismiss(_:)` insert into the respective set and persist atomically;
/// `Set` semantics make re-accepting an already-accepted id a silent no-op.
final class InboxStateStore {
    private(set) var state: InboxState
    private let path: URL

    /// Loads the store at `path`. On a missing/unreadable/corrupt file the state falls
    /// back to empty `InboxState()` (no throw) — only a genuine directory-creation
    /// failure propagates, matching `ConfigStore`'s init contract.
    init(path: URL = InboxStateStore.defaultPath) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: path),
           let loaded = try? JSONDecoder().decode(InboxState.self, from: data) {
            self.state = loaded
        } else {
            // Missing or corrupt file → graceful empty state (no throw on read).
            self.state = InboxState()
        }
    }

    /// Records `id` as accepted and persists. Idempotent (Set insert).
    func accept(_ id: String) throws {
        state.accepted.insert(id)
        try save()
    }

    /// Records `id` as dismissed and persists. Idempotent (Set insert).
    func dismiss(_ id: String) throws {
        state.dismissed.insert(id)
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: path, options: .atomic)
    }

    /// User-writable persistence path, mirroring `ConfigStore.defaultPath` /
    /// `KeybindingsStore.defaultPath`.
    static var defaultPath: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Jotty/inbox-state.json")
    }
}
