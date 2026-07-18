import XCTest
@testable import Jotty

/// Roadmap 3.4 phase 1 — sync-safety hardening. Design note:
/// brain/projects/jotty/2026-07-12-sync-safety-design.md
final class StoreSyncSafetyTests: XCTestCase {
    var folder: URL!
    var store: Store!
    let tz = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = Store(folder: folder, timezone: tz)
    }

    override func tearDown() {
        // Restore permissions so removeItem can clean up chmod-000 fixtures.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names {
                let p = folder.appendingPathComponent(name).path
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p)
            }
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeDate(_ y: Int, _ mo: Int, _ d: Int, h: Int, m: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = m
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: comps)!
    }

    // MARK: - Absent vs unreadable (the evicted-iCloud-file clobber, design §Phase 1)

    /// An I/O-layer read failure (permissions blip, dataless iCloud file offline)
    /// must FAIL the operation — not masquerade as an absent file whose next write
    /// clobbers the whole day with a fresh doc.
    func testAppendToUnreadableDayFileThrowsAndLeavesFileUntouched() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "precious existing content", at: date, id: "n_001")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let originalBytes = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(
            try store.appendNote(text: "new capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_002")
        ) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable, got \(error)")
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "unreadable day file must never be overwritten")
    }

    /// A genuinely missing file keeps today's behavior: fresh doc, capture lands.
    func testAppendToAbsentDayFileStillCreatesFreshDoc() throws {
        let date = makeDate(2026, 5, 9, h: 9, m: 0)
        try store.appendNote(text: "first of the day", at: date, id: "n_003")
        let body = try String(contentsOf: folder.appendingPathComponent("2026-05-09.md"), encoding: .utf8)
        XCTAssertTrue(body.contains("first of the day"))
    }

    // MARK: - mutateDay funnel: optimistic concurrency (design §Phase 1)

    /// The lost-update race: an external writer (Obsidian) saves between Jotty's
    /// read and write. The funnel must detect the stamp mismatch, re-read, and
    /// re-apply the mutation — the external edit SURVIVES.
    func testExternalEditBetweenReadAndWriteSurvivesViaRetry() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_mine", text: "jotty task", createdAt: date)],
                                at: date)
        let url = folder.appendingPathComponent("2026-05-08.md")

        var externalInjected = false
        try store.mutateDay(on: date) { doc in
            if !externalInjected {
                externalInjected = true
                // Simulate Obsidian: append an external task directly on disk
                // between Jotty's read and its write.
                var external = try! MarkdownDoc.parse(String(contentsOf: url, encoding: .utf8), timezone: self.tz)
                external.appendTodo(Todo(id: "t_external", text: "obsidian task", createdAt: date))
                try! external.serialize(timezone: self.tz).write(to: url, atomically: true, encoding: .utf8)
            }
            doc.appendTodo(Todo(id: "t_funnel", text: "funnel task", createdAt: date))
            return true
        }

        let final = try MarkdownDoc.parse(String(contentsOf: url, encoding: .utf8), timezone: tz)
        let ids = final.tasks.map(\.id)
        XCTAssertTrue(ids.contains("t_external"), "external edit must survive the retry")
        XCTAssertTrue(ids.contains("t_funnel"), "the mutation must be re-applied on retry")
        XCTAssertTrue(ids.contains("t_mine"))
        XCTAssertEqual(ids.filter { $0 == "t_funnel" }.count, 1, "retry must not double-apply")
    }

    /// An external writer that keeps hammering the file must not livelock the
    /// funnel: bounded attempts, then a typed failure — never a silent clobber.
    func testRetryExhaustionThrowsAfterBoundedAttempts() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "seed", at: date, id: "n_100")
        let url = folder.appendingPathComponent("2026-05-08.md")

        var invocations = 0
        XCTAssertThrowsError(
            try store.mutateDay(on: date) { doc in
                invocations += 1
                // External writer wins every race: change the bytes on every attempt.
                try! "external rewrite #\(invocations)\n".write(to: url, atomically: true, encoding: .utf8)
                doc.appendTodo(Todo(id: "t_never", text: "never lands", createdAt: date))
                return true
            }
        ) { error in
            guard case StoreError.conflictRetryExhausted = error else {
                return XCTFail("expected conflictRetryExhausted, got \(error)")
            }
        }
        XCTAssertEqual(invocations, 3, "funnel is bounded at 3 attempts")
    }

    /// A transform that declines (returns false) writes nothing: the file stays
    /// byte-identical — the renameTodo empty-rename contract, funnel-wide.
    func testNoOpTransformLeavesFileByteIdentical() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "seed", at: date, id: "n_200")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let before = try Data(contentsOf: url)

        try store.mutateDay(on: date) { _ in false }

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// A no-op transform on an ABSENT day must not conjure a file into existence.
    func testNoOpTransformOnAbsentDayCreatesNoFile() throws {
        let date = makeDate(2026, 5, 10, h: 9, m: 0)
        try store.mutateDay(on: date) { _ in false }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("2026-05-10.md").path))
    }

    /// State-setting retry semantics (adversarial-review item 2): a toggle whose
    /// race partner already completed the task must not flip it back off. The
    /// desired state is captured on the FIRST read and re-asserted on retries.
    func testToggleUnderConflictIsStateSettingNotStateFlipping() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_race", text: "shared", createdAt: date)],
                                at: date)
        let url = folder.appendingPathComponent("2026-05-08.md")

        var externalInjected = false
        store.onBeforeWriteForTesting = {
            guard !externalInjected else { return }
            externalInjected = true
            // External writer completes the SAME task between read and write.
            var external = try! MarkdownDoc.parse(String(contentsOf: url, encoding: .utf8), timezone: self.tz)
            if let i = external.tasks.firstIndex(where: { $0.id == "t_race" }) {
                external.tasks[i].done = true
            }
            try! external.serialize(timezone: self.tz).write(to: url, atomically: true, encoding: .utf8)
        }
        defer { store.onBeforeWriteForTesting = nil }

        // User's intent at click time: task was NOT done → intent is "mark done".
        try store.toggleTodo(id: "t_race", on: date)

        let final = try MarkdownDoc.parse(String(contentsOf: url, encoding: .utf8), timezone: tz)
        XCTAssertEqual(final.tasks.first(where: { $0.id == "t_race" })?.done, true,
                       "retry must re-assert the captured intent (done), not re-flip to false")
    }

    /// Adversarial-review finding 4: an EXTERNAL delete of the task mid-move must
    /// win — the landing must not resurrect a task the user just deleted in
    /// Obsidian. (The landing id-guard prevents duplication, not resurrection.)
    func testMoveToTomorrowDoesNotResurrectExternallyDeletedTask() throws {
        let source = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_move", text: "moving", createdAt: source)],
                                at: source)
        let sourceURL = folder.appendingPathComponent("2026-05-08.md")

        var injected = false
        store.onBeforeWriteForTesting = {
            guard !injected else { return }
            injected = true
            // External writer deletes the task from the SOURCE file while the
            // move is landing the copy on tomorrow.
            var external = try! MarkdownDoc.parse(String(contentsOf: sourceURL, encoding: .utf8), timezone: self.tz)
            external.tasks.removeAll { $0.id == "t_move" }
            try! external.serialize(timezone: self.tz).write(to: sourceURL, atomically: true, encoding: .utf8)
        }
        defer { store.onBeforeWriteForTesting = nil }

        try store.moveTodoToTomorrow(id: "t_move", from: source, now: source)

        let sourceDoc = try store.readDoc(on: source)
        let tomorrowDoc = try store.readDoc(on: makeDate(2026, 5, 9, h: 0, m: 0))
        XCTAssertFalse(sourceDoc.tasks.contains { $0.id == "t_move" })
        XCTAssertFalse(tomorrowDoc.tasks.contains { $0.id == "t_move" },
                       "landing must be compensated when the source line vanished externally")
    }

    /// Adversarial-review nit 5: a declining transform must not materialize the
    /// storage folder as a side effect.
    func testDecliningTransformDoesNotCreateStorageFolder() throws {
        let ghostFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let ghostStore = Store(folder: ghostFolder, timezone: tz)
        try ghostStore.mutateDay(on: makeDate(2026, 5, 8, h: 9, m: 0)) { _ in false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghostFolder.path))
    }

    /// Adversarial-review finding 3 (visibility): StoreError must render a
    /// human-readable description, not "(Jotty.StoreError error 1.)".
    func testStoreErrorsAreLocalized() {
        let url = URL(fileURLWithPath: "/tmp/2026-05-08.md")
        let unreadable = StoreError.dayFileUnreadable(url, underlying: CocoaError(.fileReadNoPermission))
        let exhausted = StoreError.conflictRetryExhausted(url)
        XCTAssertTrue((unreadable.errorDescription ?? "").contains("2026-05-08"))
        XCTAssertTrue((exhausted.errorDescription ?? "").lowercased().contains("conflict"))
    }

    /// Guarded ops (rename/toggle/…) on an unreadable file must also throw rather
    /// than silently no-op — the caller needs to surface the failure notice.
    func testRenameOnUnreadableDayFileThrows() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "seed", at: date, id: "n_010")
        let url = folder.appendingPathComponent("2026-05-08.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(try store.renameTodo(id: "t_1", text: "new", on: date)) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Coordinated accessors in the funnel (roadmap 3.4 phase 2)

    /// (a) A funnel mutation routes its day-file READ and WRITE through the
    /// coordinator seam, and the coordinated write uses `.forReplacing`.
    func testFunnelRoutesReadAndWriteThroughCoordinatorWithForReplacing() throws {
        let recorder = RecordingCoordinator()
        let s = Store(folder: folder, timezone: tz, coordinator: recorder)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let url = folder.appendingPathComponent("2026-05-08.md")

        try s.appendNote(text: "coordinated capture", at: date, id: "n_c1")

        let calls = recorder.calls
        XCTAssertTrue(calls.contains { $0.kind == .read && $0.url == url },
                      "funnel read must route through the coordinator seam")
        let writes = calls.filter { $0.kind == .write && $0.url == url }
        XCTAssertFalse(writes.isEmpty, "funnel write must route through the coordinator seam")
        XCTAssertTrue(writes.allSatisfy {
            NSFileCoordinator.WritingOptions(rawValue: $0.writeOptionsRaw ?? 0).contains(.forReplacing)
        }, "coordinated writes must use .forReplacing")
        // This test method runs on the main thread (XCTest default for a
        // synchronous test), so `!isMainThread` here proves the off-actor +
        // timeout structure via the seam itself, not just via HangingCoordinator's
        // separate thread-identity check in the never-returning-coordinator test.
        XCTAssertTrue(calls.allSatisfy { !$0.isMainThread },
                      "coordination must run off the caller's (main) thread")
        // Pass-through coordinator still does the real I/O — the capture landed.
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("coordinated capture"))
    }

    /// (b) A coordinator that never returns must NOT hang the caller: the op fails
    /// with the notice-channel error after the timeout, and the coordination ran on
    /// a background executor (off the caller thread). This is the Risk-4 off-actor +
    /// timeout structure, proven via the seam.
    func testNeverReturningCoordinatorFailsAfterTimeoutOffCallerThread() throws {
        let hang = HangingCoordinator(hangReads: true)
        let s = Store(folder: folder, timezone: tz, coordinator: hang, coordinationTimeout: 0.2)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)

        let callerThreadID = ObjectIdentifier(Thread.current)
        let start = Date()
        XCTAssertThrowsError(try s.appendNote(text: "x", at: date, id: "n_hang")) { error in
            guard case StoreError.coordinationTimedOut = error else {
                return XCTFail("expected StoreError.coordinationTimedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.2, "must wait out the timeout")
        XCTAssertLessThan(elapsed, 5.0, "must NOT block for the never-returning coordinator")
        XCTAssertTrue(hang.didEnter, "coordination must have started on the executor")
        XCTAssertNotNil(hang.coordinationThreadID)
        XCTAssertNotEqual(hang.coordinationThreadID, callerThreadID,
                          "coordination must run on a background executor, off the caller thread")
        // The op failed before any write — nothing was clobbered or created.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("2026-05-08.md").path))
    }

    /// (c1) Retry-on-stamp-mismatch with external-edit survival is unchanged with
    /// coordination active (pass-through seam): the external edit still survives and
    /// the mutation is re-applied exactly once.
    func testExternalEditSurvivesRetryWithCoordinationActive() throws {
        let recorder = RecordingCoordinator()
        let s = Store(folder: folder, timezone: tz, coordinator: recorder)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try s.appendCapture(noteText: "", noteId: nil,
                            tasks: [Todo(id: "t_mine", text: "jotty task", createdAt: date)],
                            at: date)
        let fileURL = folder.appendingPathComponent("2026-05-08.md")

        var externalInjected = false
        try s.mutateDay(on: date) { doc in
            if !externalInjected {
                externalInjected = true
                var external = try! MarkdownDoc.parse(String(contentsOf: fileURL, encoding: .utf8), timezone: self.tz)
                external.appendTodo(Todo(id: "t_external", text: "obsidian task", createdAt: date))
                try! external.serialize(timezone: self.tz).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            doc.appendTodo(Todo(id: "t_funnel", text: "funnel task", createdAt: date))
            return true
        }

        let ids = try MarkdownDoc.parse(String(contentsOf: fileURL, encoding: .utf8), timezone: tz).tasks.map(\.id)
        XCTAssertTrue(ids.contains("t_external"), "external edit must survive the retry under coordination")
        XCTAssertTrue(ids.contains("t_funnel"), "the mutation must be re-applied on retry")
        XCTAssertEqual(ids.filter { $0 == "t_funnel" }.count, 1, "retry must not double-apply")
    }

    /// (c2) The no-op-transform byte-identical contract holds with coordination
    /// active: a declining transform performs NO coordinated write and the file is
    /// byte-identical.
    func testNoOpTransformByteIdenticalWithCoordinationActive() throws {
        let recorder = RecordingCoordinator()
        let s = Store(folder: folder, timezone: tz, coordinator: recorder)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try s.appendNote(text: "seed", at: date, id: "n_c2")
        let fileURL = folder.appendingPathComponent("2026-05-08.md")
        let before = try Data(contentsOf: fileURL)
        let writesBefore = recorder.calls.filter { $0.kind == .write }.count

        try s.mutateDay(on: date) { _ in false }

        XCTAssertEqual(try Data(contentsOf: fileURL), before, "no-op transform must leave the file byte-identical")
        XCTAssertEqual(recorder.calls.filter { $0.kind == .write }.count, writesBefore,
                       "a declining transform must perform no coordinated write")
    }

    // MARK: - Dataless iCloud file handling (roadmap 3.4 phase 2, Task 5)

    /// (a) `.notDownloaded` + a coordinated read that then succeeds (the file
    /// provider materialized it) → the op proceeds normally, using the downloaded
    /// bytes. The probe is consulted but does not gate a read that succeeds.
    func testNotDownloadedWithSuccessfulCoordinatedReadProceeds() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "already on disk", at: date, id: "n_dl1")
        let url = folder.appendingPathComponent("2026-05-08.md")

        let probe = FakeUbiquitousStatusProbe(status: .notDownloaded)
        let recorder = RecordingCoordinator()
        let s = Store(folder: folder, timezone: tz, coordinator: recorder, probe: probe)

        try s.appendNote(text: "second capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_dl2")

        XCTAssertTrue(probe.calls.contains(url), "the probe seam must be consulted before the read")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("already on disk"))
        XCTAssertTrue(body.contains("second capture"), "op must proceed once the coordinated read succeeds")
    }

    /// (b) `.notDownloaded` + the download failing (offline) → the op throws
    /// `dayFileUnreadable`, never `absent`/fresh-doc, and the file is untouched —
    /// even when the underlying read failure is ENOENT-shaped (a failed-download
    /// dataless placeholder can present exactly like a missing file; the probe is
    /// what tells `readDay` not to collapse that into "absent").
    func testNotDownloadedWithFailedDownloadThrowsUnreadableNeverAbsent() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "precious existing content", at: date, id: "n_dl3")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let originalBytes = try Data(contentsOf: url)

        let probe = FakeUbiquitousStatusProbe(status: .notDownloaded)
        let failing = FailingReadCoordinator(readError: CocoaError(.fileReadNoSuchFile))
        let s = Store(folder: folder, timezone: tz, coordinator: failing, probe: probe)

        XCTAssertThrowsError(
            try s.appendNote(text: "new capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_dl4")
        ) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable (never absent), got \(error)")
            }
        }
        XCTAssertTrue(probe.calls.contains(url))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "a dataless file whose download failed must never be treated as absent/clobbered")
    }

    /// (c) A non-ubiquitous file (probe returns nil) keeps the unchanged fast
    /// path: the probe is consulted (wired in) but does not alter classification —
    /// an unreadable file is still `dayFileUnreadable`, exactly as pre-Task-5.
    func testNonUbiquitousProbeNilKeepsUnchangedFastPath() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "precious existing content", at: date, id: "n_dl5")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let originalBytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let probe = FakeUbiquitousStatusProbe(status: nil)
        let s = Store(folder: folder, timezone: tz, probe: probe)

        XCTAssertThrowsError(
            try s.appendNote(text: "new capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_dl6")
        ) { error in
            guard case StoreError.dayFileUnreadable = error else {
                return XCTFail("expected StoreError.dayFileUnreadable, got \(error)")
            }
        }
        XCTAssertTrue(probe.calls.contains(url), "probe seam is still consulted on the fast path")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    /// (d) Review finding 1 (roadmap 3.4 phase 2): a wedged provider on the PROBE
    /// call itself — not just the coordinated read — must not hang the caller past
    /// the probe's own timeout. A hanging probe + a healthy underlying file: the
    /// probe times out and is classified as `nil` (same as a probe throw), and the
    /// coordinated read that follows still succeeds normally, using the real bytes.
    func testHangingProbeWithHealthyFileSucceedsWithinTimeout() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendNote(text: "already on disk", at: date, id: "n_hp1")
        let url = folder.appendingPathComponent("2026-05-08.md")

        let probe = HangingUbiquitousStatusProbe()
        let s = Store(folder: folder, timezone: tz, coordinationTimeout: 0.2, probe: probe)

        let start = Date()
        try s.appendNote(text: "second capture", at: makeDate(2026, 5, 8, h: 10, m: 0), id: "n_hp2")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "a hanging probe must not block the caller unboundedly")
        XCTAssertTrue(probe.didEnter, "the probe must have been invoked")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("already on disk"))
        XCTAssertTrue(body.contains("second capture"),
                      "op must proceed once the probe times out (nil classification), same as a probe throw")
    }

    /// (e) A hanging probe AND a hanging coordinated read together must still fail
    /// within the SUM of their two independent timeouts, never hang unboundedly —
    /// each leg (probe, read) runs through its own `runOffActorWithTimeout` bound.
    /// The probe having timed out collapses to `nil` (unchanged classification), so
    /// the subsequent read's own timeout is what surfaces: `coordinationTimedOut`,
    /// never rewrapped as `dayFileUnreadable`.
    func testHangingProbeAndHangingCoordinatorFailsWithinSummedTimeouts() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let probe = HangingUbiquitousStatusProbe()
        let hangingCoordinator = HangingCoordinator(hangReads: true)
        let timeout: TimeInterval = 0.2
        let s = Store(folder: folder, timezone: tz, coordinator: hangingCoordinator,
                     coordinationTimeout: timeout, probe: probe)

        let start = Date()
        XCTAssertThrowsError(
            try s.appendNote(text: "x", at: date, id: "n_hp3")
        ) { error in
            guard case StoreError.coordinationTimedOut = error else {
                return XCTFail("expected StoreError.coordinationTimedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, timeout * 2 - 0.05,
                                    "must wait out BOTH the probe timeout and the read timeout")
        XCTAssertLessThan(elapsed, 5.0, "must NOT block unboundedly for the doubly-wedged provider")
        XCTAssertTrue(probe.didEnter, "the probe must have been invoked")
        XCTAssertTrue(hangingCoordinator.didEnter,
                      "the coordinated read must have been attempted after the probe timed out")
    }

    // MARK: - iCloud conflict-sibling detection (roadmap 3.4 phase 2, Task 6)

    /// Sidecars matching `<name>.conflict-*.md` in the store folder, name-sorted.
    private func conflictSidecarFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".conflict-") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Review finding (roadmap 3.4 phase 2): a `Store` that NEVER attaches an
    /// `onUnresolvedConflict` listener — the shape of `RolloverService.
    /// scanStore` (reconstructed on every foreground activation, main actor)
    /// and `CommandBarIndex`'s per-build Store — must pay ZERO probe calls.
    /// The old design probed unconditionally inside `init`, charging every
    /// listenerless secondary store the same off-actor-plus-timeout round
    /// trip as the one store that could ever observe the result.
    func testConstructionWithNoListenerAttachedPerformsZeroProbeCalls() throws {
        let v1 = FakeConflictVersion(content: Data("losing content\n".utf8))
        let probe = FakeConflictSiblingProbe(hasConflicts: true, versions: [v1])

        _ = Store(folder: folder, timezone: tz, conflictProbe: probe)

        XCTAssertTrue(probe.calls.isEmpty,
                      "a store with no onUnresolvedConflict listener must never probe")
        XCTAssertFalse(v1.isResolved)
        XCTAssertTrue(try conflictSidecarFiles().isEmpty)
    }

    /// The initial construction-time-equivalent probe now fires the moment
    /// `onUnresolvedConflict` is FIRST assigned a non-nil listener (its
    /// `didSet`), not inside `init`. This is what preserves launch-time
    /// self-heal detection for the primary store — `MenubarListModel`
    /// attaches its listener immediately after construction.
    func testAttachingListenerPerformsTheInitialCheck() throws {
        let v1 = FakeConflictVersion(content: Data("losing content\n".utf8))
        let probe = FakeConflictSiblingProbe(hasConflicts: true, versions: [v1])
        let s = Store(folder: folder, timezone: tz, conflictProbe: probe)
        XCTAssertTrue(probe.calls.isEmpty, "no probe call yet — no listener attached")

        var fired: [URL] = []
        s.onUnresolvedConflict = { fired.append($0) }

        XCTAssertFalse(probe.calls.isEmpty, "attaching the listener must trigger the initial check")
        XCTAssertEqual(fired.count, 1, "the initial check surfaces the already-present conflict")
        XCTAssertTrue(v1.isResolved, "the initial check materializes + resolves today's conflict")
        let sidecars = try conflictSidecarFiles()
        XCTAssertEqual(sidecars.count, 1)
        XCTAssertEqual(try String(contentsOf: sidecars[0], encoding: .utf8), "losing content\n")
    }

    /// (a) probe-true → the banner (`onUnresolvedConflict`) fires exactly ONCE
    /// regardless of how many losing versions there are, and EACH losing
    /// version is materialized as its own `.conflict-<stamp>.md` sidecar
    /// holding that version's own content. The probe starts `false` so
    /// construction itself is a no-op, then flips true before the explicit
    /// call — isolating this test from the construction-time check exercised
    /// above.
    func testUnresolvedConflictFiresBannerOnceAndMaterializesEachLosingVersionAsSidecar() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let v1 = FakeConflictVersion(content: Data("losing version A\n".utf8))
        let v2 = FakeConflictVersion(content: Data("losing version B\n".utf8))
        let probe = FakeConflictSiblingProbe(hasConflicts: false)
        let s = Store(folder: folder, timezone: tz, conflictProbe: probe)

        var fired: [URL] = []
        s.onUnresolvedConflict = { fired.append($0) }

        probe.hasConflicts = true
        probe.versions = [v1, v2]
        s.checkForUnresolvedConflicts(on: date)

        XCTAssertEqual(fired.count, 1, "banner fires exactly once regardless of losing-version count")
        XCTAssertEqual(fired.first?.lastPathComponent, "2026-05-08.md")

        let sidecars = try conflictSidecarFiles()
        XCTAssertEqual(sidecars.count, 2, "one sidecar per losing version")
        let contents = Set(try sidecars.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents, ["losing version A\n", "losing version B\n"])
        XCTAssertTrue(sidecars.allSatisfy { $0.lastPathComponent.contains(".conflict-") })

        XCTAssertTrue(v1.isResolved, "sidecar landed → version marked resolved")
        XCTAssertTrue(v2.isResolved)
    }

    /// (b) probe-false → nothing: no banner, no sidecar.
    func testNoUnresolvedConflictFiresNothing() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let probe = FakeConflictSiblingProbe(hasConflicts: false)
        let s = Store(folder: folder, timezone: tz, conflictProbe: probe)

        var fired: [URL] = []
        s.onUnresolvedConflict = { fired.append($0) }

        s.checkForUnresolvedConflicts(on: date)

        XCTAssertTrue(fired.isEmpty, "no conflict → banner must not fire")
        XCTAssertTrue(try conflictSidecarFiles().isEmpty, "no conflict → no sidecar")
        XCTAssertTrue(probe.calls.contains(url(for: date)), "the probe seam is still consulted")
    }

    /// (c) Sidecar naming is collision-safe (two losing versions never collide
    /// on a filename) and is NEVER parsed as a day file — the same strict
    /// `yyyy-MM-dd` discipline that already excludes `.corrupt-*` sidecars from
    /// `allDayDates()`.
    func testConflictSidecarNamingIsCollisionSafeAndExcludedFromDayFileParsing() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let v1 = FakeConflictVersion(content: Data("A\n".utf8))
        let v2 = FakeConflictVersion(content: Data("B\n".utf8))
        let probe = FakeConflictSiblingProbe(hasConflicts: false)
        let s = Store(folder: folder, timezone: tz, conflictProbe: probe)
        probe.hasConflicts = true
        probe.versions = [v1, v2]

        s.checkForUnresolvedConflicts(on: date)

        let sidecars = try conflictSidecarFiles()
        XCTAssertEqual(sidecars.count, 2, "two losing versions must not collide onto one filename")
        XCTAssertEqual(Set(sidecars.map(\.lastPathComponent)).count, 2, "filenames must be distinct")
        for sidecar in sidecars {
            XCTAssertTrue(sidecar.lastPathComponent.hasPrefix("2026-05-08.conflict-"))
            XCTAssertEqual(sidecar.pathExtension, "md")
        }

        // Never parsed as a day file: the strict yyyy-MM-dd formatter must
        // reject every sidecar's stem.
        let dayFormatter = DailyFile.dayFormatter(timezone: tz)
        for sidecar in sidecars {
            let stem = String(sidecar.lastPathComponent.dropLast(3))   // drop ".md"
            XCTAssertNil(dayFormatter.date(from: stem),
                         "a conflict sidecar name must never parse as a day key")
        }
        XCTAssertTrue(s.allDayDates().isEmpty, "sidecars are never counted as day files")
    }

    /// Per-version resolve (review finding, roadmap 3.4 phase 2): a version
    /// whose sidecar lands is marked resolved IMMEDIATELY — independent of a
    /// sibling version that keeps failing — and stays resolved with exactly
    /// ONE sidecar across two reload cycles (the persistent-failure duplicate-
    /// sidecar bug this replaces: the old whole-batch design left EVERY
    /// version unresolved on any single failure, so the next reload
    /// re-materialized the already-succeeded version into a fresh
    /// wall-clock-stamped file, unboundedly). The still-failing version stays
    /// unresolved and is genuinely retried (its `materializedContents()` is
    /// called again) on the next check. The banner still fires each check,
    /// since a conflict was found each time.
    func testPartialFailureResolvesSucceededVersionOnceAndRetriesFailedVersionAcrossReloads() throws {
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let v1 = FakeConflictVersion(content: Data("ok content\n".utf8))
        let v2 = FakeConflictVersion(content: Data("unreachable".utf8),
                                     contentsError: CocoaError(.fileReadUnknown))
        let probe = FakeConflictSiblingProbe(hasConflicts: false)
        let s = Store(folder: folder, timezone: tz, conflictProbe: probe)

        var fired: [URL] = []
        s.onUnresolvedConflict = { fired.append($0) }

        // First reload cycle: v1 succeeds, v2 fails.
        probe.hasConflicts = true
        probe.versions = [v1, v2]
        s.checkForUnresolvedConflicts(on: date)

        XCTAssertEqual(fired.count, 1, "the banner fires — a conflict was found")
        XCTAssertTrue(v1.isResolved, "the version whose sidecar landed is resolved immediately")
        XCTAssertFalse(v2.isResolved, "the version that failed to materialize stays unresolved")
        XCTAssertEqual(v1.materializeCallCount, 1)
        let sidecarsAfterFirst = try conflictSidecarFiles()
        XCTAssertEqual(sidecarsAfterFirst.count, 1, "only the succeeded version's sidecar landed")

        // Second reload cycle: v1 is now resolved, so a real NSFileVersion
        // enumeration would no longer surface it — the fake mirrors that.
        // v2 keeps failing, exactly as a persistent failure would.
        probe.versions = [v2]
        s.checkForUnresolvedConflicts(on: date)

        XCTAssertEqual(fired.count, 2, "still-unresolved conflict keeps firing the banner every check")
        XCTAssertFalse(v2.isResolved, "the persistently-failing version stays unresolved")
        XCTAssertEqual(v2.materializeCallCount, 2, "the failed version is genuinely retried, not abandoned")
        let sidecarsAfterSecond = try conflictSidecarFiles()
        XCTAssertEqual(sidecarsAfterSecond.count, 1,
                       "v1's already-resolved sidecar must never be re-materialized/duplicated by the retry")
    }

    private func url(for date: Date) -> URL {
        DailyFile.url(in: folder, on: date, timezone: tz)
    }
}

// MARK: - Conflict-sibling probe test doubles (roadmap 3.4 phase 2, Task 6)

/// Fake losing `NSFileVersion`: fixed content plus an observable resolved flag.
/// `NSFileVersion` itself has no public initializer and only exists for a
/// genuinely conflicted ubiquitous item, so this fake is how conflict-sibling
/// content is simulated in tests — mirrors why `FakeUbiquitousStatusProbe`
/// exists instead of exercising real iCloud. `@unchecked Sendable`: only
/// mutable state is `_isResolved`, guarded by `lock` (the `RecordingCoordinator`
/// idiom).
final class FakeConflictVersion: ConflictVersionMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    let content: Data
    private let contentsError: Error?
    private let resolveError: Error?
    private var _isResolved = false
    var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return _isResolved }
    /// How many times `materializedContents()` was called — lets a test prove a
    /// still-failing version is genuinely RETRIED on a subsequent
    /// `checkForUnresolvedConflicts` call (roadmap 3.4 phase 2, review finding:
    /// per-version resolve), not just left alone.
    private var _materializeCallCount = 0
    var materializeCallCount: Int { lock.lock(); defer { lock.unlock() }; return _materializeCallCount }

    init(content: Data, contentsError: Error? = nil, resolveError: Error? = nil) {
        self.content = content
        self.contentsError = contentsError
        self.resolveError = resolveError
    }

    func materializedContents() throws -> Data {
        lock.lock(); _materializeCallCount += 1; lock.unlock()
        if let contentsError { throw contentsError }
        return content
    }

    func markResolved() throws {
        if let resolveError { throw resolveError }
        lock.lock(); _isResolved = true; lock.unlock()
    }
}

/// Fake conflict-sibling probe: `hasConflicts`/`versions` are settable AFTER
/// construction (unlike `FakeUbiquitousStatusProbe`'s fixed answer) so a test
/// can construct a `Store` with a harmless `false` answer (a no-op construction-
/// time check) and only THEN flip to `true` before calling
/// `checkForUnresolvedConflicts` explicitly — isolating the explicit-call tests
/// from the construction-time check every `Store(conflictProbe:)` call also
/// performs. `@unchecked Sendable`: mutable state guarded by `lock`.
final class FakeConflictSiblingProbe: ConflictSiblingProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }
    private var _hasConflicts: Bool
    var hasConflicts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasConflicts }
        set { lock.lock(); _hasConflicts = newValue; lock.unlock() }
    }
    private var _versions: [ConflictVersionMaterializing]
    var versions: [ConflictVersionMaterializing] {
        get { lock.lock(); defer { lock.unlock() }; return _versions }
        set { lock.lock(); _versions = newValue; lock.unlock() }
    }

    init(hasConflicts: Bool, versions: [ConflictVersionMaterializing] = []) {
        self._hasConflicts = hasConflicts
        self._versions = versions
    }

    func hasUnresolvedConflicts(at url: URL) throws -> Bool {
        lock.lock(); _calls.append(url); let has = _hasConflicts; lock.unlock()
        return has
    }

    func unresolvedConflictVersions(at url: URL) throws -> [ConflictVersionMaterializing] {
        lock.lock(); defer { lock.unlock() }
        return _versions
    }
}

// MARK: - Coordinator test doubles

/// Pass-through coordinator that records every coordinated access (kind, url, write
/// options, and an identity for the thread it ran on) and then performs the real
/// I/O. Lets the funnel tests assert reads/writes route through the seam with
/// `.forReplacing` while the capture still lands on disk. `@unchecked Sendable`:
/// the only mutable state is `_calls`, guarded by `lock` (the ConfigStore idiom).
final class RecordingCoordinator: FileCoordinating, @unchecked Sendable {
    enum Kind: Sendable { case read, write }
    struct Call: Sendable {
        let kind: Kind
        let url: URL
        let writeOptionsRaw: UInt?
        let threadID: ObjectIdentifier
        let isMainThread: Bool
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ call: Call) { lock.lock(); _calls.append(call); lock.unlock() }

    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws {
        record(Call(kind: .read, url: url, writeOptionsRaw: nil,
                    threadID: ObjectIdentifier(Thread.current), isMainThread: Thread.isMainThread))
        try accessor(url)
    }
    func coordinateWriting(at url: URL, options: NSFileCoordinator.WritingOptions,
                           _ accessor: (URL) throws -> Void) throws {
        record(Call(kind: .write, url: url, writeOptionsRaw: options.rawValue,
                    threadID: ObjectIdentifier(Thread.current), isMainThread: Thread.isMainThread))
        try accessor(url)
    }
}

/// Coordinator that never returns from the requested access, simulating a wedged
/// `fileproviderd`. Records the thread it ran on so a test can prove the hang was
/// off the caller thread; blocks on a semaphore that is never signaled.
final class HangingCoordinator: FileCoordinating, @unchecked Sendable {
    private let hangReads: Bool
    private let hangWrites: Bool
    private let neverSignaled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entered = false
    private var _threadID: ObjectIdentifier?
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return _entered }
    var coordinationThreadID: ObjectIdentifier? { lock.lock(); defer { lock.unlock() }; return _threadID }

    init(hangReads: Bool = false, hangWrites: Bool = false) {
        self.hangReads = hangReads
        self.hangWrites = hangWrites
    }
    private func mark() {
        lock.lock(); _entered = true; _threadID = ObjectIdentifier(Thread.current); lock.unlock()
    }
    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws {
        mark()
        if hangReads { neverSignaled.wait() }  // never returns
        try accessor(url)
    }
    func coordinateWriting(at url: URL, options: NSFileCoordinator.WritingOptions,
                           _ accessor: (URL) throws -> Void) throws {
        mark()
        if hangWrites { neverSignaled.wait() }  // never returns
        try accessor(url)
    }
}

/// Coordinator whose coordinated READ always fails with a fixed error — simulates
/// a dataless iCloud file whose materialization/download failed (offline). Write
/// is pass-through (never reached in the offline-unreadable scenario, since the
/// funnel throws before it gets to write).
final class FailingReadCoordinator: FileCoordinating, @unchecked Sendable {
    private let readError: Error
    init(readError: Error) { self.readError = readError }

    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws {
        throw readError
    }
    func coordinateWriting(at url: URL, options: NSFileCoordinator.WritingOptions,
                           _ accessor: (URL) throws -> Void) throws {
        try accessor(url)
    }
}

// MARK: - Dataless-file probe test double

/// Fixed-answer probe: returns the same `status` for every URL it's asked about
/// and records what it was asked (roadmap 3.4 phase 2, Task 5). Real iCloud never
/// appears in tests — this fake is how `.notDownloaded` is simulated on an
/// ordinary temp-dir file. `@unchecked Sendable`: only mutable state is `_calls`,
/// guarded by `lock` (the `RecordingCoordinator` idiom).
final class FakeUbiquitousStatusProbe: UbiquitousStatusProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }
    private let status: URLUbiquitousItemDownloadingStatus?

    init(status: URLUbiquitousItemDownloadingStatus?) { self.status = status }

    func downloadingStatus(of url: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        lock.lock(); _calls.append(url); lock.unlock()
        return status
    }
}

/// Probe that never returns, simulating a wedged provider on the PROBE call
/// itself — distinct from `HangingCoordinator`, which hangs the coordinated
/// read (review finding 1, roadmap 3.4 phase 2). Blocks on a semaphore that is
/// never signaled; records whether it was entered. `@unchecked Sendable`: only
/// mutable state is `_entered`, guarded by `lock` (the `HangingCoordinator`
/// idiom).
final class HangingUbiquitousStatusProbe: UbiquitousStatusProbing, @unchecked Sendable {
    private let neverSignaled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entered = false
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return _entered }

    func downloadingStatus(of url: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        lock.lock(); _entered = true; lock.unlock()
        neverSignaled.wait()  // never returns
        return nil
    }
}
