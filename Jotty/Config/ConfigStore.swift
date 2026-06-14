import Foundation

/// Send-to-Claude handoff mode (D-SC1). `.web` opens the encoded `claude.ai/new?q=`
/// prompt; `.code` spawns the local `claude` binary. Stored in config.json as a
/// stable string so a hand-edited / pre-Phase-6 file degrades gracefully.
enum ClaudeAction: String, Codable, Equatable {
    case web
    case code
}

struct AppConfig: Codable, Equatable {
    var storageFolder: URL
    /// Provider IDs: "apple-fm" | "ollama" | "claude" | "openai" | "gemini".
    /// Non-secret — safe in config.json. API keys NEVER live here; they go
    /// through KeychainAPIKeyStore exclusively.
    var aiProviderID: String
    /// Selected Ollama model tag (e.g. "qwen2.5:3b"). nil until the user picks one.
    var ollamaModel: String?
    /// Chosen writable calendar identifier (EKCalendar). nil = use the default
    /// calendar for new events. Non-secret local pref, same class as aiProviderID.
    var calendarIdentifier: String?
    /// Remembered "delete the linked calendar event when its task is deleted"
    /// preference. nil = ask the user; true/false = remembered choice.
    var deleteCalendarEventWithTask: Bool?
    /// Send-to-Claude handoff mode (D-SC1). Defaults to `.web`.
    var claudeAction: ClaudeAction
    /// Whether the first-run onboarding flow has been completed (D-SC5).
    /// Defaults to `false`; flipped true once onboarding finishes.
    var hasCompletedOnboarding: Bool

    init(storageFolder: URL,
         aiProviderID: String = "apple-fm",
         ollamaModel: String? = nil,
         calendarIdentifier: String? = nil,
         deleteCalendarEventWithTask: Bool? = nil,
         claudeAction: ClaudeAction = .web,
         hasCompletedOnboarding: Bool = false) {
        self.storageFolder = storageFolder
        self.aiProviderID = aiProviderID
        self.ollamaModel = ollamaModel
        self.calendarIdentifier = calendarIdentifier
        self.deleteCalendarEventWithTask = deleteCalendarEventWithTask
        self.claudeAction = claudeAction
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    /// Backward-compatible decode: config.json files written before Phase 4
    /// contain only `storageFolder`. Missing provider fields default rather
    /// than failing the whole decode (which would silently reset the user's
    /// config to defaults via ConfigStore's fallback path).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageFolder = try container.decode(URL.self, forKey: .storageFolder)
        aiProviderID = try container.decodeIfPresent(String.self, forKey: .aiProviderID)
            ?? "apple-fm"
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel)
        calendarIdentifier = try container.decodeIfPresent(
            String.self, forKey: .calendarIdentifier)
        deleteCalendarEventWithTask = try container.decodeIfPresent(
            Bool.self, forKey: .deleteCalendarEventWithTask)
        // Phase 6 keys: a pre-Phase-6 (or partial) config.json omits these.
        // decodeIfPresent → default so the whole decode never fails (which would
        // reset the user's config to defaults via ConfigStore's fallback path).
        claudeAction = try container.decodeIfPresent(
            ClaudeAction.self, forKey: .claudeAction) ?? .web
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    static var defaultValue: AppConfig {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return AppConfig(storageFolder: docs.appendingPathComponent("Jotty"))
    }
}

/// Thread-safe, persisted app config.
///
/// `Sendable` so it can be captured into the `@Sendable` Claude-handoff `action`
/// closure and the calendar `calendarID` closure WITHOUT `@unchecked` masking a data
/// race (WR-03): a `send(prompt:)` that legitimately runs off the main actor must be
/// able to read `config` concurrently with an `update {}` write from a Settings tab.
/// `AppConfig` is a `Sendable` value type; `config`'s storage and every `update` are
/// serialized behind a lock, so reads and writes never tear.
final class ConfigStore: @unchecked Sendable {
    /// Serializes every read of and write to `_config`. `@unchecked Sendable` is sound
    /// here because the ONLY mutable state (`_config`) is never touched outside this lock.
    private let lock = NSLock()
    private var _config: AppConfig
    private let path: URL

    /// Live snapshot of the config, read under the lock so it never tears against a
    /// concurrent `update {}` (WR-03). `AppConfig` is a value type, so the returned copy
    /// is independent of subsequent mutations.
    var config: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: path),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self._config = loaded
        } else {
            self._config = .defaultValue
            // Encode + write the initial default outside any captured-self closure; the
            // lock is uncontended during init so a plain save is fine.
            try Self.write(_config, to: path)
        }
    }

    func update(_ mutate: (inout AppConfig) -> Void) throws {
        lock.lock()
        mutate(&_config)
        let snapshot = _config
        lock.unlock()
        // Persist OUTSIDE the lock (file I/O must not be held under the mutex), using the
        // snapshot taken while locked so the written bytes match the applied mutation.
        try Self.write(snapshot, to: path)
    }

    private static func write(_ config: AppConfig, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: path, options: .atomic)
    }

    static var defaultPath: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Jotty/config.json")
    }
}
