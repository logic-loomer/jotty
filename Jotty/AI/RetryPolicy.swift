// Jotty/AI/RetryPolicy.swift
// Shared retry helper for cloud AI providers (AI-SPEC §8.3, guardrail G4).
//
// Exponential backoff with ±50% jitter, max 2 retries (3 total attempts).
// Cloud providers (Ollama, Claude, OpenAI, Gemini) wrap their HTTP request
// closure in `policy.execute { ... }` so retry behavior is uniform across
// providers. A server-supplied `Retry-After` value (surfaced by the caller
// via `retryAfterSeconds`) overrides the base delay and skips jitter —
// the server's number is authoritative.

import Foundation

actor RetryPolicy {
    struct Config: Sendable {
        /// Total attempts = maxRetries + 1.
        var maxRetries: Int = 2
        /// Delay BEFORE retry attempt N (N = 1...maxRetries), in milliseconds.
        var baseDelaysMs: [Int] = [250, 1_000]
        /// ±50% — actual delay ∈ [base*0.5, base*1.5].
        var jitterFactor: Double = 0.5
    }

    /// Pluggable sleeper so tests do not have to wait real wall-clock seconds.
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let config: Config
    private let sleeper: Sleeper

    init(config: Config = .init(),
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.config = config
        self.sleeper = sleeper
    }

    /// Transient URLError codes retried directly so RetryPolicy stays
    /// provider-agnostic even when a provider rethrows raw URLSession
    /// failures (AI-SPEC §8.1 G4: networkConnectionLost is retryable).
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet,
    ]

    /// Run `op`. On a retryable `AIProviderError` (or transient `URLError`),
    /// sleep + retry up to `maxRetries` times. `retryAfterSeconds` lets the
    /// caller pass through `Retry-After` headers; when it returns a value,
    /// that delay is used verbatim (no jitter). The final throw is the last
    /// retryable error encountered, unwrapped. Non-retryable errors
    /// short-circuit and propagate verbatim. Cancellation propagates through
    /// the sleeper (`Task.sleep` throws `CancellationError` when cancelled).
    func execute<T: Sendable>(
        retryAfterSeconds: (@Sendable (Error) -> Double?)? = nil,
        op: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...config.maxRetries {
            if attempt > 0 {
                let nanos: UInt64
                if let lastError, let retryAfter = retryAfterSeconds?(lastError) {
                    // Server-supplied Retry-After is authoritative — no jitter.
                    nanos = UInt64(retryAfter * 1_000_000_000)
                } else {
                    let index = min(attempt - 1, config.baseDelaysMs.count - 1)
                    let baseMs = config.baseDelaysMs.isEmpty ? 0 : config.baseDelaysMs[index]
                    let jitter = 1.0 + Double.random(in: -config.jitterFactor...config.jitterFactor)
                    nanos = UInt64(Double(baseMs) * 1_000_000 * jitter)
                }
                try await sleeper(nanos)
            }
            do {
                return try await op()
            } catch let error as AIProviderError where error.isRetryable {
                lastError = error
            } catch let error as URLError where Self.transientURLErrorCodes.contains(error.code) {
                lastError = error
            }
            // Any other error (non-retryable AIProviderError, non-transient
            // URLError, CancellationError, generic Error) propagates verbatim
            // out of the unmatched catch clauses above.
        }
        throw lastError ?? AIProviderError.modelUnavailable(
            reason: "Rate limited; try again in a moment."
        )
    }
}

/// Carries the most recent `Retry-After` header value from inside a provider's
/// retried op (a `@Sendable` closure) out to RetryPolicy's `retryAfterSeconds`
/// callback. Accesses are sequential — RetryPolicy runs attempts one at a time
/// — but the NSLock keeps the type honest under Sendable checking. Shared by
/// the providers that surface Retry-After (Claude, OpenAI) so the single copy
/// cannot drift (MIN-06).
final class RetryAfterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?

    init() {}

    var value: Double? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

extension AIProviderError {
    /// Per AI-SPEC §8.3:
    ///   - `.modelUnavailable`, `.underlying` → retryable (transient)
    ///   - `.guardrail`, `.contextOverflow`   → not retryable
    ///     (deterministic refusal / oversize input — retrying cannot help)
    var isRetryable: Bool {
        switch self {
        case .modelUnavailable, .underlying: return true
        case .guardrail, .contextOverflow: return false
        }
    }
}
