import Foundation

/// Pure, conservative natural-language single-clock-time matcher (#time-reliability).
///
/// Given free text, finds the FIRST unambiguous single wall-clock time and returns its
/// matched substring range plus the 24-hour (hour, minute). This backfills the ONE gap the
/// typed-token parser (`CaptureTokenParser`) and the AI extractor both leave open: a bare
/// single time like "Call Asim at 9pm" that carries no `@`-token and no start-AND-end range.
///
/// The bar for a match is deliberately HIGH — a false positive silently blocks the wrong slot
/// on the user's calendar, which is far worse than a miss (the AI/range path still handles
/// true ranges, and the user can always add an `@time` token). It fires ONLY on a strong time
/// signal and refuses every ambiguous shape:
///
///   MATCHES (returns 24h hour/minute):
///     - `9pm` `9 pm` `9:30pm` `9:30 pm` `12am`  — 12-hour WITH am/pm
///     - `9:30` `17:00` `08:05`                  — HH:MM colon form (hour 0-23, min 0-59)
///     - `at 9pm` `at 5pm` `at 17:30`            — explicit `at ` prefix WITH am/pm or a colon
///
///   NEVER MATCHES (ambiguous / not a clock time):
///     - bare number, no am/pm, no colon: `section 9`, `call 9`, `item 5`, `at 5`
///     - durations: `2 hours`, `30 min`, `an hour`, `couple hours`, `1-2 hours`
///     - ranges: `1-2pm` (left to the AI/range path — never single-processed here)
///     - phone-like: `911`, `1-800`; money: `$9.99`; dates: `2026-07-10`; fractions: `9/10`
///
/// Pure and deterministic: `hour`/`minute` are computed from the text alone; timezone/asOf are
/// the caller's concern (they turn the (h,m) into a wall-clock instant on the target day). This
/// keeps the matcher exhaustively unit-testable with a big positive AND negative table.
enum NaturalTime {

    /// A single matched clock time: the substring range in the ORIGINAL string plus 24h time.
    struct Match: Equatable {
        let range: Range<String.Index>
        let hour: Int      // 0-23
        let minute: Int    // 0-59
    }

    /// Finds the first unambiguous single clock time in `text`, or nil. See type doc for the
    /// exact accepted/rejected grammar.
    static func firstMatch(in text: String) -> Match? {
        // ONE regex, alternation ordered MOST-SPECIFIC FIRST: the meridiem form must win over
        // the colon form so `9:30pm` reads as 21:30 (meridiem), not 09:30 (bare colon). Named
        // groups:
        //   meridiem:  merH=h  merM=mm(optional)  mer=am/pm
        //   colon:     colonH=HH  colonM=MM
        // Boundaries are hand-checked below (Swift regex `\b` is unicode-fuzzy around `:`),
        // so the pattern itself stays permissive and the guards do the rejecting.
        let pattern = /(?<merH>\d{1,2})(?::(?<merM>\d{2}))?\s?(?<mer>[ap]m)|(?<colonH>\d{1,2}):(?<colonM>\d{2})/
            .ignoresCase()

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let m = try? pattern.firstMatch(in: text[searchStart...]) {
            let range = m.range
            if let hm = classify(text, range: range,
                                 merH: m.merH, merM: m.merM, mer: m.mer,
                                 colonH: m.colonH, colonM: m.colonM) {
                return Match(range: range, hour: hm.hour, minute: hm.minute)
            }
            // Rejected candidate — advance past its first character and keep scanning so a
            // later valid time in the same string is still found (e.g. "911 then at 9pm").
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    // MARK: - Classification (pure guards)

    /// Validates one raw regex hit against the boundary + range rules, returning 24h (h,m) or nil.
    /// Captures are the named groups of the alternation (all optional — either branch fires).
    private static func classify(
        _ text: String, range: Range<String.Index>,
        merH: Substring?, merM: Substring?, mer: Substring?,
        colonH: Substring?, colonM: Substring?
    ) -> (hour: Int, minute: Int)? {
        // Reject if glued to a character that makes this NOT a standalone clock time:
        // a preceding `$` (money), or an adjacent `/` `-` `.` `:` `,` / digit on either side
        // (dates 2026-07-10, ranges 1-2pm, fractions 9/10, phone 1-800, decimals 9.99).
        if !boundariesClean(text, range) { return nil }

        // Meridiem branch (wins over colon): h(:mm)? am/pm.
        if let hStr = merH, let mer, let rawHour = Int(hStr) {
            let minute = merM.flatMap { Int($0) } ?? 0
            guard (1...12).contains(rawHour), (0...59).contains(minute) else { return nil }
            let hour: Int
            if mer.lowercased() == "pm" {
                hour = rawHour == 12 ? 12 : rawHour + 12
            } else {
                hour = rawHour == 12 ? 0 : rawHour
            }
            return (hour, minute)
        }

        // Colon branch: HH:MM, 24-hour as written.
        if let hStr = colonH, let mStr = colonM, let h = Int(hStr), let min = Int(mStr) {
            guard (0...23).contains(h), (0...59).contains(min) else { return nil }
            return (h, min)
        }

        return nil
    }

    /// The chars immediately before/after the match must not turn it into a date, range,
    /// money, phone number, or decimal. Rejects when either neighbor is a digit, or one of
    /// `/ - . : ,` (before OR after), or `$` (before).
    private static func boundariesClean(_ text: String, _ range: Range<String.Index>) -> Bool {
        let glue: Set<Character> = ["/", "-", ".", ":", ","]
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before == "$" || before.isNumber || glue.contains(before) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isNumber || glue.contains(after) { return false }
        }
        return true
    }
}
