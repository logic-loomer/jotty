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
            let tasks = applyDurationGuardrail(rawTasks, against: text, now: now, timezone: timezone)
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

    // MARK: Guardrail (per AI-SPEC §6)

    /// The 3B on-device model conflates duration phrasing ("1-2 hours", "30 min",
    /// "couple hours", "an hour") with clock-time blocks ("1-2pm"). Even with
    /// explicit prompt rules + few-shots, it occasionally emits a `timeBlock`
    /// for a bare duration. This deterministic post-process strips `timeBlock`
    /// and clears `calendarBlock` when the original input contains a duration
    /// phrase without any explicit clock-time endpoints (am/pm or HH:MM).
    private func applyDurationGuardrail(_ tasks: [ExtractedTask], against input: String, now: Date, timezone: TimeZone) -> [ExtractedTask] {
        guard hasDurationPhrase(in: input), !hasExplicitClockTime(in: input) else { return tasks }
        let inferredDue = inferDueDate(from: input, now: now, timezone: timezone)
        return tasks.map { task in
            ExtractedTask(
                title: task.title,
                dueDate: task.dueDate ?? inferredDue,
                timeBlock: nil,
                calendarBlock: false
            )
        }
    }

    /// Best-effort dueDate inference for the duration-guardrail path. Detects
    /// 'today', 'tomorrow', and weekday names in the input. Anchored against
    /// the supplied `now` (NOT `Date()`) so test fixtures resolve correctly.
    private func inferDueDate(from input: String, now: Date, timezone: TimeZone) -> Date? {
        let lower = input.lowercased()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        if lower.range(of: #"\btoday\b"#, options: .regularExpression) != nil {
            return cal.startOfDay(for: now)
        }
        if lower.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil {
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (idx, name) in weekdays.enumerated() {
            if lower.range(of: "\\b\(name)\\b", options: .regularExpression) != nil {
                let target = idx + 1   // Calendar.weekday is 1-indexed Sun=1
                let todayWd = cal.component(.weekday, from: now)
                var delta = target - todayWd
                if delta <= 0 { delta += 7 }
                return cal.date(byAdding: .day, value: delta, to: cal.startOfDay(for: now))
            }
        }
        return nil
    }

    /// Matches "1 hour", "1-2 hours", "30 min", "couple hours", "an hour", "half hour", "few hours", "all morning|afternoon|evening".
    private func hasDurationPhrase(in input: String) -> Bool {
        let patterns = [
            #"\b\d+(?:[-–]\d+)?\s*(?:hours?|hrs?)\b"#,
            #"\b\d+\s*(?:minutes?|mins?)\b"#,
            #"\b(?:an?|half|couple|few)\s*hour"#,
            #"\bhalf\s*(?:an\s*)?hour"#,
            #"\ball\s*(?:morning|afternoon|evening|day)"#
        ]
        return patterns.contains { pattern in
            input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Matches "1pm", "1:30pm", "13:00", "1-2pm", "from 9 to 11am", "9am-5pm", "14:00-15:30".
    private func hasExplicitClockTime(in input: String) -> Bool {
        let pattern = #"\b\d{1,2}(?::\d{2})?\s*(?:am|pm|AM|PM)\b|\b\d{1,2}:\d{2}\b"#
        return input.range(of: pattern, options: .regularExpression) != nil
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
