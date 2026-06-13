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

    // MARK: - Bundled-default / in-memory construction (legacy, read-only)

    /// Decodes an in-memory bindings file (the bundled default). Does not persist.
    init(data: Data) throws {
        self.path = nil
        self.bindings = Self.decode(data)
    }

    // MARK: - User-writable, persisted construction

    /// Loads the user-writable store at `path`. On first load (no file) or a
    /// corrupt file, seeds from `defaultData` and writes the user file.
    init(path: URL, defaultData: Data) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: path) {
            let resolved = Self.decode(data)
            if resolved.isEmpty {
                // Empty / malformed → reseed from the bundled default.
                self.bindings = Self.decode(defaultData)
                try persist()
            } else {
                self.bindings = resolved
            }
        } else {
            // First load: seed from the bundled default and write the user file.
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

    /// Restores every binding to the bundled default and persists.
    func reset() throws {
        bindings = Self.decode(try Self.bundledDefaultData())
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
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Jotty/keybindings.json")
    }

    /// Loads the user store at `defaultPath`, seeding from the bundled default.
    static func loadUser(path: URL = defaultPath) throws -> KeybindingsStore {
        try KeybindingsStore(path: path, defaultData: bundledDefaultData())
    }
}
