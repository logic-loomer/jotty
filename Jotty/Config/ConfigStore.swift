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

final class ConfigStore {
    private(set) var config: AppConfig
    private let path: URL

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: path),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = .defaultValue
            try save()
        }
    }

    func update(_ mutate: (inout AppConfig) -> Void) throws {
        mutate(&config)
        try save()
    }

    private func save() throws {
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
