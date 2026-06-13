import Foundation

/// Pure decision functions behind SC5 (pre-commit conflict warning) and SC4 (open-time
/// drift detection), isolated from EventKit and I/O so they are exhaustively unit-testable
/// against value types.
///
/// Nothing here touches `EKEventStore`, the disk, or the UI: it operates only on
/// `CalendarEvent` / `Todo` / `TimeBlock` value types. Plan 05 calls `conflicts(...)` to gate
/// the capture commit; the AppDelegate open hook + menubar prompt (plan 07) call
/// `driftedTasks(...)`. Both reuse `sanitize(title:)` so the title written at create time and
/// the title compared at drift time agree (otherwise SC4 false-positives every open).
enum CalendarDrift {

    // MARK: - Conflict detection (SC5)

    /// Returns the events whose interval strictly overlaps the candidate window `[start, end)`.
    ///
    /// Strict overlap means a positive-length intersection: `event.start < end && event.end > start`.
    /// Touching endpoints (an event that ends exactly at `start`, or starts exactly at `end`) do
    /// NOT conflict. A zero-length candidate window never conflicts. Results are returned sorted
    /// by start for a stable order regardless of input order.
    ///
    /// - Parameters:
    ///   - start: candidate window start (inclusive).
    ///   - end: candidate window end (exclusive).
    ///   - events: events to test against (typically a day's events from the store).
    /// - Returns: the overlapping events, sorted by start; empty when none overlap.
    static func conflicts(start: Date, end: Date, against events: [CalendarEvent]) -> [CalendarEvent] {
        // A non-positive candidate window has no positive-length intersection with anything.
        guard start < end else { return [] }
        return events
            .filter { $0.start < end && $0.end > start }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Drift detection (SC4)

    /// The outcome of comparing linked tasks against the calendar store.
    ///
    /// `drifted` pairs each task whose linked event still exists but differs (title, or start/end
    /// beyond the 60s tolerance) with that event. `missing` lists tasks whose linked event id is
    /// absent from the store (deleted in Calendar) - these drive the SC3 recreate / SC4 awareness
    /// path rather than a field-sync prompt.
    struct DriftResult {
        var drifted: [(task: Todo, event: CalendarEvent)]
        var missing: [Todo]
    }

    /// Tolerance (seconds) below which a start/end shift is NOT considered drift.
    ///
    /// Claude's-discretion granularity per CONTEXT: a sub-minute jitter (eg. rounding between the
    /// markdown wall-clock and the EKEvent instant) must not trigger a prompt on every open.
    static let toleranceSeconds: TimeInterval = 60

    /// Compares each linked task against the events fetched from the store.
    ///
    /// Only tasks with BOTH a `calEventID` and a `timeBlock` are candidates; others are ignored.
    /// For each candidate the event is matched by id:
    ///   - no match -> the task is `missing` (deleted in Calendar).
    ///   - match -> drifted when the sanitized task text differs from the event title, OR the
    ///     start/end differ by at least `toleranceSeconds`. Comparison is on absolute `Date`
    ///     instants only (RESEARCH Pitfall 4 - never wall-clock strings), so timezone/DST shifts
    ///     do not produce false drift.
    ///
    /// Title comparison uses the shared `sanitize(title:)` so a task text with markdown that was
    /// stripped when the event was created does not report false drift on the next open.
    ///
    /// - Parameters:
    ///   - tasks: the tasks to check (today+future linked tasks per CONTEXT scope).
    ///   - events: the events currently in the store for the relevant range.
    /// - Returns: a `DriftResult` splitting drifted (with their events) from missing tasks.
    static func driftedTasks(_ tasks: [Todo], against events: [CalendarEvent]) -> DriftResult {
        var drifted: [(task: Todo, event: CalendarEvent)] = []
        var missing: [Todo] = []

        for task in tasks {
            guard let calEventID = task.calEventID, let tb = task.timeBlock else { continue }
            guard let event = events.first(where: { $0.id == calEventID }) else {
                missing.append(task)
                continue
            }
            let titleChanged = sanitize(title: task.text) != event.title
            let startShifted = abs(event.start.timeIntervalSince(tb.start)) >= toleranceSeconds
            let endShifted = abs(event.end.timeIntervalSince(tb.end)) >= toleranceSeconds
            if titleChanged || startShifted || endShifted {
                drifted.append((task: task, event: event))
            }
        }
        return DriftResult(drifted: drifted, missing: missing)
    }

    // MARK: - Shared title sanitize

    /// Strips markdown emphasis, inline code, leading heading markers, and control characters
    /// from a task's text to produce a plain calendar-event title.
    ///
    /// This is the single source of truth for the event title: plan 05 reuses it for
    /// `createEvent`'s title so the value stored in the calendar matches what drift detection
    /// recomputes from the task text. Keeping create and compare on the same function is what
    /// prevents SC4 from false-positiving on every open. It also strips control characters so a
    /// crafted task text cannot inject control sequences into the EKEvent title (threat T-5-07).
    ///
    /// The function is idempotent: sanitizing an already-sanitized title returns it unchanged.
    static func sanitize(title: String) -> String {
        var s = title

        // Remove control characters (incl. tabs/newlines mapped to spaces first so words stay
        // separated, then other control chars dropped).
        s = s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })

        // Strip leading heading markers (`#`, `##`, ... possibly followed by spaces).
        s = s.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)

        // Strip inline code backticks.
        s = s.replacingOccurrences(of: "`", with: "")

        // Strip bold/italic emphasis markers (`**`, `*`, `__`, `_`). Order: doubles before
        // singles so `**x**` and `__x__` collapse cleanly.
        for marker in ["**", "__", "*", "_"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }

        // Collapse runs of whitespace to a single space and trim.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
