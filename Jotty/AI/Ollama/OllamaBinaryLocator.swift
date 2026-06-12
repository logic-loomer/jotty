// Jotty/AI/Ollama/OllamaBinaryLocator.swift
// Locates an existing Ollama binary on this Mac (AI-SPEC §3.2).
//
// Priority order matters: prefer the user's existing setup (Homebrew,
// /Applications) over the Jotty-managed copy so two daemons never fight
// over port 11434. When locate() returns anything but .jottyManaged /
// .notFound, the installer must NOT download its own copy.

import Foundation

enum OllamaBinaryLocation: Equatable {
    case systemHomebrew(URL)
    case appBundle(URL)
    case jottyManaged(URL)
    case notFound

    /// The runnable binary URL, nil for .notFound.
    var binaryURL: URL? {
        switch self {
        case .systemHomebrew(let url), .appBundle(let url), .jottyManaged(let url):
            return url
        case .notFound:
            return nil
        }
    }
}

enum OllamaBinaryLocator {

    /// The Jotty-managed binary inside the extracted Ollama.app bundle:
    /// ~/Library/Application Support/Jotty/ollama/Ollama.app/Contents/Resources/ollama
    static var jottyManagedBinary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Jotty/ollama/Ollama.app/Contents/Resources/ollama")
    }

    /// Checks well-known locations in priority order (AI-SPEC §3.2):
    /// Apple Silicon Homebrew → Intel Homebrew → /Applications DMG install →
    /// Jotty-managed Application Support copy.
    static func locate() -> OllamaBinaryLocation {
        locate(fileExists: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    /// Injectable core for tests — `fileExists` stands in for
    /// `FileManager.isExecutableFile`.
    static func locate(fileExists: (URL) -> Bool) -> OllamaBinaryLocation {
        let candidates: [(URL, (URL) -> OllamaBinaryLocation)] = [
            (URL(fileURLWithPath: "/opt/homebrew/bin/ollama"), { .systemHomebrew($0) }),
            (URL(fileURLWithPath: "/usr/local/bin/ollama"), { .systemHomebrew($0) }),
            (URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
             { .appBundle($0) }),
            (jottyManagedBinary, { .jottyManaged($0) }),
        ]
        for (url, wrap) in candidates where fileExists(url) {
            return wrap(url)
        }
        return .notFound
    }

    /// Returns the located binary URL or throws `.binaryNotFound`.
    static func requireBinary() throws -> URL {
        try requireBinary(fileExists: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    /// Injectable core for tests.
    static func requireBinary(fileExists: (URL) -> Bool) throws -> URL {
        guard let url = locate(fileExists: fileExists).binaryURL else {
            throw OllamaError.binaryNotFound
        }
        return url
    }
}
