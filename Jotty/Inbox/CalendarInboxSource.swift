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

/// A linked-task reference for the SC4 dedup filter: the task's bare `cal_event:` id plus
/// its `time:` block start. Recurring occurrences share ONE bare EventKit id, so the start
/// is what scopes a link to a single occurrence — filtering on the bare id alone hid every
/// occurrence of a series the moment one was linked. A nil start (a linked task missing its
/// time block, e.g. after a failed disk write) conservatively matches every occurrence.
struct LinkedEventRef: Hashable, Sendable {
    let eventKitID: String
    let start: Date?

    init(eventKitID: String, start: Date?) {
        self.eventKitID = eventKitID
        self.start = start
    }

    /// True when this link claims `event`: same bare id, and the task's block start is
    /// within the shared drift tolerance of the occurrence start (the same 60s window
    /// `CalendarDrift` treats as "the same time"), or the link carries no start at all.
    func matches(_ event: CalendarEvent) -> Bool {
        guard eventKitID == event.eventKitID else { return false }
        guard let start else { return true }
        return abs(start.timeIntervalSince(event.start)) < CalendarDrift.toleranceSeconds
    }
}

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
    /// Today's already-linked (bare id, block start) refs (SC4), re-read fresh each call.
    /// `@MainActor` (not `@Sendable`) so the read runs ON the main actor — awaiting
    /// it hops off-actor `fetchItems` to main, so it can never race main-actor
    /// `Store` writes; the isolation also makes the closure Sendable (WR-01).
    /// Takes the fetch instant so the linked-id read and the today-window share
    /// ONE clock read — no sub-ms midnight straddle, deterministic in tests (IN-01).
    private let linkedEventIDs: @MainActor (Date) async -> [LinkedEventRef]
    private let now: @Sendable () -> Date
    private let timezone: TimeZone
    /// Live read of `AppConfig.visibleCalendarIDs` (nil = all): an event on a calendar
    /// the user HID from display should not resurface as a task suggestion.
    private let visibleCalendarIDs: @Sendable () -> [String]?

    /// - Parameters:
    ///   - calendar: the non-prompting calendar seam; tests inject `FakeCalendarService`.
    ///   - enabled: live read of the calendar-inbox toggle.
    ///   - linkedEventIDs: today's linked (id, start) refs, so a linked occurrence is never
    ///     re-suggested — while OTHER occurrences of the same recurring series still are.
    ///   - now: injected clock, pinned in tests.
    ///   - timezone: the store/menubar timezone used to compute the today window (never `.current`).
    ///   - visibleCalendarIDs: live read of the display visibility filter (default: all).
    init(calendar: any CalendarService,
         enabled: @escaping @Sendable () -> Bool,
         linkedEventIDs: @escaping @MainActor (Date) async -> [LinkedEventRef],
         now: @escaping @Sendable () -> Date,
         timezone: TimeZone,
         visibleCalendarIDs: @escaping @Sendable () -> [String]? = { nil }) {
        self.calendar = calendar
        self.enabled = enabled
        self.linkedEventIDs = linkedEventIDs
        self.now = now
        self.timezone = timezone
        self.visibleCalendarIDs = visibleCalendarIDs
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
        // The display-visibility filter applies here too: a hidden calendar's events
        // must not resurface as suggestions.
        let events = try await calendar.eventsInRange(start: start, end: end)
            .visible(in: visibleCalendarIDs())

        let linked = await linkedEventIDs(instant)
        return events
            // SC4: per-OCCURRENCE dedup — a ref claims one occurrence (bare id + nearby
            // start), so linking the 09:00 standup still suggests the 13:00 one.
            .filter { event in !linked.contains { $0.matches(event) } }
            .map { event in
                InboxItem(
                    // `event.id` is the occurrence-unique composite, so accepting or
                    // dismissing one occurrence of a recurring series never records a
                    // state that hides its siblings.
                    id: "\(id):\(event.id)",
                    sourceID: id,
                    title: event.title,
                    url: CalendarURL.show(for: event.start)?.absoluteString ?? "",  // "" → accept turns it nil (plan 04 P5)
                    timestamp: event.start,
                    rawText: event.title,
                    timeBlock: TimeBlock(start: event.start, end: event.end),
                    calEventID: event.eventKitID  // markdown link stays the BARE id
                )
            }
    }
}
