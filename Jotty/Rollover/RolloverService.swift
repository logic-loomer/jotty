import Foundation

final class RolloverService {
    /// Short scan-store coordination timeout (review finding, roadmap 3.4 phase 2):
    /// half of `Store`'s interactive default. `run()`'s two day-file scan loops
    /// (below) call this synchronously from the main actor
    /// (`AppDelegate.runRolloverCatchUp`, called from `applicationDidFinishLaunching`,
    /// `applicationDidBecomeActive`, and the midnight `Timer` — all main-actor,
    /// un-`Task`-wrapped). Each scanned file's `readDay` makes TWO independently
    /// bounded provider calls (the dataless-file probe, then the coordinated read),
    /// so the per-file worst case is 2 × timeout, not one. But the FIRST thrown
    /// timeout aborts the whole run: a wedged coordinated read throws
    /// `coordinationTimedOut`, which propagates out of the scan loop and ends
    /// `run()`. The full N × 2 × timeout compounding therefore materializes only in
    /// the narrow case where the probe stays wedged (each probe times out → nil,
    /// the loop continues) WHILE the reads keep succeeding — otherwise the run
    /// stops at the first read that wedges. A short per-call bound is the mitigation
    /// available without restructuring `Store`'s off-actor-plus-semaphore model.
    static let scanCoordinationTimeout: TimeInterval = 1.0

    let store: Store
    let statePath: URL
    let timezone: TimeZone
    let maxLookbackDays: Int
    /// A second `Store` — same folder/timezone as `store`, but with the short
    /// `scanCoordinationTimeout` — used ONLY for the day-file scan reads in `run()`
    /// (the lookback collect loop) and `recurrenceInstances` (the unbounded
    /// template scan). Writes (today's merge, origin `rolled_to` stamping) still go
    /// through `store` at its normal timeout: those calls are few (bounded by
    /// `maxLookbackDays`) and correctness-sensitive, unlike the scan reads.
    /// Test-injectable so a test can prove the scan path uses this timeout, not
    /// `store`'s.
    private let scanStore: Store

    init(store: Store, statePath: URL, timezone: TimeZone = .current, maxLookbackDays: Int = 14,
         scanStore: Store? = nil) {
        self.store = store
        self.statePath = statePath
        self.timezone = timezone
        self.maxLookbackDays = maxLookbackDays
        self.scanStore = scanStore ?? Store(folder: store.folder, timezone: store.timezone,
                                            coordinationTimeout: Self.scanCoordinationTimeout)
    }

    func run(now: Date) throws {
        let cal = calendar()
        let today = cal.startOfDay(for: now)

        let lastRollover = readState() ?? today
        let lookbackStart = max(
            cal.date(byAdding: .day, value: -maxLookbackDays, to: today) ?? today,
            cal.startOfDay(for: lastRollover)
        )

        var collected: [Todo] = []
        /// Origin-day rolled_to stamps (per-id), DEFERRED until after the
        /// today-write lands (see below). Ids, not whole-array snapshots: the
        /// stamps are applied through the funnel per-id so an external edit to
        /// any other line on the origin day survives (finding 1).
        var originStamps: [(day: Date, ids: Set<String>)] = []
        var cursor = cal.date(byAdding: .day, value: -1, to: today)!
        while cursor >= lookbackStart {
            // Unreadable origin day ABORTS the run (throw) before any write —
            // the old try?-skip advanced lastRollover past the day and stranded
            // its leftovers forever (finding 2). Reads through `scanStore` (short
            // timeout, review finding roadmap 3.4 phase 2): this loop runs
            // synchronously on the main actor, so a wedged provider must not
            // compound N reads at the full interactive timeout.
            let doc = try scanStore.readDoc(on: cursor)
            var stampIDs: Set<String> = []
            for task in doc.tasks {
                // A recurring TEMPLATE (recur set, no recur_src marker) is never
                // collected as a leftover and never marked rolled — it persists on
                // its origin day as the source of future instances (SC2/CALX-02).
                let isTemplate = task.recur != nil && task.recurSrc == nil
                // A recurring INSTANCE (recur_src set) is likewise NOT rolled forward
                // (sweep WR): the recurrence mechanism already lands a FRESH instance
                // each due day, so an uncompleted instance is superseded by tomorrow's
                // fresh one — it is not a generic leftover. Rolling it forward too made
                // an unbounded pile stack up (a fresh instance PLUS every rolled
                // predecessor, every day). An uncompleted instance is simply left on
                // its origin day (invisible — the menubar reads only today's file, and
                // the template scan skips recur_src lines); a COMPLETED instance is
                // already excluded by `!task.done` and archives normally.
                let isInstance = task.recurSrc != nil
                if !task.done && task.rolledTo == nil && !isTemplate && !isInstance {
                    var copy = task
                    copy.rolledTo = nil
                    // Clear STALE scheduling only — a block whose slot started before
                    // the new day was missed (that's what makes it a leftover), and
                    // keeping it caused false "event deleted" prompts: the wall-clock
                    // `time:` token re-anchored the past block onto the NEW day while
                    // the linked event stayed put. A FUTURE block stays scheduled and
                    // linked ("@tomorrow @3pm" captured yesterday IS today's 3pm —
                    // clearing it would silently unschedule a valid appointment); the
                    // day-qualified time: token round-trips it faithfully.
                    if let tb = copy.timeBlock, tb.start < today {
                        copy.timeBlock = nil
                        copy.calEventID = nil
                    }
                    // Dedupe within the collect (newest day wins — the loop walks
                    // backwards from yesterday): a mid-move crash can leave one id on
                    // TWO past days, and the today-write guard only checks ids already
                    // in today's doc, not ids appearing twice in this batch.
                    if !collected.contains(where: { $0.id == copy.id }) {
                        collected.append(copy)
                    }
                    stampIDs.insert(task.id)
                }
            }
            if !stampIDs.isEmpty {
                originStamps.append((day: cursor, ids: stampIDs))
            }
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        // CR-02: instancing is gated to the FIRST run of each calendar day.
        // run() fires repeatedly within a day (launch, the midnight Timer, and
        // every applicationDidBecomeActive catch-up); re-instancing on those
        // re-runs resurrected instances the user had DELETED (the deletion
        // removes the recur_src marker together with the line) and duplicated
        // instances the user had MOVED to tomorrow (the marker moves with the
        // line). Launch-after-midnight and the midnight timer both cross a day
        // boundary and still instance; same-day re-runs skip instancing, so
        // user deletions/moves stick. First-launch (no state file) mirrors the
        // collect loop's existing no-op semantics: nothing is instanced until
        // a day boundary is crossed (a fresh install has no templates anyway).
        // The recur_src marker check inside recurrenceInstances stays as a
        // second belt for a crash between the today-write and writeState.
        let isFirstRunOfDay = cal.startOfDay(for: lastRollover) < today
        let instances = isFirstRunOfDay
            ? try recurrenceInstances(for: today, calendar: cal)
            : []

        // CRITICAL: collected leftovers + recurrence instances merge into ONE
        // today write — a second replaceTasks call would race the first.
        //
        // Write ORDER is crash-safety (WR): today's merged doc lands BEFORE the origin
        // days are stamped `rolled_to`. The old order (stamp origins in the collect
        // loop, then write today) silently LOST every collected leftover if the
        // today-write failed or the app died between the two — the origins already
        // said "rolled", and the next run skipped them. With today-first, a crash
        // before the origin stamps just re-collects on the retry, and the id guard
        // below makes that retry a no-op instead of a duplicate.
        if !collected.isEmpty || !instances.isEmpty {
            // The merge is a funnel TRANSFORM against a fresh read (finding 1):
            // the old readDoc→replaceTasks pattern re-asserted a stale snapshot
            // over any external edit landing mid-write. Id guards keep the
            // crash-retry idempotency (a copy keeps its origin task id).
            try store.mutateDay(on: today) { doc in
                let existingIDs = Set(doc.tasks.map(\.id))
                doc.tasks.append(contentsOf: collected.filter { !existingIDs.contains($0.id) })
                doc.tasks.append(contentsOf: instances.filter { !existingIDs.contains($0.id) })
                return true
            }
        }

        // Only now stamp the origin days: the copies are safely on today's disk.
        // Per-id, funnel-checked — external edits to other lines survive.
        for stamp in originStamps {
            try store.mutateDay(on: stamp.day) { doc in
                var changed = false
                for idx in doc.tasks.indices where stamp.ids.contains(doc.tasks[idx].id)
                    && doc.tasks[idx].rolledTo == nil {
                    doc.tasks[idx].rolledTo = today
                    changed = true
                }
                return changed
            }
        }

        try writeState(today)
    }

    /// Builds the fresh recurring instances due on `today` (SC2 / CALX-02).
    ///
    /// Templates are gathered from EVERY existing day file strictly before
    /// `today` — deliberately NOT bounded by `maxLookbackDays` (CR-01). A
    /// template never moves (it persists on its origin day per CONTEXT /
    /// RESEARCH A1), so any bounded window silently kills every recurrence the
    /// moment its origin day falls out of that window: with the old 14-day
    /// scan, every recurring task died two weeks after "Repeat" was set. The
    /// enumeration cost is one directory listing plus small per-day parses, on
    /// a code path that runs a handful of times per day.
    ///
    /// Files are scanned newest-first so if one id somehow carries `recur` on
    /// two days (hand-edited history), the most recent line wins as template.
    ///
    /// The `recur_src:<templateId>:<yyyy-MM-dd>` marker check against today's
    /// doc is the second belt behind the first-run-of-day gate in `run()`
    /// (CR-02): it keeps a crash between the today-write and the state-write
    /// from duplicating instances on the retry.
    private func recurrenceInstances(for today: Date, calendar cal: Calendar) throws -> [Todo] {
        var templates: [Todo] = []
        var seenIDs = Set<String>()
        let days = store.allDayDates().filter { $0 < today }.sorted(by: >)
        for day in days {
            // Unbounded by `maxLookbackDays` (CR-01, doc above) — the day-file
            // count this loop reads only grows with app lifetime, so it is the
            // main compounding risk on the main-actor `run()` call path; hence
            // `scanStore`'s short timeout (review finding, roadmap 3.4 phase 2).
            let doc = try scanStore.readDoc(on: day)
            for task in doc.tasks where task.recur != nil && task.recurSrc == nil {
                if seenIDs.insert(task.id).inserted { templates.append(task) }
            }
        }
        guard !templates.isEmpty else { return [] }

        let todayKey = dayFormatter().string(from: today)

        let todayDoc = try store.readDoc(on: today)
        var existingMarkers = Set(todayDoc.tasks.compactMap { $0.recurSrc })

        var instances: [Todo] = []
        for template in templates {
            let templateWeekday = cal.component(.weekday, from: template.createdAt)
            guard let rule = template.recur,
                  rule.isDue(on: today, templateWeekday: templateWeekday, calendar: cal) else {
                continue
            }
            let marker = "\(template.id):\(todayKey)"
            // Idempotent guard: a prior run this day already instanced this template.
            guard !existingMarkers.contains(marker) else { continue }

            // COPY-MUTATE the whole template (Phase 7 CR-01 — never rebuild
            // field-by-field), then override: a fresh instance is a brand-new,
            // not-done, unscheduled, unlinked task created today.
            var instance = template
            instance.id = Todo.newID()
            instance.done = false
            instance.completedAt = nil
            instance.createdAt = today
            instance.rolledTo = nil
            instance.recurSrc = marker
            instance.timeBlock = nil
            instance.calEventID = nil
            // WR-01: a fresh instance carries NO inherited snooze/due — a
            // template snoozed on its origin day must not stamp every future
            // instance with a snooze: token (they would all hide until the
            // date and then dump as a backlog of leftovers), and a stale
            // template due: must not mark every instance overdue forever.
            // Documented semantics: snooze/due affect only the LINE they are
            // on; a snoozed template keeps instancing (its instances are the
            // user's recurring intent — pausing would silently backlog them).
            instance.snooze = nil
            instance.dueDate = nil
            instances.append(instance)
            existingMarkers.insert(marker)
        }
        return instances
    }

    private func readState() -> Date? {
        guard let s = try? String(contentsOf: statePath, encoding: .utf8) else { return nil }
        return dayFormatter().date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeState(_ date: Date) throws {
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try dayFormatter().string(from: date).write(to: statePath, atomically: true, encoding: .utf8)
    }

    /// The SHARED fixed-format day formatter for every machine-readable key this
    /// service writes or reads: the `recur_src` day key (`todayKey`) and the
    /// rollover state file. Delegates to `DailyFile.dayFormatter` — the ONE
    /// POSIX/Gregorian-pinned builder also used for day-file NAMES and the
    /// filename parse (`Store.allDayDates`) — so no pair of the four surfaces
    /// can ever drift (WR-05 + iteration-3 WR). See that helper's doc for the
    /// era-shift hazard the pin closes; same idiom as the menubar `collapseKey`.
    private func dayFormatter() -> DateFormatter {
        DailyFile.dayFormatter(timezone: timezone)
    }

    private func calendar() -> Calendar {
        DailyFile.calendar(timezone: timezone)
    }
}
