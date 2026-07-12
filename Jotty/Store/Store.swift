import CryptoKit
import Foundation

/// Errors surfaced by day-file operations (roadmap 3.4 phase 1). Distinct from
/// the quarantine path: these mean the operation did NOT complete and nothing
/// was written — callers surface them through the failure-notice channel.
enum StoreError: Error {
    /// The day file exists (or its state is unknowable) but could not be read at
    /// the I/O layer — permissions, an evicted (dataless) iCloud file while
    /// offline, etc. Never treated as "absent": a fresh doc written over an
    /// unreadable file is whole-day data loss.
    case dayFileUnreadable(URL, underlying: Error)
    /// The optimistic-concurrency funnel lost the race to an external writer on
    /// every bounded attempt. Nothing was written; the caller surfaces a notice.
    case conflictRetryExhausted(URL)
}

extension StoreError: LocalizedError {
    /// Human-readable messages: these currently reach the user only via NSLog
    /// (the Tier-1 1.4 actionFailureNotice channel is not built yet — when it
    /// lands, these strings are what it shows). Without this conformance the
    /// logs printed "(Jotty.StoreError error 1.)".
    var errorDescription: String? {
        switch self {
        case .dayFileUnreadable(let url, let underlying):
            return "Couldn't read \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .conflictRetryExhausted(let url):
            return "Couldn't save \(url.lastPathComponent): another app kept changing it (conflict retries exhausted)"
        }
    }
}

/// Opaque token capturing what was on disk when a day file was read — the
/// optimistic-concurrency stamp (design note 2026-07-12, phase 1). Hash of the
/// RAW on-disk bytes (not the parsed doc): any external byte change, even a
/// no-op re-save with different line endings, must be treated as a conflict so
/// the retry path re-reads before writing. `nil` hash = the file was absent.
/// Day files are a few KB, so re-hashing is cheap; no mtime fast-path needed.
struct DayStamp: Equatable {
    let contentHash: SHA256Digest?
}

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
        try mutateDay(on: time) { doc in
            for task in tasks { doc.appendTodo(task) }
            if !noteText.isEmpty, let noteId {
                doc.appendNote(text: noteText, at: time, id: noteId)
            }
            return true
        }
    }

    func appendNote(text: String, at time: Date, id: String) throws {
        try appendCapture(noteText: text, noteId: id, tasks: [], at: time)
    }

    /// Toggle is STATE-SETTING under retry, not state-flipping: the user's intent
    /// ("mark done" / "mark undone") is captured from the FIRST read and re-asserted
    /// on conflict retries — a racing external writer that already completed the
    /// task must not be un-done by our retry re-flipping it (design note
    /// 2026-07-12, adversarial-review item 2).
    func toggleTodo(id: String, on date: Date) throws {
        var desired: Bool?
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            let target = desired ?? !doc.tasks[idx].done
            desired = target
            guard doc.tasks[idx].done != target else { return false }
            doc.tasks[idx].done = target
            doc.tasks[idx].completedAt = target ? Date() : nil
            return true
        }
    }

    /// Removes the task with `id` from the day's markdown (SC3). No-op when the id
    /// is absent. Disk is the source of truth; the matching calendar event (if any)
    /// is handled best-effort by the caller, never here.
    func deleteTodo(id: String, on date: Date) throws {
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks.remove(at: idx)
            return true
        }
    }

    /// Sets the task's `timeBlock` and re-serializes (SC3 edit-time). No-op when the
    /// id is absent. The `cal_event:` link is preserved; the linked event is updated
    /// best-effort by the caller, never here.
    func updateTodoTime(id: String, timeBlock: TimeBlock, on date: Date) throws {
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks[idx].timeBlock = timeBlock
            return true
        }
    }

    /// Sets the task's `snooze` date and re-serializes (Phase 8 SC3 / CALX-03).
    /// Snooze affects VISIBILITY only (the menubar filter hides the task until the
    /// date), never storage location — the task stays in its day file, distinct
    /// from move-to-tomorrow which relocates. No-op when the id is absent,
    /// mirroring `updateTodoTime`. The index-mutate IS a whole-value copy-mutate
    /// (a Swift array element assign preserves every other field — never rebuild
    /// via `Todo(id:…)`, Phase 7 CR-01).
    func snoozeTodo(id: String, to snoozeDate: Date, on date: Date) throws {
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks[idx].snooze = snoozeDate
            return true
        }
    }

    /// Sets (or, with `nil`, clears — the "None" Repeat choice) the task's
    /// recurrence rule and re-serializes (Phase 8 SC2 UI / CALX-02). No-op when
    /// the id is absent, mirroring `updateTodoTime`. Same whole-value copy-mutate
    /// as `snoozeTodo` (Phase 7 CR-01: every other token survives).
    func setTodoRecurrence(id: String, to recurrence: Recurrence?, on date: Date) throws {
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks[idx].recur = recurrence
            return true
        }
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
        try mutateDay(on: date) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks[idx].text = trimmed
            return true
        }
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
        let sourceDoc = try readOrCreate(at: sourceURL, on: sourceDate)
        guard let src = sourceDoc.tasks.first(where: { $0.id == id }) else { return }

        // Copy the WHOLE value so every field (id/text/tokens, and the Phase-7
        // source/sourceURL provenance, plus any future field) carries across the
        // move untouched — only createdAt is advanced. A field-by-field rebuild
        // here silently dropped source/sourceURL once (Phase 7 CR-01); the
        // copy-mutate pattern can never regress as fields are added.
        var moved = src
        moved.createdAt = tomorrowStart
        // Re-anchor a time block to TOMORROW's same wall-clock slot (DST-correct via
        // the pinned calendar). This used to happen IMPLICITLY through the day-dropping
        // `time:` token re-parsing on tomorrow's file; the token is day-qualified now,
        // so the move states its intent explicitly.
        if let tb = moved.timeBlock {
            moved.timeBlock = Self.reanchor(tb, ontoDay: tomorrowStart, calendar: cal)
        }

        let tomorrowURL = DailyFile.url(in: folder, on: tomorrowStart, timezone: timezone)

        // Same-file move (source day IS tomorrow): replace the element in the single
        // funnel call so remove + append round-trip through one consistent document
        // (never duplicating the task); a conflict retry re-finds the id fresh.
        if sourceURL == tomorrowURL {
            try mutateDay(on: sourceDate) { doc in
                guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
                doc.tasks[idx] = moved
                return true
            }
            return
        }

        // Land on tomorrow FIRST, then remove from the source. The old remove-first
        // order DELETED the task outright when the tomorrow-write failed mid-move —
        // the exact loss the T-6-08 invariant forbids. With land-first, a mid-move
        // failure leaves the task visible in both files instead: benign, and
        // self-healing — the rollover pass skips re-collecting an id already present
        // on the target day. The id-guard below makes the landing idempotent the
        // same way (a re-driven move after a mid-failure won't duplicate), and a
        // funnel conflict retry re-checks it against a fresh read.
        try mutateDay(on: tomorrowStart) { doc in
            guard !doc.tasks.contains(where: { $0.id == id }) else { return false }
            doc.appendTodo(moved)
            return true
        }

        var removedFromSource = false
        try mutateDay(on: sourceDate) { doc in
            guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
            doc.tasks.remove(at: idx)
            removedFromSource = true
            return true
        }

        // Compensation (adversarial-review finding 4): if the source line vanished
        // between our pre-read and the removal — an EXTERNAL delete won the race —
        // the landing above just resurrected a task the user deleted. Take the
        // landed copy back off tomorrow so the external delete wins. (A re-driven
        // move after a mid-failure is unaffected: its source removal succeeds.)
        if !removedFromSource {
            try mutateDay(on: tomorrowStart) { doc in
                guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return false }
                doc.tasks.remove(at: idx)
                return true
            }
        }
    }

    func readDoc(on date: Date) throws -> MarkdownDoc {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        return try readOrCreate(at: url, on: date)
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

    /// Test-only seam: fired inside `mutateDay` after the transform runs but
    /// BEFORE the pre-write stamp verification — the exact window an external
    /// writer races into. Lets tests inject a concurrent write through public
    /// ops (toggle/rename/…) whose transforms they cannot reach. Always nil in
    /// production; carries no behavior.
    var onBeforeWriteForTesting: (() -> Void)?

    /// THE single write funnel (roadmap 3.4 phase 1): every day-file mutation is
    /// read → transform → verify-stamp → write, with a bounded retry when an
    /// external writer (Obsidian, sync daemon) changed the bytes between our read
    /// and our write. On retry the transform re-runs against a FRESH read, so a
    /// targeted mutation (one task id, one append) re-applies exactly and the
    /// external edit to every other line survives — re-apply IS the merge.
    ///
    /// `transform` returns false to decline (no write, file byte-identical —
    /// the renameTodo empty-rename contract, funnel-wide). Per-op semantics
    /// (id-absent no-op, quarantine-before-clobber) live in the transforms and
    /// `persist` unchanged. The residual TOCTOU window between the stamp check
    /// and the atomic rename is microseconds and accepted by design — true
    /// elimination needs a lock file every writer honors, and Obsidian never will.
    func mutateDay(on date: Date, attempts: Int = 3,
                   _ transform: (inout MarkdownDoc) -> Bool) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        for _ in 0..<attempts {
            let read = try readDay(at: url, on: date)
            var doc = read.doc
            guard transform(&doc) else { return }
            onBeforeWriteForTesting?()
            guard try currentStamp(at: url) == read.stamp else { continue }
            // Folder creation sits on the WRITE path only: a declining transform
            // (or a pure read) must not materialize the storage folder as a side
            // effect (adversarial-review nit 5).
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try persist(doc, to: url, quarantining: read.corruptRaw)
            return
        }
        throw StoreError.conflictRetryExhausted(url)
    }

    /// Stamp of what is on disk RIGHT NOW — compared against the stamp captured
    /// at read time to detect an interleaved external write. Same absent-vs-
    /// unreadable discipline as `readDay`.
    private func currentStamp(at url: URL) throws -> DayStamp {
        do {
            return DayStamp(contentHash: SHA256.hash(data: try Data(contentsOf: url)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DayStamp(contentHash: nil)
        } catch {
            throw StoreError.dayFileUnreadable(url, underlying: error)
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
        /// What was on disk at read time — verified again immediately before the
        /// funnel writes (optimistic concurrency, roadmap 3.4 phase 1).
        let stamp: DayStamp
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
    private func readDay(at url: URL, on date: Date) throws -> DayRead {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Genuinely absent: fresh doc, nothing to quarantine.
            return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: nil,
                           stamp: DayStamp(contentHash: nil))
        } catch {
            // Present but unreadable at the I/O layer (permissions, evicted
            // iCloud file offline). NOT absent — writing a fresh doc here would
            // clobber the whole day (design note 2026-07-12, phase 1).
            throw StoreError.dayFileUnreadable(url, underlying: error)
        }
        let stamp = DayStamp(contentHash: SHA256.hash(data: data))
        guard let existing = String(data: data, encoding: .utf8) else {
            // Present but not UTF-8: corrupt, NOT absent — quarantine before any write.
            return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: data, stamp: stamp)
        }
        if let parsed = try? MarkdownDoc.parse(existing, timezone: timezone) {
            return DayRead(doc: parsed, corruptRaw: nil, stamp: stamp)
        }
        return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: data, stamp: stamp)
    }

    /// Thin doc-only reader for the guarded ops (toggle/delete/edit/rename/…): they
    /// early-return when the id is absent, so an unparseable file yields an empty
    /// doc, no matching id, and NO write — the corrupt file is left untouched
    /// rather than clobbered, so those paths never need quarantine.
    private func readOrCreate(at url: URL, on date: Date) throws -> MarkdownDoc {
        try readDay(at: url, on: date).doc
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
