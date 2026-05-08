import Foundation
import FoundationModels

@Generable
struct ExtractedTaskAI: Equatable {
    @Guide(description: "Verbatim or near-verbatim title from the user's input. Do not rewrite, do not corporatize, do not 'outcome-orient'. Preserve abbreviations and modifiers exactly.")
    var title: String

    @Guide(description: "ISO-8601 calendar date 'yyyy-MM-dd' for an explicit deadline only ('by Friday', 'due tomorrow', 'before EOM'). Omit for vague phrasing like 'soon', 'later', 'eventually'.")
    var dueDateISO: String?

    @Guide(description: "ISO-8601 datetime with timezone offset for the start of the clock-time block. Set ONLY when the user named both a start AND an end clock time ('1-2pm', 'from 9 to 11'). Omit for bare time mentions like 'at 5pm' or durations like '1-2 hours of focus'.")
    var blockStartISO: String?

    @Guide(description: "ISO-8601 datetime with timezone offset for the end of the clock-time block. Required iff blockStartISO is set.")
    var blockEndISO: String?
}

@Generable
struct ExtractionResultAI: Equatable {
    @Guide(description: "All actionable tasks found in the input. Empty array if input is venting, observations, or past-tense prose.", .maximumCount(20))
    var tasks: [ExtractedTaskAI]
}
