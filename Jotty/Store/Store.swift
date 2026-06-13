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

    /// Moves the task with `id` from today's file to tomorrow's file (SC4
    /// move-to-tomorrow). Removes it from today and writes today first, then appends an
    /// equivalent task to tomorrow's file — so a mid-failure leaves the task on at least
    /// one file, never silently lost (T-6-08). The moved task keeps id/text/tokens but
    /// has `createdAt` advanced to tomorrow's startOfDay, so the menubar partitions it as
    /// a tomorrow task rather than a leftover. No-op when the id is absent.
    func moveTodoToTomorrow(id: String, on date: Date) throws {
        let todayURL = DailyFile.url(in: folder, on: date, timezone: timezone)
        var todayDoc = readOrCreate(at: todayURL, on: date)
        guard let idx = todayDoc.tasks.firstIndex(where: { $0.id == id }) else { return }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: startOfDay(date))!

        let original = todayDoc.tasks[idx]
        let moved = Todo(id: original.id,
                         text: original.text,
                         createdAt: tomorrowStart,
                         done: original.done,
                         completedAt: original.completedAt,
                         dueDate: original.dueDate,
                         rolledTo: original.rolledTo,
                         sourceNote: original.sourceNote,
                         timeBlock: original.timeBlock,
                         calEventID: original.calEventID)

        // Remove from today and persist first so a partial failure never deletes
        // without landing.
        todayDoc.tasks.remove(at: idx)
        try todayDoc.serialize(timezone: timezone).write(to: todayURL, atomically: true, encoding: .utf8)

        // Append to tomorrow and persist.
        let tomorrowURL = DailyFile.url(in: folder, on: tomorrowStart, timezone: timezone)
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
