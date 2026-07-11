import Foundation

final class Store {
    let folder: URL
    let timezone: TimeZone

    /// #4: invoked with the `.corrupt-*` sidecar URL right after a
    /// present-but-unparseable day file's raw bytes are quarantined (before its
    /// content is clobbered by a new write). The app layer hooks this to surface
    /// the recovery to the user through the PersistFailureNotice channel; nil in
    /// tests and headless contexts that don't observe it.
    var onCorruptQuarantine: ((URL) -> Void)?

    init(folder: URL, timezone: TimeZone = .current) {
        self.folder = folder
        self.timezone = timezone
    }

    func appendCapture(noteText: String, noteId: String?, tasks: [Todo], at time: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = DailyFile.url(in: folder, on: time, timezone: timezone)
        let read = readDay(at: url, on: time)
        var doc = read.doc
        for task in tasks { doc.appendTodo(task) }
        if !noteText.isEmpty, let noteId {
            doc.appendNote(text: noteText, at: time, id: noteId)
        }
        try persist(doc, to: url, quarantining: read.corruptRaw)
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
        let cal = DailyFile.calendar(timezone: timezone)
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
        // Re-anchor a time block to TOMORROW's same wall-clock slot (DST-correct via
        // the pinned calendar). This used to happen IMPLICITLY through the day-dropping
        // `time:` token re-parsing on tomorrow's file; the token is day-qualified now,
        // so the move states its intent explicitly.
        if let tb = moved.timeBlock {
            moved.timeBlock = Self.reanchor(tb, ontoDay: tomorrowStart, calendar: cal)
        }

        let tomorrowURL = DailyFile.url(in: folder, on: tomorrowStart, timezone: timezone)

        // Same-file move (source day IS tomorrow): replace the element in the single doc so
        // the remove + append round-trip through one consistent document instead of racing
        // two reads/writes against the same path (and never duplicating the task).
        if sourceURL == tomorrowURL {
            sourceDoc.tasks[idx] = moved
            try sourceDoc.serialize(timezone: timezone).write(to: sourceURL, atomically: true, encoding: .utf8)
            return
        }

        // Land on tomorrow FIRST, then remove from the source (quarantine tomorrow's
        // file first if it was present-but-unparseable — this is the one unconditional
        // overwrite in the move; the source read above early-returns when its file is
        // corrupt). The old remove-first order DELETED the task outright when the
        // tomorrow-write failed mid-move (disk full, kill between the two writes) —
        // the exact loss the T-6-08 invariant forbids. With land-first, a mid-move
        // failure leaves the task visible in both files instead: benign, and
        // self-healing — the rollover pass skips re-collecting an id already present
        // on the target day.
        let tomorrowRead = readDay(at: tomorrowURL, on: tomorrowStart)
        var tomorrowDoc = tomorrowRead.doc
        tomorrowDoc.appendTodo(moved)
        try persist(tomorrowDoc, to: tomorrowURL, quarantining: tomorrowRead.corruptRaw)

        sourceDoc.tasks.remove(at: idx)
        try sourceDoc.serialize(timezone: timezone).write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    func replaceTasks(_ tasks: [Todo], on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        let read = readDay(at: url, on: date)
        var doc = read.doc
        doc.tasks = tasks
        try persist(doc, to: url, quarantining: read.corruptRaw)
    }

    func readDoc(on date: Date) throws -> MarkdownDoc {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        return readOrCreate(at: url, on: date)
    }

    /// Ensures the day file for `date` exists on disk, creating an empty scaffold
    /// when absent (#12) so ⌘K "Open Today's File" has something to open before the
    /// day's first capture (it previously no-op'd). A present, VALID file is left
    /// byte-identical (no rewrite); a present-but-unparseable file is left in place
    /// untouched (never clobbered — quarantine only happens on a real write).
    /// Returns the file URL either way.
    @discardableResult
    func ensureDayFile(on date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try MarkdownDoc(date: startOfDay(date))
            .serialize(timezone: timezone)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Every day that has a markdown file in the folder, parsed from the
    /// `yyyy-MM-dd.md` DailyFile filenames (Phase 8 CR-01). Lets callers reach
    /// ANY day's doc without a bounded lookback window — the recurrence pass
    /// scans these for templates (which persist on their origin day forever),
    /// and the recurrence UI resolves an instance's template through them.
    /// Non-matching filenames are skipped; a missing/unreadable folder yields
    /// an empty array. Parses with the SHARED POSIX/Gregorian day formatter
    /// (`DailyFile.dayFormatter`) — the same builder that NAMED the files — so
    /// the write/parse pair can never drift (iteration-3 WR: an unpinned
    /// `DailyFile.url` under a Thai Buddhist region wrote era-shifted names
    /// this parse could not map back, silently killing recurrence). Filenames
    /// that do not parse under the pinned formatter are skipped defensively,
    /// never a crash. Known limitation: an era-shifted legacy filename written
    /// by a pre-pin build under a non-Gregorian region (e.g. `2569-07-03.md`)
    /// still parses — as Gregorian year 2569 — and surfaces as a far-future
    /// day; the template scan's `< today` filter ignores it, and such files
    /// are not migrated.
    func allDayDates() -> [Date] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        let f = DailyFile.dayFormatter(timezone: timezone)
        return names.compactMap { name in
            guard name.hasSuffix(".md") else { return nil }
            return f.date(from: String(name.dropLast(3)))
        }
    }

    /// Outcome of reading a day file: the doc to work with, plus the raw on-disk
    /// bytes to quarantine IFF the file existed but could not be parsed (#4).
    private struct DayRead {
        var doc: MarkdownDoc
        /// The file's raw bytes when it was present but failed to decode or parse;
        /// nil for the happy paths (absent file, or a file that parsed cleanly).
        /// Raw `Data` (not `String`) so a non-UTF8 file is preserved byte-for-byte.
        let corruptRaw: Data?
    }

    /// Reads the day file at `url`, distinguishing the states #4 requires:
    /// absent (fresh empty doc, nothing to quarantine), parsed-ok (the parsed doc,
    /// nothing to quarantine), and present-but-unusable (a fresh empty doc PLUS
    /// the raw bytes so a writer can quarantine them before clobbering — a day file
    /// broken by an external editor or sync conflict is no longer silently
    /// destroyed on the next capture).
    ///
    /// "Unusable" covers BOTH failure layers: bytes that don't decode as UTF-8
    /// (an editor/sync client re-encoded the file as UTF-16/Latin-1 — the old
    /// single-step `String(contentsOf:encoding:)` collapsed that into "absent",
    /// so the day's full contents were clobbered with no sidecar) and bytes that
    /// decode but don't parse as a day doc.
    private func readDay(at url: URL, on date: Date) -> DayRead {
        guard let data = try? Data(contentsOf: url) else {
            // Genuinely absent (or unreadable at the I/O layer): fresh doc.
            return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: nil)
        }
        guard let existing = String(data: data, encoding: .utf8) else {
            // Present but not UTF-8: corrupt, NOT absent — quarantine before any write.
            return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: data)
        }
        if let parsed = try? MarkdownDoc.parse(existing, timezone: timezone) {
            return DayRead(doc: parsed, corruptRaw: nil)
        }
        return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: data)
    }

    /// Thin doc-only reader for the guarded ops (toggle/delete/edit/rename/…): they
    /// early-return when the id is absent, so an unparseable file yields an empty
    /// doc, no matching id, and NO write — the corrupt file is left untouched
    /// rather than clobbered, so those paths never need quarantine.
    private func readOrCreate(at url: URL, on date: Date) -> MarkdownDoc {
        readDay(at: url, on: date).doc
    }

    /// Serializes `doc` to `url`. When `corruptRaw` is non-nil (the file was
    /// present but unparseable), first copies those original bytes to a
    /// `.corrupt-*` sidecar, THEN writes the new content — the broken file is
    /// preserved AND the new capture still lands. The happy path (corruptRaw nil)
    /// is byte-identical to a plain `write(atomically:)`.
    private func persist(_ doc: MarkdownDoc, to url: URL, quarantining corruptRaw: Data?) throws {
        if let corruptRaw {
            quarantine(corruptRaw, of: url)
        }
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Copies `raw` to a `<name>.corrupt-<timestamp>.md` sidecar next to `url`,
    /// NEVER overwriting an existing sidecar: a millisecond-precision stamp plus a
    /// counter suffix guarantee uniqueness across rapid successive quarantines of
    /// the same day. Best-effort — a sidecar-write failure is logged, never thrown,
    /// so losing the corrupt copy can't also block the user's new capture. On
    /// success the sidecar URL is surfaced via `onCorruptQuarantine`.
    private func quarantine(_ raw: Data, of url: URL) {
        let base = url.deletingPathExtension().lastPathComponent   // e.g. "2026-05-08"
        let stamp = Self.corruptStamp(Date(), timezone: timezone)
        var candidate = folder.appendingPathComponent("\(base).corrupt-\(stamp).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base).corrupt-\(stamp)-\(counter).md")
            counter += 1
        }
        do {
            // Raw bytes, verbatim: a non-UTF8 original must survive un-transcoded.
            try raw.write(to: candidate, options: .atomic)
            onCorruptQuarantine?(candidate)
        } catch {
            NSLog("[Jotty] failed to quarantine corrupt day file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Filename-safe ISO8601 basic timestamp (`yyyyMMdd'T'HHmmssSSS`) for corrupt
    /// sidecars. Colons are deliberately avoided — the Cocoa file layer treats `:`
    /// as a path separator. Pinned POSIX/Gregorian like every other machine key the
    /// app writes (DailyFile discipline).
    private static func corruptStamp(_ date: Date, timezone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = DailyFile.calendar(timezone: timezone)
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS"
        f.timeZone = timezone
        return f.string(from: date)
    }

    private func startOfDay(_ d: Date) -> Date {
        DailyFile.calendar(timezone: timezone).startOfDay(for: d)
    }

    /// Rebuilds `block` on `day` keeping the same wall-clock start/end (the
    /// move-to-tomorrow semantics: a 14:00–14:30 slot stays 14:00–14:30 on the new
    /// day, DST-correct because the components are resolved through the pinned
    /// calendar). An end at/before the start crossed midnight — roll it one day
    /// forward, mirroring the `time:` token parse (I3).
    private static func reanchor(_ block: TimeBlock, ontoDay day: Date,
                                 calendar cal: Calendar) -> TimeBlock {
        func place(_ instant: Date) -> Date? {
            let hm = cal.dateComponents([.hour, .minute], from: instant)
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hm.hour
            comps.minute = hm.minute
            return cal.date(from: comps)
        }
        guard let start = place(block.start), var end = place(block.end) else { return block }
        if end < start {
            end = cal.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return TimeBlock(start: start, end: end)
    }
}
