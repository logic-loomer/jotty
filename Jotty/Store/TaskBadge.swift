import Foundation

/// Pure, timezone-pinned formatters + derivations for task-metadata badges (#3).
///
/// Hoisted from the two divergent renderers that used to each carry their own copy
/// (`ReviewListView.formatDue`/`formatTimeBlock` and `CommandBarView.trailingBadge`)
/// so the menubar list, review list, and command bar all render the SAME strings.
///
/// No I/O and no `Date()` inside — every function is `asOf`-/`calendar`-relative, so
/// the suite pins them deterministically (mirrors the `CalendarDrift`/`Recurrence`
/// value-type idiom).
enum TaskBadge {

    /// Compact start-of-block pill, `HH:mm` (zero-padded 24h), timezone-pinned.
    /// The menubar list + command-bar trailing badge both render this.
    static func timeBlockPill(_ tb: TimeBlock, timezone: TimeZone) -> String {
        formatter(timezone: timezone, format: "HH:mm").string(from: tb.start)
    }

    /// Full time-block range for the review/emoji surface: `today HH:mm–HH:mm` on
    /// the current day, else `EEE HH:mm–HH:mm`.
    static func timeBlockLabel(_ tb: TimeBlock, asOf: Date, calendar: Calendar) -> String {
        let tz = calendar.timeZone
        let time = formatter(timezone: tz, format: "HH:mm")
        let range = "\(time.string(from: tb.start))–\(time.string(from: tb.end))"
        if calendar.isDate(tb.start, inSameDayAs: asOf) {
            return "today \(range)"
        }
        return "\(formatter(timezone: tz, format: "EEE").string(from: tb.start)) \(range)"
    }

    /// Relative due label: `today` / `tomorrow` / full weekday (2–6 days out) /
    /// `MMM d` beyond a week (or in the past).
    static func dueLabel(_ date: Date, asOf: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: asOf)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        let tz = calendar.timeZone
        switch days {
        case 0:      return "today"
        case 1:      return "tomorrow"
        case 2...6:  return formatter(timezone: tz, format: "EEEE").string(from: date)
        default:     return formatter(timezone: tz, format: "MMM d").string(from: date)
        }
    }

    /// True when `task` is past due: not done, has a `dueDate` whose DAY is strictly
    /// before `asOf`'s day. Day-boundary compare — a task due TODAY is NOT overdue.
    static func isOverdue(_ task: Todo, asOf: Date, calendar: Calendar) -> Bool {
        guard !task.done, let due = task.dueDate else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: asOf)
    }

    /// SF Symbol for a recurring task: `repeat` for a template (carries a rule),
    /// `repeat.circle` for a generated instance (`recurSrc` marker); nil otherwise.
    static func recurringGlyph(_ task: Todo) -> String? {
        if task.recur != nil { return "repeat" }
        if task.recurSrc != nil { return "repeat.circle" }
        return nil
    }

    /// POSIX-locale, timezone-pinned formatter so weekday/month names and hour
    /// padding are stable across regions and test hosts.
    private static func formatter(timezone: TimeZone, format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timezone
        f.dateFormat = format
        return f
    }
}
