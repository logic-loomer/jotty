import Foundation

final class RolloverService {
    let store: Store
    let statePath: URL
    let timezone: TimeZone
    let maxLookbackDays: Int

    init(store: Store, statePath: URL, timezone: TimeZone = .current, maxLookbackDays: Int = 14) {
        self.store = store
        self.statePath = statePath
        self.timezone = timezone
        self.maxLookbackDays = maxLookbackDays
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
        var cursor = cal.date(byAdding: .day, value: -1, to: today)!
        while cursor >= lookbackStart {
            var doc = (try? store.readDoc(on: cursor)) ?? MarkdownDoc(date: cursor)
            var changed = false
            var rewritten: [Todo] = []
            for taskItem in doc.tasks {
                var task = taskItem
                // A recurring TEMPLATE (recur set, no recur_src marker) is never
                // collected as a leftover and never marked rolled — it persists on
                // its origin day as the source of future instances (SC2/CALX-02).
                // Instances (recur_src set) and non-recurring tasks roll as before.
                let isTemplate = task.recur != nil && task.recurSrc == nil
                if !task.done && task.rolledTo == nil && !isTemplate {
                    var copy = task
                    copy.rolledTo = nil
                    collected.append(copy)
                    task.rolledTo = today
                    changed = true
                }
                rewritten.append(task)
            }
            if changed {
                doc.tasks = rewritten
                try store.replaceTasks(doc.tasks, on: cursor)
            }
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        let instances = try recurrenceInstances(for: today, calendar: cal)

        // CRITICAL: collected leftovers + recurrence instances merge into ONE
        // today write — a second replaceTasks call would race the first.
        if !collected.isEmpty || !instances.isEmpty {
            var todayDoc = (try? store.readDoc(on: today)) ?? MarkdownDoc(date: today)
            todayDoc.tasks.append(contentsOf: collected)
            todayDoc.tasks.append(contentsOf: instances)
            try store.replaceTasks(todayDoc.tasks, on: today)
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
            let doc = (try? store.readDoc(on: day)) ?? MarkdownDoc(date: day)
            for task in doc.tasks where task.recur != nil && task.recurSrc == nil {
                if seenIDs.insert(task.id).inserted { templates.append(task) }
            }
        }
        guard !templates.isEmpty else { return [] }

        let todayKey = dayFormatter().string(from: today)

        let todayDoc = (try? store.readDoc(on: today)) ?? MarkdownDoc(date: today)
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
    /// rollover state file. Pinned to `en_US_POSIX` (WR-05): under a user region
    /// with a non-Gregorian calendar (Buddhist/Japanese era) an unpinned
    /// formatter renders shifted years, and a region-settings CHANGE makes
    /// previously written markers/state unmatchable — defeating the idempotency
    /// guard (duplicate instances) and invalidating the state date. Same idiom
    /// as the menubar `collapseKey`. One shared builder so the three call sites
    /// can never drift.
    private func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezone
        return f
    }

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = timezone; return c
    }
}
