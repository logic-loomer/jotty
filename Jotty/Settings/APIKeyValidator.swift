// Jotty/Settings/APIKeyValidator.swift
// UX-12 (plan 07.1-10): validates a pasted API key / PAT with ONE lightweight
// authenticated GET against the vendor's cheapest list endpoint, so "Key saved"
// stops meaning "any non-empty string accepted".
//
// SECURITY INVARIANTS (T-07.1-19):
// - The key goes ONLY into the vendor's auth header — never a URL, query
//   string, or any other field.
// - Zero logging anywhere in this file.
// - No result ever carries the key, the path, or the query; `unreachable`
//   exposes the bare host only.
//
// Probes fire ONLY on explicit user action (T-07.1-20) — this type makes no
// call unless a validate function is invoked.

import Foundation

/// Injectable-URLSession key validation helper. One probe endpoint per vendor,
/// per the RESEARCH Pattern 11 table. Endpoint shapes for OpenAI / Gemini /
/// GitHub were live-verified 2026-07-03 with a dummy key (see plan SUMMARY).
struct APIKeyValidator: Sendable {

    /// Which vendor's probe endpoint to hit.
    enum Vendor: Sendable {
        case anthropic
        case openai
        case gemini
        case githubPAT
    }

    /// Three-state probe outcome. A rejected key (auth failure) reads
    /// differently from an unreachable endpoint; `unreachable` carries the
    /// bare host only — never the path, query, or key.
    enum ValidationResult: Equatable, Sendable {
        case valid
        case rejected
        case unreachable(host: String)
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Vendor dispatch

    func validate(_ vendor: Vendor, key: String) async -> ValidationResult {
        switch vendor {
        case .anthropic: return await validateAnthropic(key: key)
        case .openai: return await validateOpenAI(key: key)
        case .gemini: return await validateGemini(key: key)
        case .githubPAT: return await validateGitHubPAT(key: key)
        }
    }

    // MARK: Per-vendor probes (RESEARCH Pattern 11 endpoint table)

    /// Anthropic: GET /v1/models with `x-api-key` + `anthropic-version`
    /// (docs.anthropic.com/en/api/models-list).
    func validateAnthropic(key: String) async -> ValidationResult {
        var request = makeProbeRequest("https://api.anthropic.com/v1/models")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return await probe(request)
    }

    /// OpenAI: GET /v1/models with Bearer auth.
    /// Live-verified 2026-07-03: dummy key returns HTTP 401.
    func validateOpenAI(key: String) async -> ValidationResult {
        var request = makeProbeRequest("https://api.openai.com/v1/models")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await probe(request)
    }

    /// Gemini: GET /v1beta/models with the `x-goog-api-key` header (NEVER the
    /// `?key=` query form — the key must not appear in any URL).
    /// Live-verified 2026-07-03: an invalid key returns HTTP 400
    /// (INVALID_ARGUMENT / API_KEY_INVALID), not 401/403 — so 400 also maps to
    /// `.rejected` for this vendor only.
    func validateGemini(key: String) async -> ValidationResult {
        var request = makeProbeRequest("https://generativelanguage.googleapis.com/v1beta/models")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return await probe(request, extraRejectedStatuses: [400])
    }

    /// GitHub PAT: GET /rate_limit — never costs API quota — with the Bearer +
    /// pinned-version idiom from GitHubInboxSource.makeRequest.
    /// Live-verified 2026-07-03: dummy token returns HTTP 401.
    func validateGitHubPAT(key: String) async -> ValidationResult {
        var request = makeProbeRequest("https://api.github.com/rate_limit")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return await probe(request)
    }

    // MARK: Shared probe core

    /// A probe should fail fast: 15s cap (T-07.1-22).
    private func makeProbeRequest(_ urlString: String) -> URLRequest {
        // Force-unwrap is safe: every probe URL above is a compile-time literal.
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return request
    }

    /// Status mapping: 2xx → valid; 401/403 (plus vendor-specific extras) →
    /// rejected; any other status, a non-HTTP response, or a thrown transport
    /// error → unreachable(bare host).
    private func probe(
        _ request: URLRequest,
        extraRejectedStatuses: Set<Int> = []
    ) async -> ValidationResult {
        let host = request.url?.host() ?? "unknown host"
        let rejectedStatuses = Set([401, 403]).union(extraRejectedStatuses)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(host: host)
            }
            switch http.statusCode {
            case 200...299:
                return .valid
            case let code where rejectedStatuses.contains(code):
                return .rejected
            default:
                return .unreachable(host: host)
            }
        } catch {
            return .unreachable(host: host)
        }
    }
}
