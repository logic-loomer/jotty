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
            let tasks = ISOTaskMapper.map(response.content.tasks, in: timezone)
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
        let nowISO = ISO8601DateFormatter().string(from: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let weekdayName = cal.weekdaySymbols[cal.component(.weekday, from: now) - 1]

        return LanguageModelSession {
            "You convert a freeform brain-dump note into a list of actionable tasks."

            "Current local date-time anchor: \(nowISO). Timezone: \(timezone.identifier). Weekday: \(weekdayName)."
            "Resolve all relative phrases against that anchor (today, tomorrow, this afternoon, weekday names, EOM, EOW)."
            "If a weekday name matches today, resolve to the NEXT occurrence (today + 7), never today, unless the user wrote 'today'."

            "Output rules:"
            "- title: preserve the user's wording verbatim or near-verbatim. No outcome-rewriting, no corporatizing, no truncation of modifiers."
            "- dueDateISO: yyyy-MM-dd. Set ONLY for explicit deadlines — phrases like 'by Friday', 'due tomorrow', 'before EOM', 'due next Monday', 'by end of week'. Resolve the named day or phrase against the anchor date and emit the concrete yyyy-MM-dd. For vague phrasing ('soon', 'later', 'eventually', 'at some point'), OMIT the field."
            "- blockStartISO + blockEndISO: full ISO-8601 with timezone offset. Set ONLY when the user named both a start AND an end clock time ('1-2pm', 'from 9 to 11', 'block 14:00-15:30'). For bare time mentions ('at 5pm', 'around 3') or durations ('1-2 hours of focus'), OMIT both."
            "- Skip non-actionable text: observations, feelings, past-tense reports, venting."
            "- Tolerate typos, lowercase, missing punctuation, run-ons, bullet variants."
            "- Empty `tasks` array is the correct answer for venting or pure prose."

            "Examples:"
            "Input: 'email Jamie about Q2 plan by Friday'"
            "Tasks: 1. title 'email Jamie about Q2 plan', dueDateISO=<this Friday's date>. 'by Friday' is an explicit deadline — resolve to the upcoming Friday."

            "Input: 'email Jamie re Q2 plan today, block 1-2pm laptop setup, domain renewal due Friday'"
            "Tasks: 3. (1) title 'email Jamie re Q2 plan', dueDateISO=<today>. (2) title 'laptop setup', blockStartISO=<today>T13:00, blockEndISO=<today>T14:00. (3) title 'domain renewal', dueDateISO=<this Friday>."

            "Input: 'I'm exhausted, this week has been brutal'"
            "Tasks: empty. This is venting, not a task."

            "Input: 'should look into the auth bug soon'"
            "Tasks: 1. title 'look into the auth bug'. NO dueDateISO — 'soon' is vague."
        }
    }
}
