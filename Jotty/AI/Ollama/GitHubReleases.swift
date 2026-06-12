// Jotty/AI/Ollama/GitHubReleases.swift
// Resolves the latest Ollama macOS release asset from the GitHub releases
// API (AI-SPEC §3.1). Jotty downloads `Ollama-darwin.zip` — the full signed
// Ollama.app bundle — and only ever exec's the inner CLI binary.
//
// The URLSession is injectable so tests can stub responses via
// StubURLProtocol; nothing in the test suite hits api.github.com live.

import Foundation

enum GitHubReleases {
    struct Asset: Equatable, Sendable {
        let url: URL        // browser_download_url
        let name: String    // "Ollama-darwin.zip"
        let size: Int64
    }

    /// GET /repos/ollama/ollama/releases/latest and pick the macOS zip.
    static func latestMacAsset(session: URLSession = .shared) async throws -> Asset {
        let api = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.downloadFailed(underlying: "GitHub releases lookup failed")
        }

        // Decode the minimal envelope we need.
        struct Release: Decodable {
            struct A: Decodable {
                let name: String
                let browser_download_url: URL
                let size: Int64
            }
            let assets: [A]
        }
        let rel: Release
        do {
            rel = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw OllamaError.downloadFailed(underlying: "Unexpected GitHub releases payload")
        }
        guard let mac = rel.assets.first(where: { $0.name == "Ollama-darwin.zip" }) else {
            throw OllamaError.downloadFailed(underlying: "No Ollama-darwin.zip in latest release")
        }
        return Asset(url: mac.browser_download_url, name: mac.name, size: mac.size)
    }
}
