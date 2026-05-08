// Jotty/AI/AIProvider.swift
import Foundation

/// Canonical error type thrown by every AIProvider. Phase 3 (AppleFMProvider)
/// and Phase 4 (Ollama / Claude / OpenAI / Gemini) all map their native
/// failures to one of these four cases. Consumers (CaptureViewModel and
/// future surfaces) catch THIS type — never a concrete provider's nested
/// error type.
enum AIProviderError: Error, Equatable {
    /// Model isn't available on this device/runtime. `reason` is human-readable
    /// and safe to show in the UI directly (e.g. "Turn on Apple Intelligence
    /// in System Settings.").
    case modelUnavailable(reason: String)

    /// Input exceeded the provider's context window. Caller should fall back
    /// to plain-note storage.
    case contextOverflow

    /// Model refused via its safety / guardrail filter. `message` is provider-
    /// supplied where available, nil otherwise.
    case guardrail(message: String?)

    /// Anything else. `message` is debug-shape only (do NOT show verbatim in UI).
    case underlying(message: String)
}

/// The single seam between Jotty's capture pipeline and any extraction
/// backend (Apple Foundation Models in Phase 3; Ollama, Claude, OpenAI,
/// Gemini in Phase 4). All providers must:
///
/// - Be safe to call from `@MainActor` contexts (typically by being an
///   `actor` or by serialising state internally).
/// - Anchor relative phrases ("today", "tomorrow", weekday names) against
///   the supplied `now` and `timezone` (NEVER UTC, NEVER `Date()` inside
///   the provider).
/// - Throw `AIProviderError` on failure (NEVER a provider-private type).
///   Callers MUST be able to fall back to plain-note storage on any throw
///   (see AI-SPEC §4.6).
protocol AIProvider: Sendable {
    func extractTasks(
        from text: String,
        now: Date,
        timezone: TimeZone
    ) async throws -> ExtractionResult
}
