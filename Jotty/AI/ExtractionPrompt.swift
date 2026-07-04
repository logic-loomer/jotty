// Jotty/AI/ExtractionPrompt.swift
import Foundation

/// The single shared extraction system prompt: anchor lines + the full rules
/// block previously inlined in `AppleFMProvider.makeSession`.
///
/// There is exactly ONE copy of this text in the codebase. `AppleFMProvider`
/// feeds it to `LanguageModelSession` as its instructions; the cloud and
/// Ollama providers concatenate it with the user text for their system
/// prompts. The wording is tuned against the 35-fixture suite — do not edit
/// without re-running the fixtures.
enum ExtractionPrompt {

    /// The prompt as a single string (lines joined with `"\n"`). This is the
    /// form the cloud/Ollama providers embed in their request bodies.
    static func text(now: Date, timezone: TimeZone) -> String {
        lines(now: now, timezone: timezone).joined(separator: "\n")
    }

    /// The prompt as individual instruction lines. `AppleFMProvider` feeds
    /// these to its `LanguageModelSession` instructions builder one element
    /// per line — preserving the exact multi-segment Instructions structure
    /// the Phase 3 fixture suite was tuned against (a single joined string
    /// renders differently to the on-device model and regresses the
    /// past-tense fixtures).
    static func lines(now: Date, timezone: TimeZone) -> [String] {
        let nowISO = ISO8601DateFormatter().string(from: now)
        let cal = DailyFile.calendar(timezone: timezone)
        let weekdayName = cal.weekdaySymbols[cal.component(.weekday, from: now) - 1]

        let lines: [String] = [
            "You convert a freeform brain-dump note into a list of actionable tasks.",

            "Current local date-time anchor: \(nowISO). Timezone: \(timezone.identifier). Weekday: \(weekdayName).",
            "Resolve all relative phrases against that anchor (today, tomorrow, this afternoon, weekday names, EOM, EOW).",
            "If a weekday name matches today, resolve to the NEXT occurrence (today + 7), never today, unless the user wrote 'today'.",

            "Output rules:",
            "- title: preserve the user's wording verbatim or near-verbatim. No outcome-rewriting, no corporatizing, no truncation of modifiers.",
            "- dueDateISO: yyyy-MM-dd. Set ONLY for explicit deadlines — phrases like 'by Friday', 'due tomorrow', 'before EOM', 'due next Monday', 'by end of week'. Resolve the named day or phrase against the anchor date and emit the concrete yyyy-MM-dd. For vague phrasing ('soon', 'later', 'eventually', 'at some point'), OMIT the field.",
            "- blockStartISO + blockEndISO: full ISO-8601 with timezone offset. Set whenever the user named a concrete clock time. A start-AND-end range ('1-2pm', 'from 9 to 11', 'block 14:00-15:30') uses those exact endpoints. A SINGLE named clock time ('at 5pm', '9pm', 'call at 17:00') sets blockStartISO to that time and blockEndISO to 30 minutes later. A concrete clock time is digits with am/pm or an explicit HH:MM. A vague or approximate mention ('around 3', 'this evening', 'later', 'soon', 'eventually', 'at some point', 'sometime after lunch') is NOT concrete, so OMIT both — these NEVER produce a block. Durations ('1-2 hours of focus', '30 min', 'an hour') set NEITHER (see the bare-duration rule below).",
            "- Skip non-actionable text: observations, feelings, past-tense reports, venting.",
            "- Tolerate typos, lowercase, missing punctuation, run-ons, bullet variants.",
            "- Empty `tasks` array is the correct answer for venting or pure prose.",

            "Examples:",
            "Input: 'email Jamie about Q2 plan by Friday'",
            "Tasks: 1. title 'email Jamie about Q2 plan', dueDateISO=<this Friday's date>. 'by Friday' is an explicit deadline — resolve to the upcoming Friday.",

            "Input: 'email Jamie re Q2 plan today, block 1-2pm laptop setup, domain renewal due Friday'",
            "Tasks: 3. (1) title 'email Jamie re Q2 plan', dueDateISO=<today>. (2) title 'laptop setup', blockStartISO=<today>T13:00, blockEndISO=<today>T14:00. (3) title 'domain renewal', dueDateISO=<this Friday>.",

            "Input: 'call Asim at 9pm today'",
            "Tasks: 1. title 'call Asim', blockStartISO=<today>T21:00, blockEndISO=<today>T21:30. A single named clock time gets a 30-minute block.",

            "Input: 'gym at 5pm'",
            "Tasks: 1. title 'gym', blockStartISO=<today>T17:00, blockEndISO=<today>T17:30.",

            "Input: 'I'm exhausted, this week has been brutal'",
            "Tasks: empty. This is venting, not a task.",

            "Input: 'should look into the auth bug soon'",
            "Tasks: 1. title 'look into the auth bug'. NO dueDateISO — 'soon' is vague.",

            "RULE — Past-tense / completed-action: ZERO tasks.",
            "Past-tense verbs ('got', 'had', 'shipped', 'wrapped', 'raised', 'agreed', 'talked', 'wrote', 'finished', 'sent') describe completed actions. Do NOT extract any task from them.",
            "Input: 'got coffee with Sam this morning, was good' → Tasks: empty. Past tense.",
            "Input: 'had standup, team raised concerns, Jake agreed to check the logs' → Tasks: empty. All past-tense — no future action for the user.",
            "Input: 'shipped the script yesterday, blast radius was small' → Tasks: empty. Observation about a past event.",

            "RULE — One-task-only / no hallucination: extract ONLY what is explicitly stated.",
            "If the input contains exactly one actionable future task, return exactly ONE task. Do not invent extras.",
            "Input: 'need to fix the login bug at some point' → Tasks: 1. title 'fix the login bug'. No due date — 'at some point' is vague.",

            "RULE — Bare duration NEVER becomes a timeBlock.",
            "A duration phrase is one that names a LENGTH only, not a clock window. Patterns: 'N hours', 'N min', 'N-N hours', 'an hour', 'half hour', 'couple hours', 'few hours', 'all morning'. These NEVER produce blockStartISO or blockEndISO. They DO produce dueDateISO if a day reference is present.",
            "A timeBlock requires explicit clock endpoints — both a START hour and an END hour as digits. '1-2pm' is a timeBlock. '1-2 hours' is a duration.",
            "Input: 'couple hours of design review tomorrow' → Tasks: 1. title 'design review', dueDateISO=<tomorrow>. blockStartISO=null, blockEndISO=null.",
            "Input: '30 min focus on the report today' → Tasks: 1. title 'focus on the report', dueDateISO=<today>. blockStartISO=null, blockEndISO=null.",
            "Input: '1-2 hours of refactor work tomorrow' → Tasks: 1. title 'refactor work', dueDateISO=<tomorrow>. blockStartISO=null, blockEndISO=null. The '1-2' is hours-of-duration, not 1pm-2pm.",
            "Input: 'an hour of code review' → Tasks: 1. title 'code review'. NO dueDateISO (no day reference). NO timeBlock.",

            "RULE — Empty / whitespace-only input → empty tasks.",
            "If the input text is empty, blank, or contains only punctuation/whitespace, return an empty tasks array. Do NOT regurgitate examples from these instructions.",
            "Input: '' → Tasks: empty.",
            "Input: '   \\n  ' → Tasks: empty.",

            "RULE — Past-tense reports stay zero, even with temporal qualifiers.",
            "Past-tense verbs followed by 'yesterday', 'this morning', 'last week' are still past-tense. The temporal qualifier does NOT make them future actions.",
            "Input: 'shipped the migration script yesterday, blast radius was small' → Tasks: empty. 'shipped' is past tense; 'yesterday' confirms it's done.",
            "Input: 'wrote the spec last week and it's been reviewed' → Tasks: empty."
        ]

        return lines
    }
}
