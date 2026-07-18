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
