import Foundation

final class KeybindingsStore {
    private struct File: Codable {
        let version: Int
        let bindings: [String: KeyCombo]
    }

    private let bindings: [Action: KeyCombo]

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var resolved: [Action: KeyCombo] = [:]
        for (rawKey, combo) in file.bindings {
            if let action = Action(rawValue: rawKey) {
                resolved[action] = combo
            }
        }
        self.bindings = resolved
    }

    func combo(for action: Action) -> KeyCombo? {
        bindings[action]
    }
}

extension KeybindingsStore {
    static func loadDefault() throws -> KeybindingsStore {
        guard let url = Bundle.main.url(forResource: "default-keybindings", withExtension: "json") else {
            throw NSError(domain: "Jotty", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "default-keybindings.json missing from bundle"])
        }
        let data = try Data(contentsOf: url)
        return try KeybindingsStore(data: data)
    }
}
