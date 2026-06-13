// Jotty/AI/AppleFMProvider.swift
import Foundation
import FoundationModels

/// On-device extraction backend backed by Apple Foundation Models (macOS 26+).
///
/// All methods throw `AIProviderError` directly — no provider-private error
/// type escapes past the actor boundary.
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
        // Always fresh — never reuse a cached session, since Instructions
        // bake in the now/timezone anchors.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AIProviderError.modelUnavailable(reason: String(describing: reason))
        }

        let session = makeSession(now: now, timezone: timezone)

        do {
            let response = try await session.respond(
                to: Prompt(text),
                generating: ExtractionResultAI.self,
                includeSchemaInPrompt: false,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0.0,
                    maximumResponseTokens: 512
                )
            )
            let rawTasks = ISOTaskMapper.map(response.content.tasks, in: timezone)
            // Duration guardrail (AI-SPEC §6) — shared post-process, see
            // Jotty/AI/Guardrails/DurationGuardrail.swift.
            let tasks = DurationGuardrail.apply(rawTasks, against: text, now: now, timezone: timezone)
            return ExtractionResult(tasks: tasks, noteBody: text)
        } catch let err as LanguageModelSession.GenerationError {
            switch err {
            case .exceededContextWindowSize:
                throw AIProviderError.contextOverflow
            case .guardrailViolation:
                throw AIProviderError.guardrail(message: nil)
            default:
                throw AIProviderError.underlying(message: String(describing: err))
            }
        } catch {
            throw AIProviderError.underlying(message: error.localizedDescription)
        }
    }

    // MARK: Private

    private func makeSession(now: Date, timezone: TimeZone) -> LanguageModelSession {
        // The instructions text lives in ExtractionPrompt — the single shared
        // copy consumed by every provider. Feed one builder element per line
        // to preserve the exact multi-segment Instructions structure the
        // Phase 3 fixture suite was tuned against (a single joined string
        // renders differently to the on-device model and regresses the
        // past-tense fixtures).
        LanguageModelSession {
            for line in ExtractionPrompt.lines(now: now, timezone: timezone) {
                line
            }
        }
    }
}
