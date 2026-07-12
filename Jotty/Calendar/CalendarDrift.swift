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
    /// Only NOT-DONE tasks with BOTH a `calEventID` and a `timeBlock` are candidates; others
    /// are ignored. A completed task is settled — editing its (still-linked) event must not
    /// prompt a sync that rewrites the done task's text/time, and a deleted event on a done
    /// task needs no cleanup (rollover clears calendar links).
    ///
    /// For each candidate the event is matched by the BARE EventKit id (`eventKitID`, the
    /// value `cal_event:` stores). Recurring series share one `eventKitID` across every
    /// occurrence, so on a multi-match the occurrence whose start is NEAREST the task's block
    /// is compared — matching an arbitrary occurrence false-drifted against the wrong time and
    /// a confirmed "Sync" rewrote the task to that wrong occurrence's slot:
    ///   - no match at all -> the task is `missing` (deleted in Calendar).
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
            guard !task.done else { continue }
            guard let calEventID = task.calEventID, let tb = task.timeBlock else { continue }
            let occurrences = events.filter { $0.eventKitID == calEventID }
            guard let event = occurrences.min(by: {
                abs($0.start.timeIntervalSince(tb.start)) < abs($1.start.timeIntervalSince(tb.start))
            }) else {
                missing.append(task)
                continue
            }
            // Compare sanitized-vs-sanitized (WR-04): create writes `sanitize(text)` as the
            // event title and SC4 sync stores `sanitize(event.title)` back, so comparing both
            // sides through the same function is what keeps the round-trip stable. Comparing
            // the raw event title would re-drift forever when the event title itself carries
            // markdown-significant characters.
            let titleChanged = sanitize(title: task.text) != sanitize(title: event.title)
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
    // MARK: - TZ-shift drift partition (roadmap 3.3)

    /// The split of drifted pairs after a live timezone change (design note
    /// 2026-07-12): `tzShift` pairs moved by exactly the zone-offset delta —
    /// artifacts of re-anchoring wall-clock tokens in the new zone, handled by
    /// the ONE bulk prompt ("times moved with you" vs "keep appointment times").
    /// `other` pairs are genuine user drift and take the normal per-set prompt.
    struct TZShiftPartition {
        var tzShift: [(task: Todo, event: CalendarEvent)]
        var other: [(task: Todo, event: CalendarEvent)]
    }

    /// Classifies each drifted pair against the zone change `from → to`.
    /// TZ-shift iff `event.start − block.start` is within `toleranceSeconds`
    /// of the PER-BLOCK offset delta — `to.offset(at: block.start) −
    /// from.offset(at: block.start)` — because the re-anchor shift depends on
    /// both zones' rules at the block's own date, not at "now" (review F2:
    /// Sydney→LA is −17h for a July block but −18h for an October one; a
    /// Brisbane→Sydney change is offset-identical in July yet shifts every
    /// post-DST block +1h and must still reach the bulk prompt).
    ///
    /// A zero per-block delta means that block did not move — its drift is
    /// genuine, so ordinary drift can never be silently bulk-synced. A pair
    /// without a time block falls through defensively (driftedTasks shouldn't
    /// produce one). Known, accepted misclassifications: a user who genuinely
    /// moved an event by exactly the zone delta lands in the bulk prompt (the
    /// prompt shows the times; the user still chooses), and a pair with BOTH a
    /// TZ shift and a title edit is bulk-handled on time only — the title
    /// drift re-detects on the next open (idempotent).
    static func partitionForTZShift(_ drifted: [(task: Todo, event: CalendarEvent)],
                                    from: TimeZone, to: TimeZone) -> TZShiftPartition {
        var result = TZShiftPartition(tzShift: [], other: [])
        for pair in drifted {
            guard let block = pair.task.timeBlock else {
                result.other.append(pair)
                continue
            }
            let perBlockDelta = TimeInterval(
                to.secondsFromGMT(for: block.start) - from.secondsFromGMT(for: block.start))
            let instantDelta = pair.event.start.timeIntervalSince(block.start)
            if perBlockDelta != 0, abs(instantDelta - perBlockDelta) <= toleranceSeconds {
                result.tzShift.append(pair)
            } else {
                result.other.append(pair)
            }
        }
        return result
    }

    static func sanitize(title: String) -> String {
        var s = title

        // Remove control characters (incl. tabs/newlines mapped to spaces first so words stay
        // separated, then other control chars dropped).
        s = s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })

        // Strip inline code backticks.
        s = s.replacingOccurrences(of: "`", with: "")

        // Strip bold/italic emphasis markers (`**`, `*`, `__`, `_`). Order: doubles before
        // singles so `**x**` and `__x__` collapse cleanly.
        for marker in ["**", "__", "*", "_"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }

        // Collapse runs of whitespace to a single space and trim, so a `#` that only became
        // leading after the backtick/emphasis/whitespace steps above is now truly at the start.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)

        // Strip leading heading markers (`#`, `##`, ... possibly followed by spaces) LAST
        // (sweep WR): running this BEFORE the steps above made sanitize non-idempotent —
        // a `#` exposed by backtick/emphasis/whitespace stripping (`**#1**`, `` `#tag` ``,
        // `  # x`) survived the first pass but was stripped on the second, causing perpetual
        // false drift and silent loss of the user's `#`. Placing it after every exposing step
        // makes sanitize a fixed point. Re-trim in case the marker left trailing space.
        s = s.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
