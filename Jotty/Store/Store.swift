import CryptoKit
import Foundation

/// Injectable file-coordination seam (roadmap 3.4 phase 2). The write funnel runs
/// its day-file read and write through this instead of touching disk directly, so
/// the coordination call can be faked in tests (record calls, simulate a hang) and
/// so the real one can be driven off the main actor with a timeout. A coordinated
/// read with no `.immediatelyAvailableMetadataOnly` already asks the file provider
/// to materialize a dataless iCloud file — Task 5's `UbiquitousStatusProbing` leans
/// on that instead of a manual download loop; Task 6 (conflict-sibling probe)
/// follows the same protocol-seam idiom (real impl + fake) as its own, separate type.
///
/// What coordination is FOR: correct interplay with `fileproviderd`/iCloud Drive —
/// a coordinated read waits out an in-flight sync write; a `.forReplacing` write is
/// fenced against the sync daemon's upload snapshot. It is advisory: it serializes
/// ONLY writers that also coordinate. Obsidian writes with plain `fs` and does not
/// coordinate, so this buys NOTHING against the Obsidian lost-update race — that
/// race is closed by the optimistic-concurrency funnel (phase 1), not by this seam.
protocol FileCoordinating: Sendable {
    /// Coordinated read. `accessor` receives the URL the coordinator hands back
    /// (normally the same URL) and does the actual byte read; whatever it throws
    /// (e.g. `CocoaError.fileReadNoSuchFile` for an absent file) propagates so the
    /// funnel keeps its absent-vs-unreadable discipline.
    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws
    /// Coordinated write. The funnel always passes `.forReplacing` (whole-file
    /// replace). `accessor` does the actual atomic write to the handed-back URL.
    func coordinateWriting(at url: URL,
                           options: NSFileCoordinator.WritingOptions,
                           _ accessor: (URL) throws -> Void) throws
}

/// Production seam: a real `NSFileCoordinator` per call (they are cheap and are not
/// meant to be reused across unrelated accesses). The accessor's own throw is
/// captured and re-raised after the coordinator returns, so an absent/unreadable
/// file surfaces the exact I/O error the funnel classifies on.
struct RealFileCoordinator: FileCoordinating {
    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws {
        var accessorError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { handedBack in
            do { try accessor(handedBack) } catch { accessorError = error }
        }
        if let accessorError { throw accessorError }
        if let coordError { throw coordError }
    }

    func coordinateWriting(at url: URL,
                           options: NSFileCoordinator.WritingOptions,
                           _ accessor: (URL) throws -> Void) throws {
        var accessorError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordError) { handedBack in
            do { try accessor(handedBack) } catch { accessorError = error }
        }
        if let accessorError { throw accessorError }
        if let coordError { throw coordError }
    }
}

/// Injectable dataless-file probe (roadmap 3.4 phase 2, Task 5). `readDay`
/// consults this BEFORE the coordinated read — purely to CLASSIFY a subsequent
/// read failure, not to gate or replace the read itself. `.notDownloaded` means
/// `url` is a ubiquitous (iCloud) placeholder whose bytes are not local yet; the
/// coordinated read that follows already asks the file provider to materialize
/// it (`RealFileCoordinator`'s `NSFileCoordinator.ReadingOptions` deliberately
/// omit `.immediatelyAvailableMetadataOnly`), so there is no separate
/// manual-download loop here. If that read still fails (download failed, or
/// offline), `readDay` must treat it as unreadable (phase 1 rule) and never as
/// absent — even when the underlying error happens to look ENOENT-shaped, which
/// a failed-download placeholder can. `nil` (a regular, non-ubiquitous file, the
/// probe call itself throwing, or the probe call timing out — see
/// `Store.probeDownloadingStatus`) short-circuits straight to the unchanged
/// fast path.
protocol UbiquitousStatusProbing: Sendable {
    func downloadingStatus(of url: URL) throws -> URLUbiquitousItemDownloadingStatus?
}

/// Production probe: the real `URLResourceValues.ubiquitousItemDownloadingStatus`
/// lookup. `nil` for a non-ubiquitous file (the resource value is simply absent
/// on a plain local file); throws only if the resource-values lookup itself
/// fails. `readDay` treats a probe failure the same as `nil` — a probe error is
/// not itself a classification signal, the read that follows still is.
struct RealUbiquitousStatusProbe: UbiquitousStatusProbing {
    func downloadingStatus(of url: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }
}

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
    /// Coordinated access ran off the main actor but the file coordinator did not
    /// return within the timeout — a stuck `fileproviderd` (iCloud). The operation
    /// did NOT complete and nothing was written; the caller surfaces a notice
    /// instead of the menubar beachballing on the wedged file provider. Treated as
    /// unreadable, never as an absent file.
    case coordinationTimedOut(URL)
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
        case .coordinationTimedOut(let url):
            return "Couldn't access \(url.lastPathComponent): iCloud (the file provider) didn't respond in time"
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

/// One-shot cancellation flag for a `runOffActorWithTimeout` envelope (roadmap
/// 3.4 phase 2, final review C1). The timeout path sets it; the enqueued closure
/// consults it immediately before any side effect so a closure ABANDONED on
/// timeout — one still parked inside a wedged `fileproviderd` when the caller has
/// already thrown `coordinationTimedOut` — lands NO write, sidecar, or
/// `markResolved` when the provider finally unwedges seconds/minutes later. A
/// plain thread-safe bool: the only mutation is the single `cancel()` the timeout
/// path makes, read by the closure. `@unchecked Sendable` (the `RecordingCoordinator`
/// lock idiom) so it can cross onto the coordination executor.
final class CoordinationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

final class Store {
    /// Thrown by the coordinated-write accessor's in-place stamp re-verify (C1)
    /// when the on-disk bytes changed between the funnel's pre-write stamp check
    /// and the actual coordinated write — an external writer that raced into the
    /// off-actor window (worst case: a write closure abandoned on timeout that
    /// unwedges long after the disk moved on). PRIVATE and never surfaced to a
    /// caller: `mutateDay` catches it and routes it straight back into its existing
    /// bounded stamp-conflict retry (`continue`), identical to the pre-write
    /// `currentStamp` mismatch path — so it needs no new public `StoreError` case.
    private struct StampConflict: Error {}

    let folder: URL
    let timezone: TimeZone

    /// File-coordination seam (roadmap 3.4 phase 2). The funnel runs its day-file
    /// read and write through this; default is a real `NSFileCoordinator`, tests
    /// inject a double. See `FileCoordinating` for what coordination does and does
    /// NOT buy (it is an iCloud/fileproviderd measure, not Obsidian protection).
    private let coordinator: FileCoordinating
    /// How long the funnel waits for a coordinated read/write before giving up and
    /// failing through the notice channel. The coordination itself runs on a
    /// background executor, so a wedged `fileproviderd` costs at most this long a
    /// stall — never a permanent main-actor beachball. Default is 2.0s (review
    /// finding, roadmap 3.4 phase 2): the original 5s default guaranteed a long
    /// VISIBLE beachball on any main-actor caller when the file provider wedges;
    /// 2.0s is still generous for a coordinated local read/write but caps the
    /// worst-case single-call stall to something a user reads as a hiccup, not a
    /// hang.
    ///
    /// Scan-loop compounding: a caller that loops over many day files (one
    /// `readDoc` per file) pays up to N × 2 × this timeout on a wedge — each
    /// `readDay` makes two independently coordinated-and-bounded provider calls
    /// (the dataless-file probe, then the coordinated read; review finding 1,
    /// roadmap 3.4 phase 2, closed the probe's own unbounded gap), so a stuck
    /// provider costs at most two timeouts per file, not one. This default is a
    /// PER-CALL bound, not a per-operation one. `CommandBarIndex.buildHistorical`'s
    /// day-file scan is unaffected: it always runs inside `Task.detached` off the
    /// main actor (`CommandBarModel.prepareForOpen`), so the compounding bound only
    /// delays a background merge, never the UI. `RolloverService.run` calls ITS scan
    /// loops synchronously from the main actor (`AppDelegate.runRolloverCatchUp`), so
    /// it reads through a separate, short-timeout `Store` (`RolloverService.scanStore`)
    /// instead of this default — bounding the worst-case main-actor stall without
    /// changing this seam's concurrency model.
    private let coordinationTimeout: TimeInterval
    /// Concurrent executor the coordinated I/O hops onto, off whatever (possibly
    /// main) actor called the funnel. Concurrent so one wedged coordination cannot
    /// serialize-block later operations. QoS is `.userInteractive` (review finding,
    /// roadmap 3.4 phase 2): the parked caller is often a `.userInteractive` main-
    /// actor UI action (menubar toggle/rename/…), and a semaphore wait does not
    /// priority-boost the queue it is waiting on — `.userInitiated` here would be a
    /// mild, avoidable priority inversion under system contention.
    private let coordinationQueue = DispatchQueue(
        label: "com.jotty.store.coordination", qos: .userInteractive, attributes: .concurrent)

    /// Dataless-file probe seam (roadmap 3.4 phase 2, Task 5). Default is the
    /// real `URLResourceValues.ubiquitousItemDownloadingStatus` lookup; tests
    /// inject a fake reporting `.notDownloaded` for an ordinary temp-dir file —
    /// real iCloud never appears in tests. See `UbiquitousStatusProbing`.
    private let probe: UbiquitousStatusProbing

    /// Conflict-sibling probe seam (roadmap 3.4 phase 2, Task 6). Default is
    /// the real `NSURLUbiquitousItemHasUnresolvedConflictsKey` +
    /// `NSFileVersion` wrapper; tests inject a fake reporting an unresolved
    /// conflict with fixed-content losing versions — real iCloud conflict
    /// siblings never appear in tests (no public `NSFileVersion` initializer).
    /// Its own, separate protocol-seam type from `UbiquitousStatusProbing` —
    /// see `ConflictSiblingProbing`.
    private let conflictProbe: ConflictSiblingProbing

    /// #4: invoked with the `.corrupt-*` sidecar URL right after a
    /// present-but-unparseable day file's raw bytes are quarantined (before its
    /// content is clobbered by a new write). The app layer hooks this to surface
    /// the recovery to the user through the PersistFailureNotice channel; nil in
    /// tests and headless contexts that don't observe it.
    var onCorruptQuarantine: ((URL) -> Void)?

    /// #6 (roadmap 3.4 phase 2, Task 6): invoked with the day-file URL when
    /// `checkForUnresolvedConflicts` found an unresolved iCloud sync conflict —
    /// mirrors `onCorruptQuarantine`'s shape exactly, but for iCloud's OWN
    /// conflict mechanism rather than a parse failure. Fires even when
    /// materializing a losing version's sidecar failed (that ONE version stays
    /// unresolved so the next check retries just it — see
    /// `checkForUnresolvedConflicts`'s per-version resolution ordering) — a
    /// detected conflict is itself always worth surfacing. nil in tests and
    /// headless contexts that don't observe it.
    ///
    /// `didSet` runs the initial probe the moment a non-nil listener is
    /// attached (review finding, roadmap 3.4 phase 2) — NOT unconditionally
    /// inside `init` as originally built. Every `Store()` construction used to
    /// pay the probe's off-actor-plus-timeout round trip regardless of whether
    /// anyone could ever observe the result: `RolloverService.scanStore` is
    /// reconstructed on every foreground activation on the MAIN actor and
    /// never attaches this listener, and `CommandBarIndex`'s per-build Store
    /// never does either. Moving the trigger here means those listenerless
    /// stores pay nothing, while the PRIMARY store still gets launch-time
    /// self-heal detection with no observable delay — `MenubarListModel`
    /// attaches its listener (`hookUnresolvedConflict`) immediately after
    /// construction, before its own first `reload()`. Setting the listener
    /// back to nil does not re-trigger anything (guarded below); reassigning
    /// a non-nil listener (e.g. `replace(store:...)`'s re-hook) re-runs the
    /// check against `Date()`, which is harmless — it is the same self-heal
    /// probe a fresh construction would have paid.
    var onUnresolvedConflict: ((URL) -> Void)? {
        didSet {
            guard onUnresolvedConflict != nil else { return }
            checkForUnresolvedConflicts()
        }
    }

    init(folder: URL, timezone: TimeZone = .current,
         coordinator: FileCoordinating = RealFileCoordinator(),
         coordinationTimeout: TimeInterval = 2.0,
         probe: UbiquitousStatusProbing = RealUbiquitousStatusProbe(),
         conflictProbe: ConflictSiblingProbing = RealConflictSiblingProbe()) {
        self.folder = folder
        self.timezone = timezone
        self.coordinator = coordinator
        self.coordinationTimeout = coordinationTimeout
        self.probe = probe
        self.conflictProbe = conflictProbe
        // Design Phase 2.3 (Task 6): the construction-time self-heal probe now
        // fires from `onUnresolvedConflict`'s `didSet` (review finding,
        // roadmap 3.4 phase 2) rather than unconditionally here — see that
        // property's doc for why. A caller that never attaches a listener
        // (a listenerless secondary store, e.g. `RolloverService.scanStore`)
        // pays nothing at construction.
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
            do {
                try persist(doc, to: url, quarantining: read.corruptRaw, expecting: read.stamp)
            } catch is StampConflict {
                // The coordinated write's in-accessor re-verify (C1) caught an
                // external writer that raced into the off-actor window AFTER the
                // pre-check above passed. Same treatment as that pre-check's own
                // mismatch: re-read and re-apply, bounded by `attempts`.
                continue
            }
            return
        }
        throw StoreError.conflictRetryExhausted(url)
    }

    /// Stamp of what is on disk RIGHT NOW — compared against the stamp captured
    /// at read time to detect an interleaved external write. Same absent-vs-
    /// unreadable discipline as `readDay`.
    ///
    /// Deliberately an UNCOORDINATED direct re-stat: it only runs after a
    /// coordinated `readDay` already succeeded for this url in the same attempt, so
    /// the bytes are local and cannot re-block on the file provider; the
    /// authoritative fence against the sync daemon is the coordinated `.forReplacing`
    /// write that follows. Coordinating it too would double the off-actor hop on the
    /// hot path for no correctness gain.
    private func currentStamp(at url: URL) throws -> DayStamp {
        do {
            return DayStamp(contentHash: SHA256.hash(data: try Data(contentsOf: url)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DayStamp(contentHash: nil)
        } catch {
            throw StoreError.dayFileUnreadable(url, underlying: error)
        }
    }

    /// Consults the dataless-file probe, off-actor and time-bounded through the
    /// same `runOffActorWithTimeout` envelope every other provider-touching call
    /// in this file uses (review finding 1, roadmap 3.4 phase 2). Without this,
    /// `probe.downloadingStatus(of:)` ran synchronously on the caller's (possibly
    /// main) actor with no bound at all — a wedged provider could hang the caller
    /// unboundedly, worst on the rollover scan loop (main-actor, up to 14 files),
    /// silently invalidating `coordinationTimeout`'s documented per-file bound.
    /// A timeout here collapses to `nil`, same as a probe throw (see
    /// `UbiquitousStatusProbing`): the coordinated read that follows still
    /// provides the real protection — it either times out too (unreadable) or
    /// hits ENOENT (absent) on its own terms.
    private func probeDownloadingStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        let probe = self.probe
        // A pure read has no side effect to gate — the cancellation token is
        // accepted (C1's uniform envelope signature) and ignored.
        return (try? runOffActorWithTimeout(url) { _ in try probe.downloadingStatus(of: url) })
            .flatMap { $0 }
    }

    /// Reads `url`'s bytes through the coordinator, off-actor and time-bounded.
    /// Propagates the accessor's own error (so `CocoaError.fileReadNoSuchFile` still
    /// means "absent" upstream) or `StoreError.coordinationTimedOut` on a wedged
    /// provider. Only the Sendable `coordinator` + `url` cross onto the executor.
    private func coordinatedReadData(at url: URL) throws -> Data {
        let coordinator = self.coordinator
        // A pure read has no side effect to gate — the cancellation token is
        // accepted (C1's uniform envelope signature) and ignored.
        return try runOffActorWithTimeout(url) { _ throws -> Data in
            var out = Data()
            try coordinator.coordinateReading(at: url) { handedBack in
                out = try Data(contentsOf: handedBack)
            }
            return out
        }
    }

    /// Writes `bytes` to `url` through the coordinator with `.forReplacing`,
    /// off-actor and time-bounded. `.atomic` = write-to-temp + rename (unchanged
    /// from phase 1); coordination fences that rename against the sync daemon.
    ///
    /// Two C1 guards fence the delayed-zombie clobber (a write closure abandoned
    /// on timeout that a wedged provider runs long after the caller gave up):
    ///  - the `cancellation` flag: a closure abandoned by the timeout path returns
    ///    without touching disk;
    ///  - an in-accessor stamp RE-VERIFY: `expected` is the stamp the funnel saw
    ///    before this write; immediately before the atomic write we re-hash the
    ///    on-disk bytes and, on any mismatch, throw `StampConflict` instead of
    ///    clobbering. This restores the µs-class TOCTOU window the off-actor hop
    ///    otherwise widened to the whole wedge duration. `mutateDay` routes the
    ///    throw back into its bounded stamp-conflict retry.
    private func coordinatedWrite(_ bytes: Data, to url: URL, expecting expected: DayStamp) throws {
        let coordinator = self.coordinator
        try runOffActorWithTimeout(url) { cancellation in
            // Abandoned-on-timeout closure: do nothing observable.
            guard !cancellation.isCancelled else { return }
            try coordinator.coordinateWriting(at: url, options: .forReplacing) { handedBack in
                guard !cancellation.isCancelled else { return }
                // Re-verify the stamp against what is on disk RIGHT NOW, inside the
                // coordinated fence — not the caller-side pre-check that ran before
                // the off-actor hop. A mismatch means an external writer landed in
                // the window; abort as a stamp conflict rather than clobber.
                guard try Self.onDiskStamp(at: handedBack) == expected else {
                    throw StampConflict()
                }
                try bytes.write(to: handedBack, options: .atomic)
            }
        }
    }

    /// Hash of the bytes on disk at `url` RIGHT NOW, for the coordinated-write
    /// re-verify (C1). Absent file → nil hash (matches `currentStamp`/`readDay`'s
    /// absent-vs-present discipline). Any OTHER read failure rethrows so the write
    /// aborts rather than silently proceeding on an unknowable disk state.
    private static func onDiskStamp(at url: URL) throws -> DayStamp {
        do {
            return DayStamp(contentHash: SHA256.hash(data: try Data(contentsOf: url)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DayStamp(contentHash: nil)
        }
    }

    /// Runs `work` on the concurrent coordination executor and blocks the caller on
    /// a semaphore until it finishes OR `coordinationTimeout` elapses. On timeout it
    /// throws `coordinationTimedOut` and abandons the (possibly permanently wedged)
    /// background work — so a stuck `fileproviderd` can hang a throwaway executor
    /// thread but NEVER the caller past the timeout. This is the Risk-4 off-actor +
    /// timeout structure: the potentially-never-returning `coordinate()` call
    /// executes on the background executor, not on whatever actor called the funnel.
    ///
    /// Cancellation (C1): the timeout path sets a `CoordinationCancellation` the
    /// enqueued `work` receives and consults before every side effect, so a closure
    /// abandoned here is INERT — an unwedging `fileproviderd` that finally runs it
    /// minutes later lands no stale bytes. Cancellation neutralizes side effects but
    /// does NOT unpark the parked thread: the abandoned closure still occupies a
    /// throwaway executor thread until the underlying provider call returns (the
    /// accumulation cost `coordinationQueue`'s concurrency already absorbs), it
    /// merely does nothing observable when it does.
    private func runOffActorWithTimeout<T: Sendable>(
        _ url: URL, _ work: @escaping @Sendable (CoordinationCancellation) throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        let cancellation = CoordinationCancellation()
        // Heap-boxed by capture; the escaping closure keeps it alive even if we
        // return (throw) first. `wait()` returning establishes happens-before with
        // the `signal()` that follows the store, so the read below sees the write.
        nonisolated(unsafe) var result: Result<T, Error>?
        coordinationQueue.async {
            result = Result(catching: { try work(cancellation) })
            sem.signal()
        }
        if sem.wait(timeout: .now() + coordinationTimeout) == .timedOut {
            cancellation.cancel()
            throw StoreError.coordinationTimedOut(url)
        }
        return try result!.get()
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
        // Dataless-file probe (roadmap 3.4 phase 2, Task 5) — consulted BEFORE
        // the read, purely to classify a failure below. A probe failure is not
        // itself meaningful, so it collapses to `nil` (unchanged fast path);
        // `readDay` never gates the read on this, it only changes what a
        // subsequent read failure MEANS.
        let isDatalessNotDownloaded = probeDownloadingStatus(of: url) == .notDownloaded

        let data: Data
        do {
            data = try coordinatedReadData(at: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !isDatalessNotDownloaded {
            // Genuinely absent: fresh doc, nothing to quarantine. (A coordinated
            // read still invokes the accessor for a missing file, so ENOENT
            // reaches us here exactly as an uncoordinated read did.) Gated on
            // `!isDatalessNotDownloaded`: a dataless file whose download failed
            // must never take this branch, even when the underlying error looks
            // ENOENT-shaped — it falls through to `dayFileUnreadable` below.
            //
            // Accepted, undocumented-until-now race: the probe and the read are
            // two separate provider round-trips, not one atomic operation. A file
            // that is genuinely deleted elsewhere BETWEEN the (stale) probe
            // reporting `.notDownloaded` and the read landing on ENOENT takes the
            // `dayFileUnreadable` branch below instead of this one — a real
            // absence misclassified as unreadable. This fails SAFE (throws, no
            // clobber of a file that no longer exists) and self-heals on the next
            // read once the stale `.notDownloaded` stops being reported, so it is
            // left as-is rather than papered over with a second probe call that
            // would just narrow, not close, the same window.
            return DayRead(doc: MarkdownDoc(date: startOfDay(date)), corruptRaw: nil,
                           stamp: DayStamp(contentHash: nil))
        } catch let error as StoreError {
            // A coordination timeout is already a notice-channel failure — surface
            // it as-is; do NOT rewrap it as `dayFileUnreadable` (it is not absent
            // either, so no clobber can follow).
            throw error
        } catch {
            // Present but unreadable at the I/O layer (permissions, evicted
            // iCloud file offline/download-failed). NOT absent — writing a fresh
            // doc here would clobber the whole day (design note 2026-07-12, phase 1).
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
    private func persist(_ doc: MarkdownDoc, to url: URL, quarantining corruptRaw: Data?,
                         expecting stamp: DayStamp) throws {
        if let corruptRaw {
            quarantine(corruptRaw, of: url)
        }
        // Coordinated, `.forReplacing` (whole-file replace), off-actor with a
        // timeout. `Data(_.utf8)` + `.atomic` reproduces the previous
        // `String.write(atomically:encoding:.utf8)` byte-for-byte (write-to-temp +
        // rename); coordination only fences the rename against the sync daemon.
        // `stamp` is re-verified inside the coordinated fence (C1).
        let bytes = Data(doc.serialize(timezone: timezone).utf8)
        try coordinatedWrite(bytes, to: url, expecting: stamp)
    }

    /// Copies `raw` to a `<name>.corrupt-<timestamp>.md` sidecar next to `url`
    /// via `writeSidecar` (best-effort — a sidecar-write failure is logged,
    /// never thrown, so losing the corrupt copy can't also block the user's
    /// new capture). On success the sidecar URL is surfaced via
    /// `onCorruptQuarantine`.
    private func quarantine(_ raw: Data, of url: URL) {
        do {
            let candidate = try Store.writeSidecar(raw, of: url, in: folder, kind: "corrupt", timezone: timezone)
            onCorruptQuarantine?(candidate)
        } catch {
            NSLog("[Jotty] failed to quarantine corrupt day file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Probes `date`'s file (default `Date()`, i.e. "today") for an unresolved
    /// iCloud sync conflict (roadmap 3.4 phase 2, design Phase 2.3) and, if
    /// found, materializes each losing `NSFileVersion` as a
    /// `.conflict-<stamp>.md` sidecar (mirrors `quarantine(_:of:)`) and marks
    /// the conflict versions resolved so the file provider can clean them up.
    ///
    /// Called once when `onUnresolvedConflict` is first attached (its `didSet`
    /// — today's file, using this method's `Date()` default; see that
    /// property's doc) and once per caller-driven "reload": Store has no
    /// reload concept or injected clock of its own, so `MenubarListModel.
    /// reload()` is the one that calls this, passing its OWN `now()` snapshot
    /// rather than letting Store call `Date()` on every check — that keeps
    /// "today" the SAME instant the caller's own snapshot uses (a
    /// test-injected clock stays authoritative) while `date`'s default still
    /// makes sense for the listener-attach call, which has no such snapshot
    /// to share.
    ///
    /// Resolution ordering (review finding, roadmap 3.4 phase 2 — PER-VERSION,
    /// not whole-batch): each losing version is marked resolved independently,
    /// immediately after ITS OWN sidecar is confirmed on disk. A version whose
    /// materialization or sidecar write fails is simply left unresolved and
    /// tried again on the next check; it does NOT block its siblings from
    /// resolving. The earlier whole-batch design (resolve nothing unless
    /// EVERY version's sidecar landed) made a persistent single-version
    /// failure re-materialize every ALREADY-SUCCEEDED sibling on every
    /// subsequent reload — each retry re-runs `writeSidecar`'s wall-clock
    /// stamp, so a version that already has a sidecar would keep growing new,
    /// never-cleaned-up ones forever. Per-version resolution means a
    /// succeeded version's provider-side cleanup (`markResolved`) proceeds
    /// right away, so a real `NSFileVersion` enumeration on the next check no
    /// longer surfaces it at all — nothing left to re-materialize. The banner
    /// fires regardless of any per-version failure: a detected conflict is
    /// itself always worth surfacing, independent of how cleanly it was
    /// archived.
    ///
    /// Off-actor + timeout, ONE envelope wraps the whole probe + enumerate +
    /// materialize + resolve sequence (review lesson, Task 5: no un-timeboxed
    /// provider calls, anywhere) — day files are a few KB and conflict
    /// siblings are rare and few, so one bounded round trip for the whole
    /// sequence is deliberately simpler than a separate envelope per losing
    /// version. A probe failure, a versions-enumeration failure, or a timeout
    /// on the whole sequence collapses to "no conflict detected" — silent,
    /// matching `probeDownloadingStatus`'s fail-safe discipline: this is
    /// best-effort awareness, never a gate on the read/write funnel.
    func checkForUnresolvedConflicts(on date: Date = Date()) {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        let conflictProbe = self.conflictProbe
        let folder = self.folder
        let timezone = self.timezone
        let found = (try? runOffActorWithTimeout(url) { cancellation throws -> Bool in
            guard try conflictProbe.hasUnresolvedConflicts(at: url) else { return false }
            // A conflict WAS found — everything below is best-effort archival;
            // its success or failure must never un-set this `true` result.
            // Abandoned-on-timeout closure (C1/M3): skip the archival side effects
            // (sidecar write + markResolved) entirely — a zombie must not materialize
            // sidecars or mutate iCloud's conflict list minutes after the caller,
            // whose `found` is already `false` (the envelope threw), moved on.
            guard !cancellation.isCancelled else { return true }
            if let versions = try? conflictProbe.unresolvedConflictVersions(at: url), !versions.isEmpty {
                for version in versions {
                    guard !cancellation.isCancelled else { break }
                    do {
                        // Per-version resolve (review finding, roadmap 3.4 phase
                        // 2): materialize + resolve THIS version alone. A
                        // sibling's failure never blocks this one, and this
                        // one's own failure never blocks its siblings — each
                        // version's fate is independent.
                        let data = try version.materializedContents()
                        _ = try Store.writeSidecar(data, of: url, in: folder, kind: "conflict", timezone: timezone)
                        // Best-effort: a resolve failure leaves iCloud's own
                        // conflict list untouched (the sidecar copy already
                        // safely landed either way) rather than throwing and
                        // losing the `true` result above.
                        try? version.markResolved()
                    } catch {
                        // Left unresolved: retried on the next check (the next
                        // reload), same as before — but ONLY this version, not
                        // every version in the batch.
                    }
                }
            }
            return true
        }) ?? false

        if found {
            onUnresolvedConflict?(url)
        }
    }

    /// Copies `raw` to a `<name>.<kind>-<timestamp>[-N].md` sidecar next to
    /// `url` inside `folder`, NEVER overwriting an existing sidecar: a
    /// millisecond-precision stamp plus a counter suffix guarantee uniqueness
    /// across rapid successive sidecar writes for the same day file. Shared by
    /// the `.corrupt-*` quarantine idiom (#4) and the `.conflict-*` iCloud
    /// sidecar idiom (Task 6) — one naming routine so the two sidecar families
    /// can never diverge in shape, and both are excluded from day-file parsing
    /// the same way (`DailyFile`'s strict `yyyy-MM-dd` formatter simply fails
    /// to parse either suffix). Throws on a write failure — `quarantine`
    /// swallows it (best-effort, unchanged #4 contract);
    /// `checkForUnresolvedConflicts` does NOT swallow it, since a failed
    /// sidecar write there must block marking the conflict resolved.
    private static func writeSidecar(_ raw: Data, of url: URL, in folder: URL,
                                     kind: String, timezone: TimeZone) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent   // e.g. "2026-05-08"
        let stamp = Self.sidecarStamp(Date(), timezone: timezone)
        var candidate = folder.appendingPathComponent("\(base).\(kind)-\(stamp).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base).\(kind)-\(stamp)-\(counter).md")
            counter += 1
        }
        // Raw bytes, verbatim: non-UTF8 corrupt-quarantine content must survive
        // un-transcoded; conflict-sidecar content is whatever the losing
        // NSFileVersion held.
        try raw.write(to: candidate, options: .atomic)
        return candidate
    }

    /// Filename-safe ISO8601 basic timestamp (`yyyyMMdd'T'HHmmssSSS`) for
    /// `.corrupt-*`/`.conflict-*` sidecars. Colons are deliberately avoided —
    /// the Cocoa file layer treats `:` as a path separator. Pinned
    /// POSIX/Gregorian like every other machine key the app writes (DailyFile
    /// discipline).
    private static func sidecarStamp(_ date: Date, timezone: TimeZone) -> String {
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
