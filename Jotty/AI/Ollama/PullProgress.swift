// Jotty/AI/Ollama/PullProgress.swift
// One NDJSON line from POST /api/pull (AI-SPEC §3.4). Phases observed:
// "pulling manifest" → "pulling <digest>" (with total/completed) →
// "verifying sha256 digest" → "writing manifest" →
// "removing any unused layers" → "success".

import Foundation

struct PullProgress: Decodable, Equatable, Sendable {
    let status: String
    let digest: String?
    let total: Int64?
    let completed: Int64?

    /// Progress within the current layer, 0...1. Nil for phases that carry
    /// no byte counts (manifest/verify/success) and when total is zero.
    /// Capped at 1.0 — the daemon can briefly report completed > total.
    var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1.0, Double(completed) / Double(total))
    }
}
