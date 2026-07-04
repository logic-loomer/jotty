// Jotty/AI/Guardrails/DurationGuardrail.swift
// Shared duration guardrail (AI-SPEC §6), extracted verbatim from
// AppleFMProvider in plan 04-09 so every provider (Apple FM, Ollama, and any
// future backend) applies identical post-processing.

import Foundation

/// Deterministic post-process shared by all extraction providers.
///
/// Small models conflate duration phrasing ("1-2 hours", "30 min",
/// "couple hours", "an hour") with clock-time blocks ("1-2pm"). Even with
/// explicit prompt rules + few-shots, they occasionally emit a `timeBlock`
/// for a bare duration. `apply` strips `timeBlock` and clears `calendarBlock`
/// when the original input contains a duration phrase without any explicit
/// clock-time endpoints (am/pm or HH:MM).
///
/// Behavior is byte-identical to the original private implementation in
/// `AppleFMProvider` — the Phase 3 fixture suite is the regression bar.
enum DurationGuardrail {

    /// Strips a `timeBlock` from any task whose origin text is a duration
    /// phrase but contains no clock-time anchor. Infers a best-effort
    /// `dueDate` from day references in the input when the task has none.
    static func apply(
        _ tasks: [ExtractedTask],
        against input: String,
        now: Date,
        timezone: TimeZone
    ) -> [ExtractedTask] {
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
    private static func inferDueDate(from input: String, now: Date, timezone: TimeZone) -> Date? {
        let lower = input.lowercased()
        let cal = DailyFile.calendar(timezone: timezone)
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
    private static func hasDurationPhrase(in input: String) -> Bool {
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
    private static func hasExplicitClockTime(in input: String) -> Bool {
        let pattern = #"\b\d{1,2}(?::\d{2})?\s*(?:am|pm|AM|PM)\b|\b\d{1,2}:\d{2}\b"#
        return input.range(of: pattern, options: .regularExpression) != nil
    }
}
