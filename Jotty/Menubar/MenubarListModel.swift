// Jotty/Menubar/MenubarListModel.swift
// The menubar popover's view model, split out of MenubarListView.swift (which had
// grown past 2,400 lines of model + views in one file). Pure file move — the type,
// its API, and its behavior are unchanged; MenubarListView and the canvas/command
// bar keep observing the same class.

import AppKit
import SwiftUI

@MainActor
final class MenubarListModel: ObservableObject {
    @Published private(set) var tasks: [Todo] = []
    @Published private(set) var dateLabel: String = ""
    @Published private(set) var leftovers: [Todo] = []
    @Published private(set) var todayTasks: [Todo] = []
    @Published private(set) var leftoversCollapsed: Bool = false
    /// Collapse state for the "Done · N" group of completed tasks (#4), mirroring
    /// `leftoversCollapsed`: day-keyed, persisted, reloaded each `reload`.
    @Published private(set) var doneCollapsed: Bool = false

    /// The task row to spotlight on the current popover render (Phase 9 SC3 —
    /// the command bar's "open the dropdown with task X highlighted" seam).
    /// Set by `MenubarController.showPopover(highlighting:)` AFTER its reload
    /// (reload clears this at entry, so set-then-reload would drop it); the view
    /// observes it for scroll-to + a fading row wash, then calls
    /// `clearHighlight()`. An id not present in any partition is harmless — the
    /// view finds no row and the next reload clears it.
    @Published private(set) var highlightedTaskID: String?

    /// Today's timed calendar events for the read-only menubar section (SC2).
    /// Empty when no service is injected or access is denied; the service already
    /// filters all-day events and sorts by start (plan 03). UNFILTERED by calendar
    /// visibility — the drift pass and conflict copy need the full set; views render
    /// `visibleCalendarEvents`.
    @Published private(set) var calendarEvents: [CalendarEvent] = []
    /// Today's ALL-DAY events for the chip row (deadlines, PTO, holidays) — the rows
    /// the timed fetch deliberately drops. Read-only signal, never conflict material.
    @Published private(set) var allDayEvents: [CalendarEvent] = []
    /// True when calendar access is denied/restricted; the view degrades to a
    /// one-line affordance instead of rows (graceful degradation, never crashes).
    @Published private(set) var calendarAccessDenied: Bool = false

    /// The DISPLAY set for the menubar section + canvas: `calendarEvents` through the
    /// Settings → Calendar visibility filter (nil = all). Live-read so a Settings
    /// toggle takes effect on the next render with no reload.
    var visibleCalendarEvents: [CalendarEvent] {
        calendarEvents.visible(in: configStore?.config.visibleCalendarIDs)
    }
    /// The display set for the all-day chip row, same visibility filter.
    var visibleAllDayEvents: [CalendarEvent] {
        allDayEvents.visible(in: configStore?.config.visibleCalendarIDs)
    }

    /// One-time "Also delete the calendar event?" prompt (SC3). Set only when a
    /// linked task is deleted and `deleteCalendarEventWithTask` is still nil
    /// (unanswered); the task is already removed from markdown by then.
    @Published var deletePrompt: DeletePrompt?
    /// Open-time drift prompt (SC4): the linked tasks whose calendar event changed
    /// externally, offered for a calendar-wins sync. Set by `reloadCalendar`.
    @Published var driftPrompt: DriftPrompt?
    /// The ONE-SHOT bulk TZ-shift re-anchor prompt (roadmap 3.3 slice 2). Set by the
    /// FIRST `reloadCalendar` after a live timezone-change rebuild when the per-block
    /// partition (`CalendarDrift.partitionForTZShift`) finds pairs that moved by exactly
    /// the zone-offset delta — re-anchoring artifacts, not genuine user drift. Offers the
    /// whole set one choice ("Times moved with you" vs "Keep appointment times") instead
    /// of a per-task drift storm; the non-matching pairs fall through to `driftPrompt`.
    /// A normal (non-rebuild) reload clears it — those pairs re-detect as ordinary drift.
    @Published var reanchorPrompt: ReanchorPrompt?
    /// Linked tasks whose calendar event was deleted in Calendar.app (detected at open time,
    /// CR-02). Surfaced — not silently dropped — so the user is offered a calendar-wins
    /// cleanup: clearing the now-dead `cal_event:` link degrades the task to an unlinked
    /// time-blocked task instead of leaving it pointing at a dead (and recyclable, WR-05) id
    /// forever. Set by `reloadCalendar`; cleared on confirm/dismiss and reset each reload.
    @Published var missingLinkPrompt: MissingLinkPrompt?
    /// Transient, dismissible notice surfaced when a task-wins "Update event" push
    /// (roadmap 2.3) could not update one or more linked events — deleted in Calendar,
    /// or a foreign/recycled event the WR-05 marker guard refused to touch. Every OTHER
    /// pair in the same resolve is unaffected (each pair's push is independent). Reset
    /// to nil at the start of each `confirmDriftUpdateEvent` so a stale notice from a
    /// prior resolve never bleeds into a clean one. nil = nothing to show.
    @Published var driftUpdateSkipNotice: String?
    /// Pending drop conflict (Phase 8 SC1 / T-8-10): set when a drop's
    /// `overlappingEvents` gate finds an overlap, mirroring the capture flow's
    /// SC5 semantics — the canvas UI (plan 05) resolves it via
    /// `resolveDropConflict(commitAnyway:)`. Cancel skips the create (the
    /// time: block is already on disk, disk wins); commit creates the event.
    @Published var pendingDropConflict: CalendarConflict?

    /// Convenience count for the one-line affordance copy.
    var missingLinkCount: Int { missingLinkPrompt?.tasks.count ?? 0 }

    /// Carries the linked tasks whose calendar event was deleted, awaiting a clear decision.
    struct MissingLinkPrompt: Identifiable {
        let id = UUID()
        let tasks: [Todo]
    }

    /// Carries the task awaiting a delete-event decision.
    struct DeletePrompt: Identifiable {
        let id = UUID()
        let task: Todo
    }

    /// Carries the drifted (task, event) pairs awaiting a calendar-wins sync decision.
    struct DriftPrompt: Identifiable {
        let id = UUID()
        let drifted: [(task: Todo, event: CalendarEvent)]
    }

    /// Carries the TZ-shifted (task, event) pairs awaiting the one-shot bulk re-anchor
    /// decision after a live timezone change (roadmap 3.3 slice 2).
    struct ReanchorPrompt: Identifiable {
        let id = UUID()
        let tzShift: [(task: Todo, event: CalendarEvent)]
    }

    /// WR-09: `var` (not `let`) — the storage folder can change in Settings → Storage
    /// while the app runs, and `Store.folder` is immutable, so AppDelegate swaps in a
    /// freshly built Store via `replaceStore(_:)`. A launch-time capture would leave the
    /// menubar list, rollover reload, toggle/delete/rename, and the drift pass operating
    /// on the OLD folder for the rest of the session while capture writes to the new one.
    private(set) var store: Store
    /// The zone the render stack is PINNED to (day partitioning, collapse keys, the
    /// HH:mm formatter). `private(set) var` (roadmap 3.3 slice 2): a live system-
    /// timezone change re-pins it through `replace(store:timezone:)`, rebuilding the
    /// cached formatter — otherwise the menubar would keep partitioning and rendering
    /// in the launch zone after the user (or a laptop crossing regions) moved.
    private(set) var timezone: TimeZone
    /// Armed by `replace(...)` on any zone-IDENTIFIER change (roadmap 3.3 slice 2): the
    /// FROM zone the NEXT `reloadCalendar` hands to `CalendarDrift.partitionForTZShift`
    /// (paired with the now-current `timezone`) so it can split re-anchor artifacts from
    /// genuine drift per-block. Consumed (cleared) by that reload. nil = no pending rebuild
    /// (a folder-only change keeps the same identifier, so it never arms). The arm is the
    /// identifier change, NOT a single-instant offset compare — Brisbane→Sydney is
    /// offset-identical in July yet shifts every post-Oct block, so the per-block partition
    /// (not an offset gate) is the sole decider of WHICH pairs are prompted.
    private var pendingReanchorFromZone: TimeZone?
    /// SHARED timezone-pinned HH:mm formatter for event/block times, built ONCE per
    /// pinned zone (the menubar section and canvas previously rebuilt a DateFormatter
    /// per render — formatter construction is one of the more expensive Foundation
    /// inits, and the calendar section renders one per visible event row). Main-actor
    /// confined like the rest of the model, so the non-thread-safe DateFormatter is
    /// safe to share; `replace(store:timezone:)` rebuilds it on a zone change.
    private(set) var timeFormatter: DateFormatter
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Optional calendar orchestration seam; nil = pure task tool (no calendar
    /// section). Wraps the injected `CalendarService` (plan 08 injects the real
    /// EventKit-backed one from AppDelegate) — the coordinator owns the service-side
    /// logic (access gate, fetches, update-or-recreate, conflict queries) and this
    /// model keeps the published state, prompts, and disk writes.
    private let calendarCoordinator: CalendarCoordinator?
    /// Optional config store for the remembered delete-event preference (SC3).
    /// nil-defaulted so existing tests/callers construct the model without it; when
    /// nil, a linked delete falls back to NOT touching the calendar (safe default).
    private let configStore: ConfigStore?
    /// Optional Send-to-Claude seam (SC1). nil-defaulted like calendar/configStore so
    /// existing tests/callers construct the model without it; when nil, the "Send to
    /// Claude" menu item is a no-op (AppDelegate injects the real SystemClaudeHandoff).
    private let claudeHandoff: (any ClaudeHandoff)?
    /// Optional unified-inbox coordinator (Phase 7). nil-defaulted like calendar so
    /// existing tests/callers construct the model without it; when nil there is no
    /// Suggested section and `refreshInbox()` is a no-op. AppDelegate injects the real
    /// `InboxService([GitHubInboxSource], …)`. Exposed (not private) so the view can
    /// `@ObservedObject` it directly for `suggestions` updates. `private(set) var`
    /// (roadmap 3.3 slice 2): the live timezone-change rebuild swaps in a freshly
    /// zone-pinned InboxService (its `CalendarInboxSource` pins the today-window
    /// timezone at construction), so the Suggested section's window follows a zone
    /// change on the next popover open. Folder-only changes keep the current instance.
    private(set) var inboxService: InboxService?
    /// Optional SHARED user keybindings store (UX-07). nil-defaulted like the other
    /// seams so existing tests/callers construct the model without it; when nil the
    /// Send-to-Claude item simply shows no key equivalent. AppDelegate injects the
    /// SAME store the Keybindings tab mutates, so the displayed equivalent always
    /// matches the live binding (the popover view is rebuilt on every open).
    private let keybindings: KeybindingsStore?

    /// The LIVE Send-to-Claude combo for the visible key equivalent (UX-07);
    /// nil when unbound or no store is injected.
    var sendToClaudeCombo: KeyCombo? { keybindings?.combo(for: .sendToClaude) }

    /// The LIVE ⌘K command-bar combo for the discoverable "Search…" footer (#2);
    /// nil when unbound or no store is injected (footer degrades to no key hint).
    var commandBarCombo: KeyCombo? { keybindings?.combo(for: .globalCommandBar) }

    /// Reference "now" for metadata-badge derivations (overdue / relative-due),
    /// and a timezone-pinned calendar matching the day partitioning (#3), so the
    /// menubar pills agree with the leftover/today split.
    var badgeAsOf: Date { now() }
    var badgeCalendar: Calendar { DailyFile.calendar(timezone: timezone) }

    /// One-line, transient notice shown when Code-mode Send-to-Claude finds no `claude`
    /// binary (D-SC1 graceful degrade): points the user to Web mode. Cleared by the view
    /// after a brief display. nil = nothing to show.
    @Published var claudeNotice: String?

    /// Transient, dismissible menubar notice shown when a day file was found
    /// unparseable and quarantined to a `.corrupt-*` sidecar before a write (#7 —
    /// the menubar wire-up for Cluster A's `Store.onCorruptQuarantine`). A FIXED
    /// string only — never interpolate the path or bytes (T-07.1-16). nil = nothing.
    @Published var corruptQuarantineNotice: String?
    /// In-flight calendar refresh spawned by `reload()`, so tests (and reload callers) can
    /// await it deterministically. Kept distinct from `editTask` (WR-03) so an edit and a
    /// concurrent refresh never overwrite each other's handle and drop in-flight work.
    private var refreshTask: Task<Void, Never>?
    /// In-flight edit-time update/recreate work spawned by `editTime()`. Distinct from
    /// `refreshTask`: `editTime` ends by triggering a `reload()` (which sets `refreshTask`),
    /// so sharing one handle would let the reload clobber the edit handle before a test
    /// could observe it (WR-03).
    private var editTask: Task<Void, Never>?
    /// In-flight delete-event best-effort work, awaited by tests.
    private var deleteTask: Task<Void, Never>?
    /// In-flight drop-to-time-block calendar work spawned by `dropTask()` (Phase 8 SC1).
    /// A DEDICATED handle (WR-03): `dropTask` ends by triggering a reload (which sets
    /// `refreshTask`) and a drop on an already-scheduled task delegates to `editTime`
    /// (which sets `editTask`) — sharing any of those handles would let one overwrite
    /// the other before a test could await it.
    private var dropHandle: Task<Void, Never>?
    /// Suspends the drop's calendar pass while a conflict decision is pending
    /// (mirrors `CaptureViewModel.conflictContinuation`).
    private var dropConflictContinuation: CheckedContinuation<Bool, Never>?

    init(store: Store,
         timezone: TimeZone = .current,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         calendar: (any CalendarService)? = nil,
         configStore: ConfigStore? = nil,
         claudeHandoff: (any ClaudeHandoff)? = nil,
         inboxService: InboxService? = nil,
         keybindings: KeybindingsStore? = nil) {
        self.store = store
        self.timezone = timezone
        self.timeFormatter = Self.makeTimeFormatter(timezone: timezone)
        self.defaults = defaults
        self.now = now
        self.calendarCoordinator = calendar.map { CalendarCoordinator(calendar: $0) }
        self.configStore = configStore
        self.claudeHandoff = claudeHandoff
        self.inboxService = inboxService
        self.keybindings = keybindings
        hookCorruptQuarantine()
        // Launch-time load must NOT prompt (WR-06 class): the model is built inside
        // applicationDidFinishLaunching, so a default reload() fired the one-time TCC
        // calendar dialog at app launch with zero user action. The prompt stays
        // reserved for explicit calendar paths — the first popover open re-reloads
        // with the default promptIfUndetermined: true.
        reload(promptIfUndetermined: false)
    }

    // MARK: - Corrupt-file quarantine notice (#7, wire-up)

    /// Publishes the transient corrupt-quarantine recovery notice. Shared entry
    /// point for the store callback and tests.
    func showCorruptQuarantineNotice() {
        corruptQuarantineNotice = "Recovered a damaged day file — a backup was saved."
    }

    /// Dismisses the corrupt-quarantine notice (non-blocking, user-dismissible).
    func dismissCorruptQuarantineNotice() {
        corruptQuarantineNotice = nil
    }

    /// Routes the store's `onCorruptQuarantine` (fired when a day file was
    /// quarantined before a clobbering write) to the transient menubar notice.
    /// Every Store write path in the app runs on the main actor, so the callback
    /// assumes main isolation and publishes synchronously. Re-installed by
    /// `replaceStore` so a Settings folder change keeps surfacing recoveries.
    private func hookCorruptQuarantine() {
        store.onCorruptQuarantine = { [weak self] _ in
            MainActor.assumeIsolated { self?.showCorruptQuarantineNotice() }
        }
    }

    // NOTE (CR-03/IN-03): every visible row is loaded from TODAY's doc —
    // `reload()` reads only today's file, and rollover lands leftovers there
    // as copies that keep their origin `createdAt`. "The file the task lives
    // in" is therefore ALWAYS today's file for anything the menubar can show;
    // a createdAt-derived day would point at the hidden, rolled_to:-marked
    // origin line instead. All row ops anchor on `now()`.

    /// `clearMissingLinks` is forwarded to the spawned calendar refresh: it is true on a
    /// genuine open-time reload (popover open, foreground, midnight) so a deleted event's
    /// dead link self-heals (CR-02), but false when reload runs as the tail of an edit-time
    /// create/update, so the self-heal never races the just-written id (see `reloadCalendar`).
    ///
    /// `promptIfUndetermined` is likewise forwarded (WR-02): the popover-open path keeps the
    /// default `true` (an explicit user action may drive the one-time TCC prompt), but the
    /// foreground-activation catch-up and the midnight timer pass `false` — a background
    /// reload must NEVER re-issue the system calendar prompt while access is notDetermined.
    func reload(clearMissingLinks: Bool = true, promptIfUndetermined: Bool = true) {
        // A highlight never sticks across reloads/opens (Phase 9 SC3): the
        // controller re-applies it AFTER reload when the command bar asked for one.
        highlightedTaskID = nil
        // Single snapshot: grouping, collapse key, and dateLabel must all
        // derive from the same instant (midnight Timer reloads an open popover).
        let snapshot = now()
        let cal = DailyFile.calendar(timezone: timezone)
        let todayStart = cal.startOfDay(for: snapshot)

        do {
            let doc = try store.readDoc(on: snapshot)
            tasks = doc.tasks
        } catch {
            tasks = []
        }
        // Phase 8 SC3 (CALX-03): a task snoozed to a FUTURE date is hidden from
        // BOTH partitions until that date. The @Published `tasks` array stays the
        // FULL list (doneCount + the calendar drift linkage read it); only the
        // partitions filter. Reappearance is automatic: on/after the snooze day
        // the predicate is false — the token stays on disk, merely ignored
        // (T-8-07: a snoozed task is never permanently hidden).
        let visible = tasks.filter { task in
            guard let snooze = task.snooze else { return true }
            return cal.startOfDay(for: snooze) <= todayStart
        }
        leftovers = visible.filter { cal.startOfDay(for: $0.createdAt) < todayStart && !$0.done }
        todayTasks = visible.filter { !(cal.startOfDay(for: $0.createdAt) < todayStart && !$0.done) }

        let todayKey = collapseKey(for: snapshot)
        leftoversCollapsed = defaults.bool(forKey: todayKey)
        let todayDoneKey = doneCollapseKey(for: snapshot)
        doneCollapsed = defaults.bool(forKey: todayDoneKey)
        // Housekeeping: drop every stale collapse key from earlier days
        // (the app may not run every day, so "yesterday only" leaks keys).
        for key in defaults.dictionaryRepresentation().keys
            where (key.hasPrefix("leftoversCollapsed-") && key != todayKey)
               || (key.hasPrefix("doneCollapsed-") && key != todayDoneKey) {
            defaults.removeObject(forKey: key)
        }

        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = timezone
        dateLabel = f.string(from: snapshot)

        // Calendar refresh rides on every reload trigger (popover open, window
        // close, midnight Timer) so the read section + future drift hooks stay
        // fresh. The task path above stays synchronous; calendar is async/best-effort.
        // The PRIOR refresh is cancelled first: two concurrent refreshes can finish
        // out of order (the fetch awaits), letting an older result overwrite a newer
        // one — `reloadCalendar` checks `Task.isCancelled` before publishing.
        if calendarCoordinator != nil {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.reloadCalendar(promptIfUndetermined: promptIfUndetermined,
                                           clearMissingLinks: clearMissingLinks)
            }
        }
    }

    /// The timezone-pinned HH:mm formatter builder (POSIX/Gregorian discipline),
    /// shared by `init` and the rebuild so the two can never drift.
    private static func makeTimeFormatter(timezone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        f.timeZone = timezone
        return f
    }

    /// WR-09 folder-change convenience: swaps the backing Store after a Settings →
    /// Storage folder change and reloads so the visible list reflects the NEW folder
    /// immediately, adopting the new Store's timezone (the AppDelegate builds that
    /// Store with a fresh `.current`, so the model's zone stays in lock-step with the
    /// store's — the invariant MenubarController relies on). Safe to call with an
    /// unchanged folder/zone — it then behaves like a plain `reload()`.
    func replaceStore(_ newStore: Store) {
        replace(store: newStore, timezone: newStore.timezone)
    }

    /// Re-pins the render stack onto a NEW Store + timezone, KEEPING the current
    /// inbox service — the folder-change path and the tests' rebuild entry point.
    /// Delegates to the inbox-swapping overload the live timezone-change rebuild uses.
    func replace(store newStore: Store, timezone newTimezone: TimeZone) {
        replace(store: newStore, timezone: newTimezone, inboxService: inboxService)
    }

    /// The live timezone-change rebuild (roadmap 3.3 slice 2): re-pins the backing
    /// Store, the model timezone, and the cached HH:mm formatter onto `newTimezone`,
    /// swaps in the freshly zone-pinned `inboxService` (its `CalendarInboxSource`
    /// fixes the today-window zone at construction), re-hooks corrupt-quarantine, and
    /// reloads so the list + calendar section re-render in the new zone.
    ///
    /// RENDER-ONLY: no Store WRITE is reachable from here — `reload()` only READS
    /// today's doc and fetches calendar events; the wall-clock tokens on disk are
    /// TZ-agnostic and stay byte-identical (the rollover over-correction taught us
    /// that acting automatically on re-anchored data destroys it, so a rebuild never
    /// rewrites a file). Enforced by construction AND the byte-identical-folder test.
    ///
    /// The reload passes `promptIfUndetermined: false` (WR-06 class): a rebuild is
    /// never an explicit calendar action, so it must NEVER re-issue the one-time TCC
    /// calendar prompt while access is notDetermined. Main-actor sequenced (@MainActor)
    /// so it cannot interleave with an in-flight capture commit or rollover (WR-09).
    func replace(store newStore: Store, timezone newTimezone: TimeZone,
                 inboxService newInbox: InboxService?) {
        // Arm the one-shot bulk re-anchor partition for the NEXT reload iff the zone
        // IDENTIFIER changed (roadmap 3.3 slice 2). A folder-only change keeps the same
        // identifier → no arm → plain reload. The zone PAIR (old, new) must reach the
        // partition so it computes each block's re-anchor delta at the block's own date.
        let oldTimezone = timezone
        pendingReanchorFromZone = oldTimezone.identifier == newTimezone.identifier ? nil : oldTimezone
        store = newStore
        timezone = newTimezone
        timeFormatter = Self.makeTimeFormatter(timezone: newTimezone)
        inboxService = newInbox
        hookCorruptQuarantine()   // #7: re-hook so the new store's quarantines surface.
        reload(promptIfUndetermined: false)
    }

    // MARK: - Unified inbox (Phase 7, SC2/SC3)

    /// Lazy refresh hook (SC3): fan out over configured sources. `InboxService.refresh()`
    /// self-guards — it makes NO network call when zero sources are configured — so calling
    /// this on every menubar open is safe on the default config. A nil service is a no-op.
    func refreshInbox() async {
        await inboxService?.refresh()
    }

    /// Accept a suggestion (SC2): record the id (so it is never re-suggested and is dropped
    /// from the Suggested list), then write it as a real task carrying `source:`/`source_url:`
    /// provenance into today's `## Tasks`. The id is recorded FIRST (WR-01): if the task
    /// write fails, a leaked dedupe entry (no task) is harmless, whereas the reverse order
    /// could write a duplicate task on re-accept. Best-effort — any error degrades
    /// gracefully (logged), never crashes the popover.
    ///
    /// A CALENDAR item (Phase 11) additionally carries `item.timeBlock` and `item.calEventID`,
    /// so the written task gains `time:` + `cal_event:<existing id>` tokens — a LINK to the
    /// already-existing event. Accept NEVER calls `createEvent`/`updateEvent` (contrast
    /// `dropTask`): the event exists, we only reference it. For every other source both fields
    /// are nil, so the token pair is omitted and that branch is byte-identical to before.
    func acceptSuggestion(_ item: InboxItem) {
        guard let inboxService else { return }
        let when = now()
        let todo = Todo(
            id: UUID().uuidString,
            text: item.title,
            createdAt: when,
            timeBlock: item.timeBlock,   // calendar only → time: token; nil elsewhere
            calEventID: item.calEventID, // calendar only → cal_event: LINK; nil elsewhere
            source: item.id,             // composite "<sourceID>:<itemID>" → source: token
            sourceURL: item.url.isEmpty ? nil : item.url)  // P5: empty local url → omit source_url:
        do {
            // WR-01: record acceptance (dedupe id) BEFORE the visible task write. If the
            // task write then throws, the worst case is a leaked dedupe entry (the item
            // won't re-suggest) — strictly safer than the reverse order, where a write
            // success followed by an accept failure leaves the item suggested and invites
            // the user to re-accept, writing a SECOND duplicate task. A dedupe entry with
            // no task is harmless; a duplicate task is not.
            try inboxService.accept(item)
            try store.appendCapture(noteText: "", noteId: nil, tasks: [todo], at: when)
            reload()                // surface the new task in the list
        } catch {
            NSLog("[Jotty] accept suggestion failed: \(error.localizedDescription)")
        }
    }

    /// Dismiss a suggestion (SC2): record the id (persisted) and drop it from the Suggested
    /// list — never written to a task, never re-suggested. Best-effort; a persist failure
    /// logs and leaves the item visible rather than crashing.
    func dismissSuggestion(_ item: InboxItem) {
        guard let inboxService else { return }
        do {
            try inboxService.dismiss(item)
        } catch {
            NSLog("[Jotty] dismiss suggestion failed: \(error.localizedDescription)")
        }
    }

    /// Lazy access gate + today's-events fetch for the read-only Calendar section (SC2).
    /// Authorized -> fetch today's [startOfDay, endOfDay) events; denied -> empty + flag;
    /// notDetermined -> prompt once (only when `promptIfUndetermined` is true), then branch.
    /// Any thrown error degrades to empty + logs (never crashes). No-op when no service is
    /// injected.
    ///
    /// `promptIfUndetermined` defaults to true so explicit user actions (popover open, edit)
    /// can drive the one-time access prompt. `applicationDidBecomeActive` passes `false`
    /// (WR-06): foreground activation must NOT re-issue the TCC prompt on every activation
    /// while the grant is still `notDetermined` — a denied result is already terminal
    /// (`access()` maps `.denied`/`.restricted` to `.denied`, so the `notDetermined` branch is
    /// never re-entered once the user has answered).
    func reloadCalendar(promptIfUndetermined: Bool = true,
                        clearMissingLinks: Bool = true) async {
        // Consume the pending re-anchor arm (roadmap 3.3 slice 2): THIS invocation owns it,
        // so the FIRST reload after a rebuild partitions drift while every later reload uses
        // the normal path. On an early return below (no coordinator / denied / superseded /
        // fetch failure) there is no drift to classify anyway, and the design re-detects the
        // shift on the next open (idempotent — nothing is persisted about the prompt).
        let reanchorFrom = pendingReanchorFromZone
        pendingReanchorFromZone = nil

        guard let calendarCoordinator else {
            calendarEvents = []
            allDayEvents = []
            calendarAccessDenied = false
            return
        }

        // The coordinator runs the lazy access gate (WR-06 no-prompt rule and the
        // post-prompt cancellation check); this model maps outcomes onto its
        // published state — immediately, so a fresh grant clears the denied
        // affordance before the (possibly slow) fetches run.
        switch await calendarCoordinator.resolveAccess(promptIfUndetermined: promptIfUndetermined) {
        case .superseded:
            // A newer reload owns the published state — touch nothing.
            return
        case .denied:
            calendarEvents = []
            allDayEvents = []
            calendarAccessDenied = true
            return
        case .unavailable:
            calendarEvents = []
            allDayEvents = []
            calendarAccessDenied = false
            return
        case .granted:
            calendarAccessDenied = false
        }

        // Today's range in the model's timezone (matches task partitioning) —
        // computed AFTER the gate: the TCC prompt can suspend across midnight, and
        // the window must be the day the fetch actually runs, not the day it asked.
        let snapshot = now()
        let cal = DailyFile.calendar(timezone: timezone)
        let todayStart = cal.startOfDay(for: snapshot)
        guard let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) else {
            calendarEvents = []
            allDayEvents = []
            return
        }

        switch await calendarCoordinator.fetchTimedEvents(from: todayStart, to: todayEnd) {
        case .superseded:
            return
        case .failed:
            // Best-effort: a read failure degrades to no rows, skips the drift pass.
            calendarEvents = []
            allDayEvents = []
            return
        case .fetched(let events):
            // Published BEFORE the all-day fetch: a supersede between the two must
            // not discard the already-fetched timed result.
            calendarEvents = events
        }

        switch await calendarCoordinator.fetchAllDayEvents(from: todayStart, to: todayEnd) {
        case .superseded:
            return
        case .failed:
            allDayEvents = []
        case .fetched(let allDay):
            allDayEvents = allDay
        }

        // SC4: open-time drift awareness. Compare today's linked tasks against the fetched
        // events. Drifted (title/time changed externally) -> a one-time calendar-wins sync
        // prompt. Missing (event deleted in Calendar) -> the dead `cal_event:` link is
        // cleared so the task degrades cleanly to an unlinked time-blocked task, and the
        // count is surfaced (CR-02 — calendar wins; a deleted event must not leave a task
        // pointing at a dead/recyclable id forever).
        //
        // `linked` is scoped to the SAME window the read fetched (`[todayStart, todayEnd)`),
        // not "today+future": storage is one file per day and `reload()` only loads today's
        // file, so a future-day task could never appear in `calendarEvents` and would be
        // mis-classified as missing (WR-02).
        let linked = todayLinkedTasks(from: todayStart, to: todayEnd)
        let result = CalendarDrift.driftedTasks(linked, against: calendarEvents)
        // Surface (do NOT silently drop, CR-02) both the drifted and the missing-link sets.
        // Both are RESET to nil when their condition clears (sweep WR: driftPrompt lacked the
        // `else = nil` its sibling missingLinkPrompt had, so a stale "Sync from Calendar?"
        // could linger with outdated event data once the drift was resolved). Both resets are
        // gated on the SAME `clearMissingLinks` guard: on a genuine open-time refresh they
        // set-or-clear, but an edit-time trailing reload passes `clearMissingLinks: false` so
        // the just-written id is never raced against a not-yet-refreshed fetch and the
        // in-progress edit is not fought (CR-02 must not fight the SC3 edit flow).
        if clearMissingLinks {
            // On the FIRST reload after a rebuild (`reanchorFrom` set), intercept BEFORE
            // the normal drift prompt: split the drifted pairs into TZ-shift artifacts (the
            // one-shot bulk re-anchor prompt) and genuine drift (the normal per-set prompt).
            // The zone PAIR is (reanchorFrom → the now-current `timezone`), so the partition
            // computes each block's re-anchor delta at that block's own date (DST-safe). A
            // non-rebuild reload clears any stale bulk prompt — those pairs re-detect as
            // ordinary drift, so nothing is ever silently stranded.
            let driftedForPrompt: [(task: Todo, event: CalendarEvent)]
            if let reanchorFrom {
                let partition = CalendarDrift.partitionForTZShift(
                    result.drifted, from: reanchorFrom, to: timezone)
                reanchorPrompt = partition.tzShift.isEmpty
                    ? nil
                    : ReanchorPrompt(tzShift: partition.tzShift)
                driftedForPrompt = partition.other
            } else {
                reanchorPrompt = nil
                driftedForPrompt = result.drifted
            }
            driftPrompt = driftedForPrompt.isEmpty
                ? nil
                : DriftPrompt(drifted: driftedForPrompt)
            missingLinkPrompt = result.missing.isEmpty
                ? nil
                : MissingLinkPrompt(tasks: result.missing)
        }
    }

    /// Linked tasks (calEventID + timeBlock) whose block falls inside the fetched window
    /// `[start, end)`. Scope matches the today-only read + one-file-per-day storage (WR-02);
    /// historical and future-day tasks are structurally out of scope.
    private func todayLinkedTasks(from start: Date, to end: Date) -> [Todo] {
        tasks.filter { task in
            guard task.calEventID != nil, let tb = task.timeBlock else { return false }
            return tb.start >= start && tb.start < end
        }
    }

    /// Confirms the missing-link prompt (CR-02): clears the now-dead `cal_event:` link from
    /// each surfaced task. Calendar wins — the task keeps its time block but is unlinked, so a
    /// later edit re-creates a fresh event rather than risking an update against a recycled
    /// EventKit identifier (WR-05). Best-effort + idempotent: a disk failure logs, never crashes.
    func confirmClearMissingLinks() {
        guard let prompt = missingLinkPrompt else { return }
        missingLinkPrompt = nil
        let snapshot = now()
        do {
            let missingIDs = Set(prompt.tasks.map(\.id))
            try store.mutateDay(on: snapshot) { doc in
                var cleared = false
                for idx in doc.tasks.indices where missingIDs.contains(doc.tasks[idx].id)
                    && doc.tasks[idx].calEventID != nil {
                    doc.tasks[idx].calEventID = nil
                    cleared = true
                }
                return cleared
            }
        } catch {
            NSLog("[Jotty] clearing dead calendar links failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Dismisses the missing-link prompt, leaving the (dead) links in place ("Keep").
    func dismissMissingLinkPrompt() {
        missingLinkPrompt = nil
    }

    /// Awaits all in-flight calendar work (edit-time update/recreate, then the refresh it
    /// triggers) spawned by the most recent `editTime()`/`reload()`. Test hook (mirrors
    /// `CaptureViewModel.awaitCalendarWork`); production fires-and-forgets. Awaiting the edit
    /// task FIRST then the refresh task it spawns makes test sequencing deterministic (WR-03).
    func awaitCalendarRefresh() async {
        if let t = editTask { _ = await t.value }
        if let t = refreshTask { _ = await t.value }
    }

    func setCollapsed(_ collapsed: Bool, at date: Date? = nil) {
        leftoversCollapsed = collapsed
        defaults.set(collapsed, forKey: collapseKey(for: date ?? now()))
    }

    /// Persists + applies the "Done · N" collapse choice for a day (#4), mirroring
    /// `setCollapsed`.
    func setDoneCollapsed(_ collapsed: Bool, at date: Date? = nil) {
        doneCollapsed = collapsed
        defaults.set(collapsed, forKey: doneCollapseKey(for: date ?? now()))
    }

    // MARK: - Command bar highlight (Phase 9, SC3)

    /// Spotlights the row with `taskID` (command-bar Enter-on-today-task seam).
    /// If the task sits in a COLLAPSED leftovers section, auto-expand first so the
    /// highlight is actually visible. The expand is TRANSIENT (sweep INFO): it
    /// updates the in-memory `leftoversCollapsed` only and does NOT write the
    /// day-keyed collapse default — going through the persisting `setCollapsed`
    /// clobbered the user's collapsed=true for the whole day, so the section stayed
    /// expanded across the next fresh model load. A reload re-reads the persisted
    /// key, so the transient expand naturally lasts only until the next reload.
    /// Highlighting a today task (or an unknown id) never touches the collapse
    /// state. Call AFTER `reload()` — reload clears the id at entry.
    func highlight(taskID: String) {
        if leftoversCollapsed, leftovers.contains(where: { $0.id == taskID }) {
            leftoversCollapsed = false
        }
        // Same transient expand for the "Done · N" group: a ⌘K Enter on a completed
        // task otherwise scrolls to nothing and the highlight silently no-ops behind
        // the collapsed section. In-memory only (not setDoneCollapsed) — the user's
        // persisted collapse choice survives the next reload, like leftovers above.
        if doneCollapsed, todayDone.contains(where: { $0.id == taskID }) {
            doneCollapsed = false
        }
        highlightGeneration += 1
        highlightedTaskID = taskID
    }

    /// Monotonic token minted per `highlight(taskID:)` trigger (review WR-04).
    /// The view captures the value at trigger time and passes it back through
    /// `clearHighlight(ifGeneration:)` from its 1.5 s fade timer, so an OLDER
    /// trigger's timer can never wipe a NEWER highlight mid-fade. Lives on the
    /// shared model (not view @State) so a stale timer from a torn-down view
    /// instance is also superseded by the next trigger.
    private(set) var highlightGeneration = 0

    /// Removes the spotlight; the view calls this once its fade completes.
    func clearHighlight() {
        highlightedTaskID = nil
    }

    /// Trigger-scoped clear for the fade timer (WR-04): a no-op when a newer
    /// `highlight(taskID:)` superseded `generation` — THAT trigger's timer owns
    /// the clear. The unconditional `clearHighlight()` stays for explicit paths.
    func clearHighlight(ifGeneration generation: Int) {
        guard generation == highlightGeneration else { return }
        highlightedTaskID = nil
    }

    func toggle(_ task: Todo) {
        // Membership must be captured BEFORE the store write and reload():
        // reload repartitions the arrays and a just-completed leftover vanishes.
        let wasLeftover = leftovers.contains { $0.id == task.id }
        // Single snapshot: the store write and the collapse key must agree
        // on the day even if the wall clock crosses midnight mid-call.
        let snapshot = now()
        do {
            try store.toggleTodo(id: task.id, on: snapshot)
            // Auto-collapse only on the day's FIRST interaction; a manual
            // expand/collapse (key present) is the user's choice and wins.
            // Gated on write success: a failed toggle is not an interaction.
            if wasLeftover, defaults.object(forKey: collapseKey(for: snapshot)) == nil {
                // Same animation as the manual header toggle — and, like it, honours
                // Reduce Motion (#11): the model reads the AppKit signal at call time
                // (it has no @Environment) so the auto-collapse snaps when reduced.
                let anim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? nil : .easeInOut(duration: 0.15)
                withAnimation(anim) {
                    setCollapsed(true, at: snapshot)
                }
            }
        } catch {
            NSLog("[Jotty] toggle failed: \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - Delete (SC3)

    /// Deletes a task. The markdown line is removed immediately (disk is the source
    /// of truth, T-5-09 — a calendar failure never blocks the local delete). If the
    /// task had a linked calendar event, the remembered `deleteCalendarEventWithTask`
    /// preference decides: nil -> surface a one-time prompt; true -> delete the event
    /// best-effort; false -> leave the event. The remembered choice is acted on
    /// silently thereafter.
    func delete(_ task: Todo) {
        let snapshot = now()
        do {
            try store.deleteTodo(id: task.id, on: snapshot)
        } catch {
            NSLog("[Jotty] delete failed: \(error.localizedDescription)")
        }

        if let eventID = task.calEventID {
            switch configStore?.config.deleteCalendarEventWithTask {
            case .some(true):
                bestEffortDeleteEvent(id: eventID)
            case .some(false):
                break // remembered: leave the event.
            case .none:
                // Unanswered (nil pref, or no config store) -> ask once.
                deletePrompt = DeletePrompt(task: task)
            }
        }
        reload()
    }

    /// Resolves the one-time delete-event prompt: persists the answer (so the next
    /// linked delete acts silently) and, on "yes", deletes the linked event
    /// best-effort. The task was already removed from markdown by `delete(_:)`.
    func resolveDeletePrompt(deleteEvent: Bool) {
        guard let prompt = deletePrompt else { return }
        deletePrompt = nil
        try? configStore?.update { $0.deleteCalendarEventWithTask = deleteEvent }
        if deleteEvent, let eventID = prompt.task.calEventID {
            bestEffortDeleteEvent(id: eventID)
        }
    }

    /// Awaits the in-flight best-effort delete-event work (test hook).
    func awaitDeleteWork() async {
        if let t = deleteTask { _ = await t.value }
    }

    /// Fires the calendar delete on a detached task; a failure logs but never
    /// rolls back the already-completed markdown delete (best-effort, T-5-09).
    private func bestEffortDeleteEvent(id eventID: String) {
        guard let calendarCoordinator else { return }
        deleteTask = Task {
            await calendarCoordinator.deleteEventBestEffort(id: eventID)
        }
    }

    // MARK: - Edit time (SC3)

    /// Changes a task's time block, conflict-gated like every other calendar write.
    ///
    /// With a calendar wired, the move runs the SAME overlap gate capture and first-drop
    /// run (SC5 parity — previously "Move +30 min" and a canvas drop-move slid into a busy
    /// slot silently): overlapping events are fetched for the TARGET slot, the task's OWN
    /// linked event is excluded (a small nudge overlaps the event being moved — not a
    /// conflict), and an overlap surfaces the shared `pendingDropConflict` prompt. The gate
    /// runs BEFORE the disk write so a cancel leaves the task AND event untouched — writing
    /// first would leave a task/event disagreement that drift-prompts on the next open.
    ///
    /// Confirmed (or clear): the markdown `time:` token is written (disk first, T-5-09; a
    /// FAILED write stops the calendar pass — same orphan guard as `dropTask`), then a
    /// linked event is updated in place by id. When the event is gone (.eventNotFound), it
    /// is recreated and the new id rewritten onto the task line (recreate-and-relink per
    /// CONTEXT/RESEARCH). Other calendar errors are logged, never blocking.
    func editTime(_ task: Todo, to newBlock: TimeBlock) {
        let snapshot = now()
        guard let calendarCoordinator else {
            // Pure task tool: nothing to conflict with, no event to move.
            do {
                try store.updateTodoTime(id: task.id, timeBlock: newBlock, on: snapshot)
            } catch {
                NSLog("[Jotty] editTime failed: \(error.localizedDescription)")
            }
            reload()
            return
        }

        let title = CalendarDrift.sanitize(title: task.text)
        editTask = Task { [weak self] in
            guard let self else { return }
            // Conflict gate (SC5), excluding the task's OWN event: a read failure is
            // non-fatal — fall through to the move, exactly like the capture pass.
            var proceed = true
            if let conflictTitle = await calendarCoordinator.firstConflictTitle(
                overlapping: newBlock, excludingEventID: task.calEventID) {
                proceed = await self.awaitDropConflictDecision(title: conflictTitle, kind: .move)
            }
            guard proceed else {
                await self.reloadOnMain(clearMissingLinks: false)
                return
            }
            // The decision can arrive arbitrarily late: the popover can close with
            // the prompt pending (the inert isPresented setter keeps the
            // continuation suspended) and re-present it on a later open. A confirm
            // that crossed midnight must not replay the stale snapshot — that wrote
            // the time: token into YESTERDAY's file and moved the live event onto a
            // past slot. The task has rolled; abort and let the user re-issue.
            guard DailyFile.calendar(timezone: self.timezone)
                .isDate(self.now(), inSameDayAs: snapshot) else {
                await self.reloadOnMain(clearMissingLinks: false)
                return
            }

            do {
                try self.store.updateTodoTime(id: task.id, timeBlock: newBlock, on: snapshot)
            } catch {
                // The time: write failed — updating the event anyway would desync the
                // task from its event (and drift-prompt forever). Stop here.
                NSLog("[Jotty] editTime failed: \(error.localizedDescription)")
                await self.reloadOnMain(clearMissingLinks: false)
                return
            }

            if let eventID = task.calEventID {
                let outcome = await calendarCoordinator.updateOrRecreate(
                    eventID: eventID, title: title, block: newBlock, context: "editTime")
                if case .recreated(let newID) = outcome {
                    // Event deleted in Calendar: rewrite the fresh id onto the task (SC3).
                    self.relink(taskID: task.id, block: newBlock, newEventID: newID, on: snapshot)
                }
            }
            // Skip the dead-link self-heal on the edit's trailing reload: the id was just
            // (re)written and a stale/empty fetch must not clear it (CR-02 vs SC3).
            await self.reloadOnMain(clearMissingLinks: false)
        }
    }

    /// Rewrites a recreated event's fresh id (and the block it was created for) onto
    /// the task line — the disk half of recreate-and-relink; the event half lives in
    /// `CalendarCoordinator.updateOrRecreate`.
    private func relink(taskID: String, block: TimeBlock, newEventID: String, on date: Date) {
        do {
            try store.mutateDay(on: date) { doc in
                guard let idx = doc.tasks.firstIndex(where: { $0.id == taskID }) else { return false }
                doc.tasks[idx].timeBlock = block
                doc.tasks[idx].calEventID = newEventID
                return true
            }
        } catch {
            NSLog("[Jotty] recreate-relink rewrite failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Drift sync (SC4)

    /// Confirms the open-time drift prompt: calendar wins. Each drifted task's text
    /// and time block are rewritten to match its calendar event, persisted per-id
    /// through the mutateDay funnel (T-5-10 — user-confirmed, scoped to the drifted
    /// linked tasks; conflict-safe against external writers, review finding 1).
    func confirmDriftSync() {
        guard let prompt = driftPrompt else { return }
        driftPrompt = nil
        applyCalendarWins(prompt.drifted)
    }

    /// The calendar-wins per-pair rewrite funnel (SC4), shared by `confirmDriftSync` and
    /// the bulk re-anchor "Keep appointment times" choice (roadmap 3.3 slice 2). Rewrites
    /// each pair's task text + time block from its event, persisted per-id through the
    /// mutateDay funnel (T-5-10 — conflict-safe against external writers). A cross-midnight
    /// event re-anchors to a rolled-end/day-qualified block automatically on serialization.
    /// Per-pair by construction: a task no longer on today's doc is skipped, never fatal.
    private func applyCalendarWins(_ pairs: [(task: Todo, event: CalendarEvent)]) {
        let snapshot = now()
        do {
            try store.mutateDay(on: snapshot) { doc in
                var changed = false
                for pair in pairs {
                    guard let idx = doc.tasks.firstIndex(where: { $0.id == pair.task.id }) else { continue }
                    // Store the SANITIZED title (WR-04): drift is detected via
                    // `sanitize(task.text) != event.title`, and create writes `sanitize(text)`
                    // as the event title. Writing the raw event title back into `task.text`
                    // would be asymmetric — the next open recomputes `sanitize(newText)`, which
                    // can differ from `event.title` and re-trigger drift on every open. It also
                    // keeps markdown-significant chars out of the parser-sensitive task line (IN-01).
                    doc.tasks[idx].text = CalendarDrift.sanitize(title: pair.event.title)
                    doc.tasks[idx].timeBlock = TimeBlock(start: pair.event.start, end: pair.event.end)
                    changed = true
                }
                return changed
            }
        } catch {
            NSLog("[Jotty] drift sync failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Dismisses the drift prompt, leaving the markdown unchanged ("Keep mine").
    func dismissDriftPrompt() {
        driftPrompt = nil
    }

    // MARK: - One-shot bulk TZ-shift re-anchor (roadmap 3.3 slice 2)

    /// "Times moved with you": push each TZ-shifted task's OWN (re-anchored) wall-clock
    /// instants onto its linked event, in bulk. Reuses the per-pair task-wins funnel — one
    /// pair's `.notFound`/`.failed` never stops its siblings (no all-or-nothing batch), with
    /// the Task-1 skip-notice semantics. Each block already carries the NEW zone's wall-clock
    /// after the rebuild's reparse, so pushing it moves the appointment to follow the user.
    func confirmReanchorMoveWithMe() {
        guard let prompt = reanchorPrompt else { return }
        reanchorPrompt = nil
        bulkPushMine(prompt.tzShift)
    }

    /// "Keep appointment times": calendar wins in bulk — pin each task back onto its event's
    /// absolute instants (the existing SC4 per-pair path). Day-qualified tokens fall out of
    /// serialization automatically where a re-anchor crossed midnight.
    func confirmReanchorKeepTimes() {
        guard let prompt = reanchorPrompt else { return }
        reanchorPrompt = nil
        applyCalendarWins(prompt.tzShift)
    }

    /// Dismisses the bulk re-anchor prompt without persisting anything ("decide later"):
    /// the next reload re-detects the still-present shift as ordinary drift (idempotent).
    func dismissReanchorPrompt() {
        reanchorPrompt = nil
    }

    /// Confirms the open-time drift prompt: TASK wins ("Update event", roadmap 2.3).
    /// For each drifted pair, pushes the TASK's own fields onto its linked calendar
    /// event via the per-pair `updateEventForDrift` — the SAME action a later
    /// roadmap-3.3 task reuses in bulk after a timezone change, so it stays callable
    /// independently of this prompt. Unlike `confirmDriftSync`, the markdown is
    /// untouched: the task was already correct, the calendar was stale.
    ///
    /// A pair whose event is gone (`.eventNotFound` — deleted in Calendar, or a
    /// foreign/recycled event the WR-05 marker guard refuses to touch) is skipped
    /// with a notice; a pair whose event still exists but whose write genuinely
    /// failed gets its OWN distinct notice (review finding 1 — the old copy
    /// collapsed both into "could not be found", which is factually wrong for a
    /// save failure). Every OTHER pair is still attempted (no early return on one
    /// pair's failure).
    func confirmDriftUpdateEvent() {
        guard let prompt = driftPrompt else { return }
        driftPrompt = nil
        bulkPushMine(prompt.drifted)
    }

    /// The task-wins bulk-push funnel, shared by `confirmDriftUpdateEvent` and the bulk
    /// re-anchor "Times moved with you" choice (roadmap 3.3 slice 2). Pushes each pair's
    /// task fields onto its event through the per-pair `updateEventForDrift`; a pair whose
    /// event is gone (`.notFound`) or whose save failed (`.failed`) is counted and skipped
    /// while every OTHER pair is still attempted (review finding 1 — per-pair isolation, no
    /// early return). The combined skip notice is published when the batch finishes.
    private func bulkPushMine(_ pairs: [(task: Todo, event: CalendarEvent)]) {
        driftUpdateSkipNotice = nil
        editTask = Task { [weak self] in
            guard let self else { return }
            var notFoundCount = 0
            var failedCount = 0
            for pair in pairs {
                switch await self.updateEventForDrift(pair) {
                case .updated:
                    break
                case .notFound:
                    notFoundCount += 1
                case .failed:
                    failedCount += 1
                }
            }
            self.driftUpdateSkipNotice = Self.driftUpdateNotice(notFound: notFoundCount, failed: failedCount)
        }
    }

    /// Builds the per-resolve "Update event" skip notice (review finding 1).
    /// `.notFound` and `.failed` are DISTINCT outcomes and must never share copy that
    /// claims "not found" for a genuine save failure. When only `.notFound` pairs were
    /// skipped, the original copy applies ("not found" covers BOTH a genuinely deleted
    /// event and a foreign/recycled id the WR-05 marker guard refused — deliberately not
    /// claiming "deleted", since the guard case is not a deletion). When ANY pair failed
    /// to save — alone or mixed with `.notFound` pairs — the notice falls back to the
    /// generic "could not be updated" copy over the combined count, since claiming "not
    /// found" would misdescribe the failed pairs in that mix. Returns nil when nothing
    /// was skipped.
    private static func driftUpdateNotice(notFound: Int, failed: Int) -> String? {
        guard notFound + failed > 0 else { return nil }
        guard failed == 0 else {
            let total = notFound + failed
            return total == 1
                ? "1 calendar event could not be updated."
                : "\(total) calendar events could not be updated."
        }
        return notFound == 1
            ? "1 calendar event could not be found and was not updated."
            : "\(notFound) calendar events could not be found and were not updated."
    }

    /// Per-pair task-wins "Update event" push (roadmap 2.3): rewrites ONE drifted
    /// pair's linked calendar event from the TASK's own fields — sanitized text
    /// (`CalendarDrift.sanitize`, the SAME derivation the create path uses, so the
    /// title agrees with what drift detection recomputes) and the task's time block.
    /// Callable independently of the drift-prompt UI (a later roadmap-3.3 task reuses
    /// it for the bulk TZ-shift "times moved with you" resolution).
    ///
    /// Returns `.notFound` when the event is gone (`.eventNotFound`, including the WR-05
    /// marker guard refusing a foreign/recycled id) or `.failed` when the push otherwise
    /// failed (already logged) — kept DISTINCT (review finding 1) so the caller's notice
    /// copy never claims "not found" for a genuine save failure. Never recreates on
    /// either outcome — recreating on a task-wins confirm would silently multiply events
    /// for a user who only meant to update one. A missing coordinator/link/block (should
    /// not happen for a pair sourced from `driftPrompt`, which only carries linked tasks)
    /// also reports `.failed`, since it is not an "event not found in Calendar" case.
    func updateEventForDrift(_ pair: (task: Todo, event: CalendarEvent)) async -> CalendarCoordinator.UpdateEventOutcome {
        guard let calendarCoordinator,
              let eventID = pair.task.calEventID,
              let block = pair.task.timeBlock else { return .failed }
        let title = CalendarDrift.sanitize(title: pair.task.text)
        return await calendarCoordinator.updateEvent(
            eventID: eventID, title: title, block: block, context: "driftUpdateEvent")
    }

    /// Dismisses the "Update event" skip notice (non-blocking, user-dismissible).
    func dismissDriftUpdateSkipNotice() {
        driftUpdateSkipNotice = nil
    }

    private func reloadOnMain(clearMissingLinks: Bool = true) async {
        await MainActor.run { self.reload(clearMissingLinks: clearMissingLinks) }
    }

    // MARK: - Row affordances (SC1 / SC4)

    /// Moves the task to TOMORROW's file (SC4). "Tomorrow" is computed from the current
    /// day (`now()`), NOT from the task's creation day, so a stale leftover (created days
    /// ago) lands on the real tomorrow and stops being a leftover — never written back to a
    /// past-day file (CR-01). The source file is TODAY's file — the one every visible row
    /// was loaded from (IN-03: a rolled leftover's visible copy lives in today's doc; its
    /// createdAt-day file holds only the hidden rolled_to:-marked line, so a createdAt
    /// source left the visible copy in place and duplicated onto tomorrow). Disk is the
    /// source of truth: the store removes it from today and lands it on tomorrow
    /// (re-partitioned createdAt), then we reload so it leaves today's list.
    ///
    /// Sweep WR: the store re-anchors the task's `time:` block to TOMORROW's wall-clock
    /// slot during the move, but a linked calendar EVENT stays on its original day.
    /// Left unmoved, the next day's day-filtered calendar fetch cannot find the event
    /// (now a day behind the task's block) and the drift pass FALSELY classifies the
    /// task as missing — whose "clear dead link" confirm then orphans the still-live
    /// event. So for a linked task we move the event too: update it in place to the
    /// re-anchored block (recreate-and-relink if it was deleted), mirroring `editTime`,
    /// so the link stays valid across the move. A failure logs, never crashes.
    func moveToTomorrow(_ task: Todo) {
        let snapshot = now()
        do {
            try store.moveTodoToTomorrow(id: task.id, from: snapshot, now: snapshot)
        } catch {
            NSLog("[Jotty] moveToTomorrow failed: \(error.localizedDescription)")
        }

        if let calendarCoordinator, let eventID = task.calEventID {
            let cal = DailyFile.calendar(timezone: timezone)
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: snapshot))!
            // Re-read the block the store actually re-anchored onto tomorrow (exact
            // wall-clock match, DST-correct) so the event lands on the same slot as the task.
            let movedBlock = (try? store.readDoc(on: tomorrowStart))?
                .tasks.first { $0.id == task.id }?.timeBlock
            if let movedBlock {
                let title = CalendarDrift.sanitize(title: task.text)
                editTask = Task { [weak self] in
                    guard let self else { return }
                    let outcome = await calendarCoordinator.updateOrRecreate(
                        eventID: eventID, title: title, block: movedBlock,
                        context: "moveToTomorrow")
                    if case .recreated(let newID) = outcome {
                        // Event deleted in Calendar: relink the recreated one on tomorrow.
                        self.relink(taskID: task.id, block: movedBlock,
                                    newEventID: newID, on: tomorrowStart)
                    }
                }
            }
        }

        reload()
    }

    /// Opens the markdown day file the task lives in (SC4). Read-only reveal in the
    /// user's default .md handler; never mutates state. Post-rollover, "the file the
    /// task lives in" is TODAY's file — the doc the visible line was loaded from
    /// (IN-03); the createdAt-day file holds only the rolled_to:-marked origin line.
    func openDayFile(_ task: Todo) {
        let url = DailyFile.url(in: store.folder, on: now(), timezone: store.timezone)
        NSWorkspace.shared.open(url)
    }

    /// Hands the task off to Claude (SC1). Wraps the task text in the prompt template
    /// once (`ClaudePrompt.wrapped`) — the handoff takes the FINAL prompt — and routes
    /// it through the injected seam. When Code mode reports no `claude` binary
    /// (`send` returns false), surface a one-line notice pointing to Web mode
    /// (D-SC1 graceful degrade). No-op when no handoff is injected.
    func sendToClaude(_ task: Todo) {
        guard let claudeHandoff else { return }
        let context = claudeContext(for: task)
        // Mode-aware cap: Web/URL truncates hard, Code/argv allows fuller text (#1).
        let cap = (configStore?.config.claudeAction ?? .web) == .web
            ? ClaudePrompt.webContextCap
            : ClaudePrompt.codeContextCap
        let prompt = ClaudePrompt.wrapped(taskText: task.text,
                                          sourceNoteBody: context.body,
                                          siblingTitles: context.siblings,
                                          maxContextLength: cap)
        let delivered = claudeHandoff.send(prompt: prompt)
        if !delivered {
            claudeNotice = "Claude Code isn’t available — switch to Web mode in Settings → AI."
        }
    }

    /// Reads TODAY's doc (the file every visible row was loaded from, IN-03) and
    /// gathers the Send-to-Claude context for `task` (#1): the body of the note the
    /// task was extracted from (`sourceNote`), and the titles of its SIBLING tasks —
    /// other tasks in the same day sharing the same `sourceNote`, excluding `task`.
    /// Graceful when the note is missing or the read throws (empty context → the
    /// builder degrades to the plain wrapped prompt). Pure read, no mutation.
    private func claudeContext(for task: Todo) -> (body: String?, siblings: [String]) {
        guard let noteID = task.sourceNote,
              let doc = try? store.readDoc(on: now()) else {
            return (nil, [])
        }
        let body = doc.notes.first { $0.id == noteID }?.text
        let siblings = doc.tasks
            .filter { $0.sourceNote == noteID && $0.id != task.id }
            .map(\.text)
        return (body, siblings)
    }

    /// Commits an inline rename (SC4). The store rewrites only the task's text,
    /// preserving id + every metadata token, and rejects an empty-after-trim rename
    /// (no write — the caller reverts the UI). Anchored on TODAY's file, the doc the
    /// visible row came from (IN-03: renaming a rolled leftover on its createdAt day
    /// rewrote the hidden origin line and the reload reverted the user's edit). Disk
    /// stays the source of truth; we reload so the list reflects the new text. A
    /// failure logs, never crashes.
    func rename(_ task: Todo, to text: String) {
        do {
            try store.renameTodo(id: task.id, text: text, on: now())
        } catch {
            NSLog("[Jotty] rename failed: \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - Snooze + recurrence (Phase 8 SC2/SC3)

    /// Snoozes the task until `date` (SC3 / CALX-03): the Store writes the
    /// `snooze:` token in place on TODAY's file — the file every visible row
    /// was loaded from (CR-03: a rolled leftover's visible copy lives in
    /// today's doc; its `createdAt`-day file holds only the hidden
    /// `rolled_to:`-marked origin line, so anchoring there was a silent
    /// no-op). Visibility only, the task is never relocated (distinct from
    /// move-to-tomorrow); the reload then drops it from today's partitions
    /// until the date arrives. A failure logs, never crashes.
    func snooze(_ task: Todo, to date: Date) {
        do {
            try store.snoozeTodo(id: task.id, to: date, on: now())
        } catch {
            NSLog("[Jotty] snooze failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Sets the task's recurrence rule (SC2 / CALX-02 UI surface); `nil` clears
    /// it (the Repeat "None" choice). Anchored on TODAY's file, same as
    /// `snooze` (CR-03). Persists the `recur:` token via the Store, then
    /// reloads. A failure logs, never crashes.
    ///
    /// CR-04: after day 1 the only line the user can reach is an INSTANCE
    /// (`recur_src` set) — the rule that actually drives instancing lives on
    /// the TEMPLATE, on a past day's file the menubar never shows. Writing the
    /// instance line alone was completely inert: "None" never stopped the
    /// recurrence and a rule change never changed it. For an instance, the
    /// template is resolved through the marker's id and edited too.
    func setRecurrence(_ task: Todo, to recurrence: Recurrence?) {
        do {
            if let marker = task.recurSrc,
               let templateID = marker.split(separator: ":", maxSplits: 1).first.map(String.init),
               !templateID.isEmpty {
                try setTemplateRecurrence(templateID: templateID, to: recurrence, instance: task)
            } else {
                try store.setTodoRecurrence(id: task.id, to: recurrence, on: now())
            }
        } catch {
            NSLog("[Jotty] setRecurrence failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Applies a Repeat choice made ON AN INSTANCE to its template (CR-04).
    ///
    /// The template line (`recur` set, no `recur_src`) is located by scanning
    /// the existing day files newest-first (mirrors the rollover template
    /// scan — templates persist on their origin day, unbounded by any window).
    ///
    /// - Rule change: the template's `recur` is rewritten, so future
    ///   instancing follows the new rule from tomorrow.
    /// - "None": the template's `recur` is cleared AND the line is marked
    ///   `rolled_to:` today — with the rule gone it would otherwise become an
    ///   ordinary not-done line on a past day, which the NEXT rollover would
    ///   collect as a leftover, resurrecting the just-cancelled task.
    ///   `rolled_to` already means "this line's lineage continues elsewhere;
    ///   never roll it again", and today's instance IS that continuation.
    ///
    /// The visible instance line mirrors the rule so the Repeat checkmark
    /// reflects the choice immediately; its `recur_src` stays, so it can never
    /// itself be scanned as a template (no duplicate templates).
    ///
    /// Fallback when the template line is unreachable (deleted file /
    /// hand-edited line): choosing a rule PROMOTES the instance to a template
    /// (clear `recur_src`, set `recur`) so the choice takes effect instead of
    /// silently decorating a dead lineage; choosing "None" just clears the
    /// visible line (nothing can instance anymore anyway).
    private func setTemplateRecurrence(templateID: String, to recurrence: Recurrence?,
                                       instance: Todo) throws {
        let snapshot = now()
        let cal = DailyFile.calendar(timezone: timezone)
        let todayStart = cal.startOfDay(for: snapshot)

        let templateDay = store.allDayDates().sorted(by: >).first { day in
            guard let doc = try? store.readDoc(on: day) else { return false }
            return doc.tasks.contains { $0.id == templateID && $0.recur != nil && $0.recurSrc == nil }
        }

        guard let templateDay else {
            if recurrence != nil {
                // Promote the instance: it becomes the template going forward.
                try store.mutateDay(on: snapshot) { doc in
                    guard let idx = doc.tasks.firstIndex(where: { $0.id == instance.id }) else { return false }
                    doc.tasks[idx].recur = recurrence
                    doc.tasks[idx].recurSrc = nil
                    return true
                }
            } else {
                try store.setTodoRecurrence(id: instance.id, to: nil, on: snapshot)
            }
            NSLog("[Jotty] setRecurrence: template %@ not found; applied to instance only", templateID)
            return
        }

        try store.mutateDay(on: templateDay) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == templateID }) else { return false }
            doc.tasks[idx].recur = recurrence
            if recurrence == nil, !doc.tasks[idx].done, doc.tasks[idx].rolledTo == nil {
                doc.tasks[idx].rolledTo = todayStart
            }
            return true
        }
        // Mirror onto the visible line (checkmark reflects reality).
        try store.setTodoRecurrence(id: instance.id, to: recurrence, on: snapshot)
    }

    /// The Snooze-to "Tomorrow" target: startOfDay(now()) + 1 day. Anchored on
    /// `now()`, NEVER task.createdAt (CR-01) — snoozing a stale leftover must
    /// target the real tomorrow, not a day in the past.
    var snoozeTomorrowDate: Date { snoozeDate(daysFromToday: 1) }

    /// The Snooze-to "Next week" target: startOfDay(now()) + 7 days (CR-01).
    var snoozeNextWeekDate: Date { snoozeDate(daysFromToday: 7) }

    private func snoozeDate(daysFromToday days: Int) -> Date {
        let cal = DailyFile.calendar(timezone: timezone)
        let todayStart = cal.startOfDay(for: now())
        return cal.date(byAdding: .day, value: days, to: todayStart) ?? todayStart
    }

    // MARK: - Drag-to-time-block (Phase 8 SC1 / CALX-01)

    /// Default duration of a block created by dropping an unscheduled task onto a
    /// canvas time slot (RESEARCH A2: 30 min — Claude discretion). Derived from
    /// the CanvasLayout constant so the layout math and the model can never
    /// disagree on the drop duration (IN-04: single source of truth).
    static let defaultDropDuration: TimeInterval =
        TimeInterval(CanvasLayout.defaultDropDurationMinutes * 60)

    /// The canvas rail source (plan 05): visible, not-done tasks with no `time:`
    /// block — the draggable "unscheduled" set. Built from the SAME partitions the
    /// menubar list renders, so a future-snoozed task never appears in the rail
    /// (CALX-03) and leftovers stay draggable onto today's canvas.
    var unscheduledTasks: [Todo] {
        (leftovers + todayTasks).filter { $0.timeBlock == nil && !$0.done }
    }

    /// Drops the task with `id` onto the canvas slot `slot` (SC1 / CALX-01).
    ///
    /// Unscheduled task: sets `time:` = [slot, slot + `defaultDropDuration`) on disk
    /// FIRST (`store.updateTodoTime`, T-5-09), then — best-effort, mirroring
    /// `editTime`'s shape — runs the EXACT Phase-5 create path on a dedicated handle:
    /// conflict gate (`overlappingEvents` → decision, T-8-10), `createEvent` with the
    /// SANITIZED title (T-8-08), `cal_event:` write-back (mirrors `writeCalEventID` /
    /// `recreateAndRelink`), ending in `reloadOnMain(clearMissingLinks: false)` so
    /// the CR-02 self-heal never races the just-written id. A calendar failure logs
    /// and leaves the time-blocked task on disk with no `cal_event:` (T-8-09).
    ///
    /// Already-scheduled task (CONTEXT "unscheduled only"): the drop is a MOVE —
    /// delegate to `editTime`, which updates a linked event in place (or recreates a
    /// missing one) and never creates a duplicate. Unknown id: no-op.
    func dropTask(id: String, atSlot slot: Date) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let snapshot = now()

        // WR-03: clamp the slot so the whole default-duration block fits
        // INSIDE today. The drop layer spans the full 24h axis, so a snapped
        // slot can be as late as 24:00 — but the `time:` token serializes
        // wall-clock only, and a block touching midnight re-parses on the
        // doc's OWN day with end 00:00 < start (inverted), permanently out of
        // sync with the created event. The latest allowed start sits one snap
        // step short of the exact day-end fit, so the clamped start stays
        // grid-aligned AND the block's end lands strictly before midnight.
        let cal = DailyFile.calendar(timezone: timezone)
        let dayStart = cal.startOfDay(for: snapshot)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 3600)
        let snapStep = TimeInterval(CanvasLayout.defaultSnapMinutes * 60)
        let latestStart = dayEnd.addingTimeInterval(-(Self.defaultDropDuration + snapStep))
        let start = min(max(slot, dayStart), latestStart)
        let block = TimeBlock(start: start,
                              end: start.addingTimeInterval(Self.defaultDropDuration))

        if task.timeBlock != nil {
            editTime(task, to: block)
            return
        }

        do {
            // Disk first (T-5-09): the block lands even if every calendar step fails.
            try store.updateTodoTime(id: id, timeBlock: block, on: snapshot)
        } catch {
            // The time: write failed — continuing would conflict-gate, create the event,
            // and write `cal_event:` onto a task with NO `time:`, which the drift pass
            // permanently ignores (it requires both fields) → an orphaned event. Stop.
            NSLog("[Jotty] dropTask time write failed: \(error.localizedDescription)")
            reload()
            return
        }

        guard let calendarCoordinator else {
            reload()   // pure task tool: time-blocked on disk, no event.
            return
        }

        // Sanitize BEFORE the event write so task text cannot smuggle control
        // chars / markdown into the EKEvent title (T-8-08 — shared create/compare
        // function, same as capture + editTime).
        let title = CalendarDrift.sanitize(title: task.text)
        dropHandle = Task { [weak self] in
            guard let self else { return }
            // Conflict gate (Phase-5 SC5 semantics, T-8-10): a read failure is
            // non-fatal — fall through to create, exactly like the capture pass.
            var commitAnyway = true
            if let conflictTitle = await calendarCoordinator.firstConflictTitle(
                overlapping: block, excludingEventID: nil) {
                commitAnyway = await self.awaitDropConflictDecision(title: conflictTitle)
            }
            if commitAnyway {
                // Same cross-midnight guard as editTime: a conflict decision that
                // arrives on a later day must not create an event for the stale
                // (yesterday) slot or write the link into yesterday's file.
                guard DailyFile.calendar(timezone: self.timezone)
                    .isDate(self.now(), inSameDayAs: snapshot) else {
                    await self.reloadOnMain(clearMissingLinks: false)
                    return
                }
                do {
                    let eventID = try await calendarCoordinator.createEvent(title: title,
                                                                            block: block)
                    self.writeDropCalEventID(eventID, forTaskID: id, on: snapshot)
                } catch {
                    // Best-effort (T-8-09): the time-blocked task stays on disk,
                    // just without a cal_event link.
                    NSLog("[Jotty] dropTask createEvent failed: \(error.localizedDescription)")
                }
            }
            // Skip the dead-link self-heal on the trailing reload: the id was just
            // written and a stale fetch must not clear it (same as editTime, CR-02).
            await self.reloadOnMain(clearMissingLinks: false)
        }
    }

    /// Sets `cal_event:<id>` on the just-dropped task line and re-persists the day's
    /// tasks (mirrors `CaptureViewModel.writeCalEventID` + `recreateAndRelink`).
    private func writeDropCalEventID(_ eventID: String, forTaskID id: String, on date: Date) {
        do {
            try store.mutateDay(on: date) { doc in
                guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
                doc.tasks[idx].calEventID = eventID
                return true
            }
        } catch {
            NSLog("[Jotty] dropTask cal_event write-back failed: \(error.localizedDescription)")
        }
    }

    /// Publishes a pending drop/move conflict and suspends until the canvas or popover UI
    /// calls `resolveDropConflict(...)` (mirrors `CaptureViewModel.awaitConflictDecision`).
    ///
    /// WR-02: conflicts are SERIALIZED — a second drop reaching this gate while
    /// an earlier decision is still pending would otherwise overwrite the
    /// stored continuation without resuming it, suspending the first drop's
    /// task forever (Swift logs CONTINUATION MISUSE) and orphaning its handle.
    /// The stale pending drop is pre-empted as a cancel (the same safe default
    /// as the capture window's teardown, CQ-02): for a `.create` its time: block
    /// is already on disk and only the event create is skipped; for a `.move`
    /// nothing has been written yet, so the pre-empt changes nothing.
    private func awaitDropConflictDecision(title: String,
                                           kind: CalendarConflict.Kind = .create) async -> Bool {
        resolveDropConflict(commitAnyway: false)   // pre-empt a stale pending drop
        pendingDropConflict = CalendarConflict(conflictTitle: title, kind: kind)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            dropConflictContinuation = c
        }
    }

    /// Resolves a pending drop conflict (plan 05's canvas alert calls this).
    /// `true` = create the event anyway; `false` = skip the create — the time:
    /// block is already on disk either way (disk wins). No-op if nothing pends;
    /// nil-before-resume makes double-resume structurally impossible (same
    /// pattern as `CaptureViewModel.resolveConflict`). `pendingDropConflict`
    /// is cleared HERE — not after the await in `awaitDropConflictDecision` —
    /// so a pre-empted drop's later resumption can never clobber a newer
    /// pending conflict's published state (WR-02).
    func resolveDropConflict(commitAnyway: Bool) {
        guard let c = dropConflictContinuation else { return }
        dropConflictContinuation = nil
        pendingDropConflict = nil
        c.resume(returning: commitAnyway)
    }

    /// Awaits all in-flight drop work (test hook, mirrors `awaitCalendarRefresh`):
    /// the drop's calendar pass first, then the edit handle (a drop on a scheduled
    /// task delegates to `editTime`), then the trailing refresh either spawned.
    func awaitDropWork() async {
        if let t = dropHandle { _ = await t.value }
        if let t = editTask { _ = await t.value }
        if let t = refreshTask { _ = await t.value }
    }

    var doneCount: Int { tasks.filter(\.done).count }

    /// The tasks actually VISIBLE in the popover: the snooze-filtered partitions
    /// (leftovers + today), NOT the snooze-inclusive `tasks`. The empty-state hint
    /// and the header count gate on THIS (sweep INFO) so a day whose only tasks are
    /// snoozed to a future date shows the "No tasks today" hint and a 0-count badge
    /// instead of hiding the hint and over-counting invisible snoozed rows.
    var visibleTasks: [Todo] { leftovers + todayTasks }
    /// Done count among the visible (snooze-filtered) partitions — the numerator for
    /// the "N of M done" header badge, so it never counts future-snoozed rows.
    var visibleDoneCount: Int { visibleTasks.filter(\.done).count }

    /// Today's partition split for rendering (#4): OPEN tasks render inline; DONE
    /// tasks move into the collapsible "Done · N" group. `todayTasks` stays the full
    /// set (the canvas blocks and counts read it), so this is presentation-only.
    var todayOpen: [Todo] { todayTasks.filter { !$0.done } }
    var todayDone: [Todo] { todayTasks.filter(\.done) }

    /// Row identity for the task-list LazyVStack. Embeds the SECTION (leftover /
    /// open / done), not just the task id: the lazy container caches built rows by
    /// identity across the WHOLE container, so a row whose identity survived a
    /// toggle was re-shown in the "Done · N" group with its PRE-toggle content
    /// (empty checkbox, no strikethrough) until the popover was rebuilt. A
    /// section-qualified identity makes the moved row a NEW identity that must be
    /// built fresh from the current Todo value.
    static func rowID(_ task: Todo, isLeftover: Bool) -> String {
        if isLeftover { return "leftover-\(task.id)" }
        return task.done ? "done-\(task.id)" : "open-\(task.id)"
    }

    /// The scroll target for the command-bar highlight: resolves which section the
    /// task currently renders in and returns that row's section-qualified identity,
    /// so `scrollTo` keeps finding rows now that they no longer use the bare task id.
    /// Unknown ids fall back to the raw id, which matches nothing — same as before.
    func rowScrollID(for taskID: String) -> String {
        if let t = leftovers.first(where: { $0.id == taskID }) {
            return Self.rowID(t, isLeftover: true)
        }
        if let t = todayTasks.first(where: { $0.id == taskID }) {
            return Self.rowID(t, isLeftover: false)
        }
        return taskID
    }

    /// startOfDay(now()) in the model timezone — the read-only dayStart anchor
    /// the calendar canvas (plan 08-05) derives its axis from. Kept alongside
    /// the private `now()` so the canvas never needs its own clock and its
    /// positions agree with the partitioning above by construction.
    var startOfToday: Date {
        let cal = DailyFile.calendar(timezone: timezone)
        return cal.startOfDay(for: now())
    }

    /// Today's gregorian weekday (1=Sun…7=Sat) in the model timezone — the weekday
    /// a "Weekly" Repeat choice anchors to (sweep INFO). Capturing the CHOSEN
    /// weekday (rather than deriving it from the task's createdAt) makes a Weekly
    /// rule set on a Tuesday fire on Tuesdays, even for a task created on another
    /// weekday.
    var currentWeekday: Int {
        let cal = DailyFile.calendar(timezone: timezone)
        return cal.component(.weekday, from: now())
    }

    /// Abbreviated origin-day label ("Jun 28") for a leftover row, or nil when the task
    /// originated yesterday — the common case needs no per-row date (UX-05). Display-only:
    /// never feeds the leftover grouping/filter itself (Phase 8 owns the TZ rework).
    func originLabel(for task: Todo) -> String? {
        let cal = DailyFile.calendar(timezone: timezone)
        let todayStart = cal.startOfDay(for: now())
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart),
              cal.startOfDay(for: task.createdAt) != yesterdayStart else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = timezone
        return f.string(from: task.createdAt)
    }

    private func collapseKey(for date: Date) -> String {
        "leftoversCollapsed-\(dayKey(for: date))"
    }

    /// Day-keyed persistence key for the "Done · N" collapse state (#4), parallel to
    /// `collapseKey`.
    private func doneCollapseKey(for date: Date) -> String {
        "doneCollapsed-\(dayKey(for: date))"
    }

    /// The shared `yyyy-MM-dd` day component for the collapse keys. Fixed-format,
    /// POSIX-pinned so region calendar settings (Buddhist/Japanese era years) cannot
    /// skew it; timezone-pinned to match the day partitioning.
    private func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezone
        return f.string(from: date)
    }
}
