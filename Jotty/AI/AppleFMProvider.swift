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

            "RULE — Past-tense / completed-action: ZERO tasks."
            "Past-tense verbs ('got', 'had', 'shipped', 'wrapped', 'raised', 'agreed', 'talked', 'wrote', 'finished', 'sent') describe completed actions. Do NOT extract any task from them."
            "Input: 'got coffee with Sam this morning, was good' → Tasks: empty. Past tense."
            "Input: 'had standup, team raised concerns, Jake agreed to check the logs' → Tasks: empty. All past-tense — no future action for the user."
            "Input: 'shipped the script yesterday, blast radius was small' → Tasks: empty. Observation about a past event."

            "RULE — One-task-only / no hallucination: extract ONLY what is explicitly stated."
            "If the input contains exactly one actionable future task, return exactly ONE task. Do not invent extras."
            "Input: 'need to fix the login bug at some point' → Tasks: 1. title 'fix the login bug'. No due date — 'at some point' is vague."

            "RULE — Bare duration NEVER becomes a timeBlock."
            "A duration phrase is one that names a LENGTH only, not a clock window. Patterns: 'N hours', 'N min', 'N-N hours', 'an hour', 'half hour', 'couple hours', 'few hours', 'all morning'. These NEVER produce blockStartISO or blockEndISO. They DO produce dueDateISO if a day reference is present."
            "A timeBlock requires explicit clock endpoints — both a START hour and an END hour as digits. '1-2pm' is a timeBlock. '1-2 hours' is a duration."
            "Input: 'couple hours of design review tomorrow' → Tasks: 1. title 'design review', dueDateISO=<tomorrow>. blockStartISO=null, blockEndISO=null."
            "Input: '30 min focus on the report today' → Tasks: 1. title 'focus on the report', dueDateISO=<today>. blockStartISO=null, blockEndISO=null."
            "Input: '1-2 hours of refactor work tomorrow' → Tasks: 1. title 'refactor work', dueDateISO=<tomorrow>. blockStartISO=null, blockEndISO=null. The '1-2' is hours-of-duration, not 1pm-2pm."
            "Input: 'an hour of code review' → Tasks: 1. title 'code review'. NO dueDateISO (no day reference). NO timeBlock."

            "RULE — Empty / whitespace-only input → empty tasks."
            "If the input text is empty, blank, or contains only punctuation/whitespace, return an empty tasks array. Do NOT regurgitate examples from these instructions."
            "Input: '' → Tasks: empty."
            "Input: '   \\n  ' → Tasks: empty."

            "RULE — Past-tense reports stay zero, even with temporal qualifiers."
            "Past-tense verbs followed by 'yesterday', 'this morning', 'last week' are still past-tense. The temporal qualifier does NOT make them future actions."
            "Input: 'shipped the migration script yesterday, blast radius was small' → Tasks: empty. 'shipped' is past tense; 'yesterday' confirms it's done."
            "Input: 'wrote the spec last week and it's been reviewed' → Tasks: empty."
        }
    }
}
