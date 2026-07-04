import Foundation

/// Pure, timezone-pinned parser for typed time/due tokens in a MANUAL capture line (#8).
///
/// With no AI provider configured there is no due-date or time write path outside AI
/// extraction — "Call dentist @tomorrow @3pm" would otherwise commit as a bare task. This
/// scans a `- [ ]` task line for a small, documented token set and returns the clean title
/// plus any due date / time block, reusing the app's calendar factory + drop-default duration
/// so a manual time block is byte-for-byte what a canvas drop would produce.
///
/// Grammar (tokens are whitespace-delimited words, matched exactly, case-insensitive):
///   - `@3pm` `@9am` `@3:30pm`   → 12-hour time (hour 1–12, optional `:mm`, `am`/`pm`)
///   - `@15:00` `@9:30`          → 24-hour time (colon form)
///   - `@9` `@15`                → bare hour, 24-hour (so `@9` == 09:00, not 9pm)
///   - `@today` `@tomorrow`      → due date (+ the day for any `@time`)
///   - `@mon`..`@sun` `@friday`  → next matching weekday (today counts), same due/day role
///   - `due:fri` `due:tomorrow`  → due date (day words, same set as `@`)
///   - `due:2026-07-10`         → due date (ISO `yyyy-MM-dd`)
///
/// Rules: recognized tokens are stripped from the title (no leftover token text, no double
/// spaces); a word that merely starts with `@`/`due:` but doesn't match the grammar is left
/// untouched (conservative — `email@work.com`, `due:soon` stay in the title); a line with no
/// recognized token passes through unchanged with nil due/time (today's behavior preserved);
/// if stripping the tokens would empty the title, the line is treated as token-free so no
/// empty task is produced. `asOf`/`timezone` are injected so the suite pins every case.
enum CaptureTokenParser {

    struct Result: Equatable {
        let cleanTitle: String
        let dueDate: Date?
        let timeBlock: TimeBlock?
    }

    /// Manual time block length — the SAME constant a canvas/menubar drop uses (#8: "default
    /// duration consistent with the app's drop default"), so both surfaces agree.
    static let defaultDurationMinutes = CanvasLayout.defaultDropDurationMinutes

    /// Gregorian weekday numbers (Sunday = 1 … Saturday = 7) keyed by abbreviation + full name.
    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tuesday": 3,
        "wed": 4, "wednesday": 4,
        "thu": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    static func parse(_ input: String, asOf: Date, timezone: TimeZone) -> Result {
        let calendar = DailyFile.calendar(timezone: timezone)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        var titleWords: [String] = []
        var timeHM: (hour: Int, minute: Int)?
        var dayDate: Date?
        var sawToken = false

        // Whitespace-delimited scan; the title rebuilds with single spaces (collapses runs).
        for word in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            let lower = word.lowercased()

            if lower.hasPrefix("@") {
                let value = String(lower.dropFirst())
                if let hm = matchTime(value) {
                    timeHM = hm; sawToken = true; continue
                }
                if let d = resolveDay(value, asOf: asOf, calendar: calendar) {
                    dayDate = d; sawToken = true; continue
                }
            } else if lower.hasPrefix("due:") {
                let value = String(lower.dropFirst(4))
                if let d = resolveDay(value, asOf: asOf, calendar: calendar) {
                    dayDate = d; sawToken = true; continue
                }
            }

            titleWords.append(word)
        }

        var cleanTitle = titleWords.joined(separator: " ")

        // Natural-language single clock time fallback (#time-reliability): fires ONLY when no
        // typed `@time` token was found, so every existing @-token path stays byte-identical
        // (`@9pm` sets timeHM above and skips this). A bare "Call Asim at 9pm" then still gets a
        // block + a cleaned title. Conservative by construction (see NaturalTime): a plain number
        // or duration never matches, so a non-time line is returned unchanged.
        var naturalSaw = false
        if timeHM == nil, let nat = NaturalTime.firstMatch(in: cleanTitle) {
            let stripped = NaturalTime.strippedTitle(cleanTitle, removing: nat.range)
            if !stripped.isEmpty {
                cleanTitle = stripped
                timeHM = (nat.hour, nat.minute)
                naturalSaw = true
            }
        }

        // No token, or stripping tokens emptied the title → preserve today's bare-task behavior.
        guard sawToken || naturalSaw, !cleanTitle.isEmpty else {
            return Result(cleanTitle: trimmed, dueDate: nil, timeBlock: nil)
        }

        var timeBlock: TimeBlock?
        if let hm = timeHM {
            let base = dayDate ?? calendar.startOfDay(for: asOf)
            if let start = calendar.date(bySettingHour: hm.hour, minute: hm.minute,
                                         second: 0, of: base) {
                let end = start.addingTimeInterval(TimeInterval(defaultDurationMinutes * 60))
                timeBlock = TimeBlock(start: start, end: end)
            }
        }

        // dueDate is set only when a day/due token named a day; a bare `@time` schedules the
        // block for today without also stamping a due date (mirrors the AI path's independence).
        return Result(cleanTitle: cleanTitle, dueDate: dayDate, timeBlock: timeBlock)
    }

    // MARK: - Matchers (pure)

    /// Parses the value after `@` as a wall-clock time, returning 24-hour (hour, minute) or nil.
    /// `value` is already lowercased.
    private static func matchTime(_ value: String) -> (hour: Int, minute: Int)? {
        // Anchored so a partial match (e.g. a URL fragment) never counts as a token.
        // Inlined (not a static `let`): a stored `Regex` is non-Sendable under Swift 6.
        guard let m = value.wholeMatch(of: /^(\d{1,2})(?::(\d{2}))?(am|pm)?$/),
              let rawHour = Int(m.1) else { return nil }
        let minute = m.2.flatMap { Int($0) } ?? 0
        guard (0...59).contains(minute) else { return nil }

        if let meridiem = m.3 {
            guard (1...12).contains(rawHour) else { return nil }
            let hour: Int
            if meridiem == "pm" {
                hour = rawHour == 12 ? 12 : rawHour + 12
            } else {
                hour = rawHour == 12 ? 0 : rawHour   // am
            }
            return (hour, minute)
        }

        guard (0...23).contains(rawHour) else { return nil }
        return (rawHour, minute)
    }

    /// Resolves a day word (`today`/`tomorrow`/weekday) or an ISO `yyyy-MM-dd` to start-of-day,
    /// or nil if it matches neither. `value` is already lowercased.
    private static func resolveDay(_ value: String, asOf: Date, calendar: Calendar) -> Date? {
        let todayStart = calendar.startOfDay(for: asOf)

        if value == "today" { return todayStart }
        if value == "tomorrow" {
            return calendar.date(byAdding: .day, value: 1, to: todayStart)
        }
        if let target = weekdays[value] {
            // Nearest matching weekday, counting today (0…6 days out).
            for offset in 0...6 {
                if let d = calendar.date(byAdding: .day, value: offset, to: todayStart),
                   calendar.component(.weekday, from: d) == target {
                    return d
                }
            }
            return nil
        }
        if value.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/) != nil {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: value) { return calendar.startOfDay(for: d) }
        }
        return nil
    }
}
