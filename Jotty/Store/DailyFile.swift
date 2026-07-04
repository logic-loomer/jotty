import Foundation

enum DailyFile {
    /// The ONE fixed-format day formatter for every `yyyy-MM-dd` machine key
    /// the app writes or reads: day-file NAMES (`url`), the filename parse
    /// (`Store.allDayDates`), and — via `RolloverService.dayFormatter()` — the
    /// `recur_src` day key and the rollover state file. Pinned to `en_US_POSIX`
    /// plus an explicit Gregorian calendar (the WR-05 idiom): an unpinned
    /// formatter under a non-Gregorian region calendar (Thai Buddhist, Japanese
    /// era) renders an era-shifted year — e.g. `2569-07-03.md` — which the
    /// pinned parse then reads as a completely different day, silently killing
    /// the recurrence template scan and forking templates via orphan promotion.
    /// Writer and parser share THIS builder so asymmetry is impossible by
    /// construction.
    static func dayFormatter(timezone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar(timezone: timezone)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezone
        return f
    }

    /// The ONE Gregorian calendar factory: an explicit `.gregorian` identifier
    /// pinned to `timezone` (same discipline as `dayFormatter`). Replaces the
    /// ~18 inline `var cal = Calendar(identifier: .gregorian); cal.timeZone = tz`
    /// sites across the app so a FORGOTTEN `timeZone` — a silent day-boundary
    /// bug (startOfDay / weekday / date-add landing on the wrong calendar day) —
    /// is impossible by construction. Callers that only need day arithmetic pass
    /// the store/menubar `timezone`; formatter `.calendar` assignments pass the
    /// formatter's own zone.
    static func calendar(timezone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timezone
        return c
    }

    static func url(in folder: URL, on date: Date, timezone: TimeZone) -> URL {
        let fmt = dayFormatter(timezone: timezone)
        return folder.appendingPathComponent("\(fmt.string(from: date)).md")
    }
}
