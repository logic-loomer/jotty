import Foundation

/// Mutable, persisted keybindings store.
///
/// Before Phase 6 this was read-only (bundle default → `combo(for:)`). It now
/// owns a user-writable copy at `Application Support/Jotty/keybindings.json`
/// (same appSupport idiom as `ConfigStore.defaultPath`): on first load with no
/// user file it seeds from the bundled `default-keybindings.json` and writes the
/// user file, `setCombo(_:for:)` mutates + persists, and `reset()` rewrites from
/// the bundled default. The legacy `init(data:)` / `loadDefault()` reads are kept
/// so callers that just need the bundled default (HotkeyManager re-read, seeding)
/// continue to work.
///
/// A malformed user file is tolerated: unknown action keys are dropped and a
/// corrupt/unreadable file falls back to a bundled-default seed rather than
/// crashing (threat T-6-02).
final class KeybindingsStore {
    private struct File: Codable {
        let version: Int
        let bindings: [String: KeyCombo]
    }

    private static let version = 1

    private var bindings: [Action: KeyCombo]
    /// User-writable persistence path. `nil` for the in-memory `init(data:)`
    /// construction (bundled-default reads), which never persists.
    private let path: URL?
    /// The injected default seed, retained at init so `reset()` restores exactly the
    /// seed first-run seeding used (WR-01) and forward-compat backfill (WR-02) merges
    /// against the SAME source — never coupling back to global `Bundle.main` state.
    /// `nil` for the in-memory `init(data:)` path (which never resets or backfills).
    private let defaultData: Data?

    // MARK: - Bundled-default / in-memory construction (legacy, read-only)

    /// Decodes an in-memory bindings file (the bundled default). Does not persist,
    /// reset, or backfill, so it carries no retained seed.
    init(data: Data) throws {
        self.path = nil
        self.defaultData = nil
        self.bindings = Self.decode(data)
    }

    // MARK: - User-writable, persisted construction

    /// Loads the user-writable store at `path`. On first load (no file) or a
    /// corrupt file, seeds from `defaultData` and writes the user file.
    init(path: URL, defaultData: Data) throws {
        self.path = path
        self.defaultData = defaultData
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: path) {
            var resolved = Self.decode(data)
            if resolved.isEmpty {
                // Empty / malformed → reseed from the injected default.
                self.bindings = Self.decode(defaultData)
                try persist()
            } else {
                // WR-02 forward-compat: a valid pre-upgrade file is missing actions added
                // in a later version (e.g. sendToClaude). Backfill those from the default
                // seed so the new action keeps its default combo instead of resolving to
                // nil ("Not set"), and persist so the file is complete on the next launch.
                var backfilled = false
                for (action, combo) in Self.decode(defaultData) where resolved[action] == nil {
                    resolved[action] = combo
                    backfilled = true
                }
                self.bindings = resolved
                if backfilled { try persist() }
            }
        } else {
            // First load: seed from the injected default and write the user file.
            self.bindings = Self.decode(defaultData)
            try persist()
        }
    }

    // MARK: - Reads

    func combo(for action: Action) -> KeyCombo? {
        bindings[action]
    }

    /// Snapshot of every resolved binding (for the Keybindings tab + conflict check).
    func allBindings() -> [Action: KeyCombo] {
        bindings
    }

    // MARK: - Mutation (persisted)

    /// Sets `combo` for `action` and persists. No-op persistence if not user-backed.
    func setCombo(_ combo: KeyCombo, for action: Action) throws {
        bindings[action] = combo
        try persist()
    }

    /// Restores every binding to the INJECTED default seed (WR-01) and persists — the
    /// exact same source first-run seeding used, never re-reading global `Bundle.main`
    /// state (which could diverge from the injected seed). Falls back to the bundle only
    /// for the in-memory `init(data:)` path that has no retained seed.
    func reset() throws {
        let seed = try defaultData ?? Self.bundledDefaultData()
        bindings = Self.decode(seed)
        try persist()
    }

    // MARK: - Helpers

    private func persist() throws {
        guard let path else { return }
        let file = File(
            version: Self.version,
            bindings: Dictionary(uniqueKeysWithValues:
                bindings.map { ($0.key.rawValue, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: path, options: .atomic)
    }

    /// Decodes raw file data into resolved `Action → KeyCombo` pairs, dropping any
    /// unknown action keys. Returns `[:]` on a malformed file (caller reseeds).
    private static func decode(_ data: Data) -> [Action: KeyCombo] {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return [:]
        }
        var resolved: [Action: KeyCombo] = [:]
        for (rawKey, combo) in file.bindings {
            if let action = Action(rawValue: rawKey) {
                resolved[action] = combo
            }
        }
        return resolved
    }

    private static func bundledDefaultData() throws -> Data {
        guard let url = Bundle.main.url(
            forResource: "default-keybindings", withExtension: "json") else {
            throw NSError(domain: "Jotty", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "default-keybindings.json missing from bundle"])
        }
        return try Data(contentsOf: url)
    }
}

extension KeybindingsStore {
    /// Reads the bundled default into an in-memory (non-persisted) store.
    static func loadDefault() throws -> KeybindingsStore {
        try KeybindingsStore(data: bundledDefaultData())
    }

    /// User-writable persistence path, mirroring `ConfigStore.defaultPath`.
    static var defaultPath: URL {
        // CQ-06 fail-soft: fall back to the home-anchored Application Support path so
        // this accessor keeps returning a non-optional URL instead of crashing launch.
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Jotty] Application Support unavailable; falling back to ~/Library/Application Support")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Jotty/keybindings.json")
        }
        return appSupport.appendingPathComponent("Jotty/keybindings.json")
    }

    /// Loads the user store at `defaultPath`, seeding from the bundled default.
    static func loadUser(path: URL = defaultPath) throws -> KeybindingsStore {
        try KeybindingsStore(path: path, defaultData: bundledDefaultData())
    }
}
