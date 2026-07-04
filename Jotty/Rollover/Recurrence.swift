import Foundation

/// Pure recurrence rule for repeating tasks (SC2 / CALX-02), mirroring the
/// `CalendarDrift` idiom: a value type with no I/O, exhaustively unit-testable.
///
/// The rule is persisted as the value part of the `recur:<rule>` markdown token
/// (`daily` / `weekly` / `weekday` / `custom:1,3,5`). Weekday integers are the
/// gregorian `Calendar.component(.weekday, ...)` values: 1=Sunday … 7=Saturday.
///
/// `isDue` operates purely on the passed `day` + `calendar` — never `Date()`-
/// relative — so callers pin the model timezone via a gregorian calendar
/// (`RolloverService.calendar()` idiom) and weekday math stays correct across
/// timezones and region calendars (RESEARCH Pitfall: timezone weekday math).
enum Recurrence: Equatable, Sendable {
    case daily
    /// Repeats weekly on a specific gregorian weekday (1=Sun…7=Sat).
    ///
    /// The associated value is the weekday the user CHOSE the rule on (sweep INFO):
    /// serialized as `weekly:<wd>`. A `nil` value is a legacy bare `weekly` token
    /// (pre-sweep, or hand-edited) which falls back to the template's createdAt
    /// weekday — the old behavior — so on-disk files stay backward compatible.
    case weekly(Int?)
    case weekday
    /// Repeats on the listed gregorian weekdays (1=Sun…7=Sat).
    case custom(Set<Int>)

    /// Parses the value part of a `recur:` token.
    ///
    /// `"custom:<csv>"` accepts a comma-separated list of weekday ints (empties
    /// ignored, duplicates deduped by the `Set`). Returns `nil` for an unknown
    /// rule, an empty custom set, or any component that is not an int in 1...7 —
    /// a hand-edited malformed value degrades to a non-recurring task rather
    /// than crashing or instancing (threat T-8-02).
    static func parse(_ s: String) -> Recurrence? {
        switch s {
        case "daily": return .daily
        case "weekly": return .weekly(nil)   // back-compat: bare token → createdAt-weekday fallback
        case "weekday": return .weekday
        default:
            if s.hasPrefix("weekly:") {
                let wd = s.dropFirst("weekly:".count)
                guard let n = Int(wd), (1...7).contains(n) else { return nil }
                return .weekly(n)
            }
            guard s.hasPrefix("custom:") else { return nil }
            let csv = s.dropFirst("custom:".count)
            var days = Set<Int>()
            for part in csv.split(separator: ",", omittingEmptySubsequences: true) {
                guard let n = Int(part), (1...7).contains(n) else { return nil }
                days.insert(n)
            }
            return days.isEmpty ? nil : .custom(days)
        }
    }

    /// The VALUE part of the `recur:` token (no `recur:` prefix).
    ///
    /// Custom weekdays serialize as a SORTED ascending csv (`custom:1,3,5`) so
    /// `parse(serialize())` round-trips deterministically and the on-disk token
    /// is stable across runs.
    func serialize() -> String {
        switch self {
        case .daily: return "daily"
        case .weekly(let wd):
            // Explicit weekday → `weekly:<wd>`; a legacy nil stays the bare `weekly`
            // token so files written before this fix round-trip unchanged.
            if let wd { return "weekly:\(wd)" }
            return "weekly"
        case .weekday: return "weekday"
        case .custom(let days):
            return "custom:" + days.sorted().map(String.init).joined(separator: ",")
        }
    }

    /// Whether an instance of this rule is due on `day`.
    ///
    /// - Parameters:
    ///   - day: the day being tested (any instant within it; the weekday is
    ///     resolved through `calendar`).
    ///   - templateWeekday: the template task's creation weekday (1=Sun…7=Sat),
    ///     used only by `.weekly` (repeat on the same weekday as the template).
    ///   - calendar: a timezone-pinned gregorian calendar; the weekday is taken
    ///     in THIS calendar's timezone, never the system's.
    func isDue(on day: Date, templateWeekday: Int, calendar: Calendar) -> Bool {
        let wd = calendar.component(.weekday, from: day)
        switch self {
        case .daily: return true
        case .weekday: return (2...6).contains(wd)
        // Explicit chosen weekday when set; else the legacy createdAt-weekday fallback.
        case .weekly(let target): return wd == (target ?? templateWeekday)
        case .custom(let days): return days.contains(wd)
        }
    }
}
