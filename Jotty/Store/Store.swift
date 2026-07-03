import Foundation

final class Store {
    let folder: URL
    let timezone: TimeZone

    init(folder: URL, timezone: TimeZone = .current) {
        self.folder = folder
        self.timezone = timezone
    }

    func appendCapture(noteText: String, noteId: String?, tasks: [Todo], at time: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = DailyFile.url(in: folder, on: time, timezone: timezone)
        var doc = readOrCreate(at: url, on: time)
        for task in tasks { doc.appendTodo(task) }
        if !noteText.isEmpty, let noteId {
            doc.appendNote(text: noteText, at: time, id: noteId)
        }
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    func appendNote(text: String, at time: Date, id: String) throws {
        try appendCapture(noteText: text, noteId: id, tasks: [], at: time)
    }

    func toggleTodo(id: String, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].done.toggle()
        doc.tasks[idx].completedAt = doc.tasks[idx].done ? Date() : nil
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the task with `id` from the day's markdown (SC3). No-op when the id
    /// is absent. Disk is the source of truth; the matching calendar event (if any)
    /// is handled best-effort by the caller, never here.
    func deleteTodo(id: String, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks.remove(at: idx)
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sets the task's `timeBlock` and re-serializes (SC3 edit-time). No-op when the
    /// id is absent. The `cal_event:` link is preserved; the linked event is updated
    /// best-effort by the caller, never here.
    func updateTodoTime(id: String, timeBlock: TimeBlock, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].timeBlock = timeBlock
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sets the task's `snooze` date and re-serializes (Phase 8 SC3 / CALX-03).
    /// Snooze affects VISIBILITY only (the menubar filter hides the task until the
    /// date), never storage location — the task stays in its day file, distinct
    /// from move-to-tomorrow which relocates. No-op when the id is absent,
    /// mirroring `updateTodoTime`. The index-mutate IS a whole-value copy-mutate
    /// (a Swift array element assign preserves every other field — never rebuild
    /// via `Todo(id:…)`, Phase 7 CR-01).
    func snoozeTodo(id: String, to snoozeDate: Date, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].snooze = snoozeDate
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sets (or, with `nil`, clears — the "None" Repeat choice) the task's
    /// recurrence rule and re-serializes (Phase 8 SC2 UI / CALX-02). No-op when
    /// the id is absent, mirroring `updateTodoTime`. Same whole-value copy-mutate
    /// as `snoozeTodo` (Phase 7 CR-01: every other token survives).
    func setTodoRecurrence(id: String, to recurrence: Recurrence?, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].recur = recurrence
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rewrites only the task's `text`, preserving id + every metadata token
    /// (created/done/due/rolled_to/source_note/time/cal_event) via the serialize
    /// round-trip (SC4 inline rename). The new text is trimmed; an empty-after-trim
    /// rename is rejected (no write — the file stays byte-identical so the caller can
    /// revert the UI). No-op when the id is absent, mirroring deleteTodo. No new
    /// escaping: serialize's IN-01 guard neutralizes `<!--`/`-->` in the text (T-6-07).
    func renameTodo(id: String, text: String, on date: Date) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].text = trimmed
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Moves the task with `id` from the file it currently lives in (`sourceDate`) to
    /// TOMORROW's file, where "tomorrow" is `startOfDay(now) + 1 day` — derived from the
    /// CURRENT day, NOT the task's (possibly past) creation day (CR-01). A leftover that
    /// originated several days ago therefore lands on the real tomorrow and stops being a
    /// leftover, instead of being written back into a stale past-day file.
    ///
    /// Removes it from the source file and writes that file first, then appends an
    /// equivalent task to tomorrow's file — so a mid-failure leaves the task on at least
    /// one file, never silently lost (T-6-08). The moved task keeps id/text/tokens but has
    /// `createdAt` advanced to tomorrow's startOfDay, so the menubar partitions it as a
    /// tomorrow task rather than a leftover. No-op when the id is absent. A source==tomorrow
    /// no-op move re-reads/rewrites the same file consistently (the remove-then-append
    /// round-trips through one document).
    func moveTodoToTomorrow(id: String, from sourceDate: Date, now: Date) throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: startOfDay(now))!

        let sourceURL = DailyFile.url(in: folder, on: sourceDate, timezone: timezone)
        var sourceDoc = readOrCreate(at: sourceURL, on: sourceDate)
        guard let idx = sourceDoc.tasks.firstIndex(where: { $0.id == id }) else { return }

        // Copy the WHOLE value so every field (id/text/tokens, and the Phase-7
        // source/sourceURL provenance, plus any future field) carries across the
        // move untouched — only createdAt is advanced. A field-by-field rebuild
        // here silently dropped source/sourceURL once (Phase 7 CR-01); the
        // copy-mutate pattern can never regress as fields are added.
        var moved = sourceDoc.tasks[idx]
        moved.createdAt = tomorrowStart

        let tomorrowURL = DailyFile.url(in: folder, on: tomorrowStart, timezone: timezone)

        // Same-file move (source day IS tomorrow): replace the element in the single doc so
        // the remove + append round-trip through one consistent document instead of racing
        // two reads/writes against the same path (and never duplicating the task).
        if sourceURL == tomorrowURL {
            sourceDoc.tasks[idx] = moved
            try sourceDoc.serialize(timezone: timezone).write(to: sourceURL, atomically: true, encoding: .utf8)
            return
        }

        // Remove from the source file and persist first so a partial failure never deletes
        // without landing.
        sourceDoc.tasks.remove(at: idx)
        try sourceDoc.serialize(timezone: timezone).write(to: sourceURL, atomically: true, encoding: .utf8)

        // Append to tomorrow and persist.
        var tomorrowDoc = readOrCreate(at: tomorrowURL, on: tomorrowStart)
        tomorrowDoc.appendTodo(moved)
        try tomorrowDoc.serialize(timezone: timezone).write(to: tomorrowURL, atomically: true, encoding: .utf8)
    }

    func replaceTasks(_ tasks: [Todo], on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        doc.tasks = tasks
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    func readDoc(on date: Date) throws -> MarkdownDoc {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        return readOrCreate(at: url, on: date)
    }

    private func readOrCreate(at url: URL, on date: Date) -> MarkdownDoc {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           let parsed = try? MarkdownDoc.parse(existing, timezone: timezone) {
            return parsed
        }
        return MarkdownDoc(date: startOfDay(date))
    }

    private func startOfDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.startOfDay(for: d)
    }
}
