import Foundation

enum ISOTaskMapper {
    static func map(_ ai: [ExtractedTaskAI], in tz: TimeZone) -> [ExtractedTask] {
        let dayFmt = DateFormatter()
        dayFmt.calendar = DailyFile.calendar(timezone: tz)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = tz
        dayFmt.dateFormat = "yyyy-MM-dd"

        return ai.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            // Deliberately STRICT (yyyy-MM-dd only): models hallucinate full datetimes
            // into this field for undated inputs, and the strict parse rejecting them
            // is what keeps "look into the auth bug" from growing a spurious due date
            // (the AppleFM subset suite pins this).
            let due = item.dueDateISO.flatMap { dayFmt.date(from: $0) }

            let block: TimeBlock? = {
                guard let s = item.blockStartISO,
                      let e = item.blockEndISO,
                      let start = flexibleDateTime(s, in: tz),
                      let end = flexibleDateTime(e, in: tz),
                      end > start else { return nil }
                return TimeBlock(start: start, end: end)
            }()

            return ExtractedTask(
                title: title,
                dueDate: due,
                timeBlock: block,
                calendarBlock: block != nil
            )
        }
    }

    /// Parses the model's datetime with a tolerance chain: strict internet-datetime,
    /// then fractional seconds, then the zone-less local forms (with and without
    /// seconds), interpreted in the user's timezone. LLMs routinely emit
    /// `…T15:00:00.000+10:00`, `…T15:00:00` (no offset), or `…T15:00` even when the
    /// prompt's example shows the strict form — the old single strict formatter
    /// silently dropped the whole time block on every such variant, so a
    /// "block 1-2pm" capture lost its time with no signal to the user.
    static func flexibleDateTime(_ value: String, in tz: TimeZone) -> Date? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime, .withTimeZone]
        if let d = strict.date(from: value) { return d }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withTimeZone, .withFractionalSeconds]
        if let d = fractional.date(from: value) { return d }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            let f = DateFormatter()
            f.calendar = DailyFile.calendar(timezone: tz)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = format
            if let d = f.date(from: value) { return d }
        }
        return nil
    }
}
