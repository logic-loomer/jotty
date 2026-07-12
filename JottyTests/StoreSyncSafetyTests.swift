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
}
