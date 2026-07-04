// Jotty/Inbox/CalendarInboxSource.swift
// The calendar concrete InboxSource (SC1/SC4/SC5, plan 11-02). Surfaces TODAY's
// external timed events — read on-device through the injected CalendarService
// seam (EventKit, no network) — as InboxItems carrying the plan-01 time-block +
// link-id payload, so an accepted item writes a `time:`/`cal_event:` task that
// links back to the existing event rather than creating a new one.
//
// Mirrors GitHubInboxSource's struct shape: injected collaborators, a pure map,
// and an isConfigured gate. Every collaborator is injectable, so the suite drives
// it hermetically with a FakeCalendarService + closures + a pinned now/timezone —
// touching no EventKit and firing no TCC prompt.
//
// Privacy gate (T-11-03): the source NEVER calls requestAccess(); it reads only
// the non-prompting access() and the enabled() toggle (OFF by default). Both are
// re-checked in fetchItems so a disabled/denied source does ZERO calendar reads.

import Foundation

/// Calendar inbox source: today's un-linked timed events → `InboxItem`s.
///
/// Conforms to `InboxSource`; `id` matches the `calendar` catalog entry. The five
/// collaborators are injected so the suite pins `now`/`timezone`, swaps in a
/// `FakeCalendarService`, and feeds `enabled`/`linkedEventIDs` closures directly.
struct CalendarInboxSource: InboxSource {

    // MARK: InboxSource identity (matches the `calendar` catalog entry)

    let id = "calendar"
    let displayName = "Calendar"
    /// Documented-disclosure string for the transparency list — this source reads
    /// on-device via EventKit and makes no network call.
    let endpointURL = "On-device (EventKit, no network)"

    // MARK: Injected collaborators

    private let calendar: any CalendarService
    /// Reads `AppConfig.calendarInboxEnabled` LIVE each call (toggle OFF by default).
    private let enabled: @Sendable () -> Bool
    /// Today's already-linked bare EventKit ids (SC4), re-read fresh each call.
    /// `@MainActor` (not `@Sendable`) so the read runs ON the main actor — awaiting
    /// it hops off-actor `fetchItems` to main, so it can never race main-actor
    /// `Store` writes; the isolation also makes the closure Sendable (WR-01).
    /// Takes the fetch instant so the linked-id read and the today-window share
    /// ONE clock read — no sub-ms midnight straddle, deterministic in tests (IN-01).
    private let linkedEventIDs: @MainActor (Date) async -> Set<String>
    private let now: @Sendable () -> Date
    private let timezone: TimeZone

    /// - Parameters:
    ///   - calendar: the non-prompting calendar seam; tests inject `FakeCalendarService`.
    ///   - enabled: live read of the calendar-inbox toggle.
    ///   - linkedEventIDs: today's linked event ids, so a linked event is never re-suggested.
    ///   - now: injected clock, pinned in tests.
    ///   - timezone: the store/menubar timezone used to compute the today window (never `.current`).
    init(calendar: any CalendarService,
         enabled: @escaping @Sendable () -> Bool,
         linkedEventIDs: @escaping @MainActor (Date) async -> Set<String>,
         now: @escaping @Sendable () -> Date,
         timezone: TimeZone) {
        self.calendar = calendar
        self.enabled = enabled
        self.linkedEventIDs = linkedEventIDs
        self.now = now
        self.timezone = timezone
    }

    // MARK: Configuration

    /// True iff the toggle is on AND the OS has granted full access. Uses only the
    /// non-prompting `access()` (never `requestAccess()`), so reading this property
    /// can never surface a TCC prompt — the privacy-gate mirror of GitHub's PAT gate.
    var isConfigured: Bool { enabled() && calendar.access() == .authorized }

    // MARK: Fetch

    /// Reads today's timed events through the seam and maps the un-linked survivors.
    /// Re-guards on `enabled()` (checked FIRST, short-circuiting before `access()`)
    /// AND `access()`, so a disabled or access-denied source performs ZERO
    /// `eventsInRange` calls and never prompts (SC5/T-11-03).
    func fetchItems() async throws -> [InboxItem] {
        guard enabled(), calendar.access() == .authorized else { return [] }  // SC5: no read when unconfigured

        // One clock read drives BOTH the today-window and the linked-id read (IN-01).
        let instant = now()

        // Today window [startOfDay(instant), +1d) in the INJECTED timezone — the same
        // calendar reloadCalendar uses; never `.current` (P3/I9).
        let cal = DailyFile.calendar(timezone: timezone)
        let start = cal.startOfDay(for: instant)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }

        // All-day rows are dropped upstream by CalendarEventMapper, so eventsInRange
        // only ever returns timed events — the source never filters isAllDay itself.
        let events = try await calendar.eventsInRange(start: start, end: end)

        let linked = await linkedEventIDs(instant)
        return events
            .filter { !linked.contains($0.id) }  // SC4: bare EventKit id, not the composite
            .map { event in
                InboxItem(
                    id: "\(id):\(event.id)",
                    sourceID: id,
                    title: event.title,
                    url: CalendarURL.show(for: event.start)?.absoluteString ?? "",  // "" → accept turns it nil (plan 04 P5)
                    timestamp: event.start,
                    rawText: event.title,
                    timeBlock: TimeBlock(start: event.start, end: event.end),
                    calEventID: event.id
                )
            }
    }
}
