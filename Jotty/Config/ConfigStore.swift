import Foundation

struct AppConfig: Codable, Equatable {
    var storageFolder: URL

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
