// Jotty/AI/AppleFMProvider.swift
import Foundation
import FoundationModels

/// On-device extraction backend backed by Apple Foundation Models (macOS 26+).
///
/// All methods throw `AIProviderError` directly — no provider-private error
/// type escapes past the actor boundary. Plan 05 fills in `extractTasks`.
actor AppleFMProvider: AIProvider {

    // MARK: Lifecycle

    init() {}

    // MARK: AIProvider

    /// Warm model weights before the user submits a note, reducing first-call
    /// latency. Does NOT cache the session — its Instructions bake in `now` +
    /// `timezone`, which become stale as the user types. The next session
    /// built in `extractTasks` benefits from the weight-loading side-effect of
    /// calling `prewarm()` here.
    func prewarm() async {
        // Warm model weights only. Do NOT cache the session — its Instructions
        // bake in `now` + `timezone`, which become stale as the user types.
        let warm = makeSession(now: Date(), timezone: .current)
        warm.prewarm()
        // Intentionally do not store; warm.prewarm() primes weights at the
        // model layer, which the next session built in extractTasks benefits from.
    }

    func extractTasks(
        from text: String,
        now: Date,
        timezone: TimeZone
    ) async throws -> ExtractionResult {
        // STUB: filled in plan 05. Do not run respond() yet.
        throw AIProviderError.modelUnavailable(
            reason: "AppleFMProvider.extractTasks not implemented (plan 05)"
        )
    }

    // MARK: Private

    private func makeSession(now: Date, timezone: TimeZone) -> LanguageModelSession {
        // Skeleton instructions — plan 05 replaces with full prompt block
        // from AI-SPEC §4.2. The function takes `now` and `timezone` so
        // every session is anchored at call time; there is no init-time anchor.
        return LanguageModelSession {
            "You convert a freeform brain-dump note into a list of actionable tasks."
        }
    }
}
