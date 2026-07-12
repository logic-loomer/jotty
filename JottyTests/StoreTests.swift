import XCTest
@testable import Jotty

final class StoreTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAppendNoteCreatesFileIfMissing() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let date = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendNote(text: "hello", at: date, id: "n_001")

        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("### 07:30 <!-- id:n_001 -->"))
        XCTAssertTrue(body.contains("hello"))
    }

    func testAppendNoteAppendsToExisting() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let d1 = makeDate(2026, 5, 8, h: 7, m: 30)
        let d2 = makeDate(2026, 5, 8, h: 8, m: 15)
        try store.appendNote(text: "first", at: d1, id: "n_001")
        try store.appendNote(text: "second", at: d2, id: "n_002")

        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("first"))
        XCTAssertTrue(body.contains("second"))
        XCTAssertTrue(body.contains("n_001"))
        XCTAssertTrue(body.contains("n_002"))
    }

    func testAppendCaptureWritesTasksAndNoteTogether() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let tasks = [Todo(id: "t_001", text: "one", createdAt: now)]
        try store.appendCapture(noteText: "a note", noteId: "n_001",
                                tasks: tasks, at: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("- [ ] one <!-- id:t_001"))
        XCTAssertTrue(body.contains("a note"))
    }

    func testToggleTaskFlipsState() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)],
                                at: now)
        try store.toggleTodo(id: "t_001", on: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("- [x] x <!-- id:t_001"))
        XCTAssertTrue(body.contains("done:"), "completedAt should be serialized as 'done:<ISO>' on toggle-on")

        try store.toggleTodo(id: "t_001", on: now)
        let body2 = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body2.contains("- [ ] x <!-- id:t_001"))
        XCTAssertFalse(body2.contains("done:"), "'done:' metadata should be removed on toggle-off")
    }

    func testMutateDayCanOverwriteTaskList() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "old", createdAt: now)],
                                at: now)
        try store.mutateDay(on: now) { doc in
            doc.tasks = [Todo(id: "t_999", text: "new", createdAt: now)]
            return true
        }
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(body.contains("t_001"))
        XCTAssertTrue(body.contains("t_999"))
    }

    // MARK: - Delete (SC3)

    func testDeleteTodoRemovesMatchingTaskOthersUntouched() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_keep", text: "keep me", createdAt: now),
            Todo(id: "t_drop", text: "drop me", createdAt: now)
        ], at: now)

        try store.deleteTodo(id: "t_drop", on: now)

        // Round-trips: reread shows the dropped task gone, the kept task intact.
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_keep"])
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(body.contains("t_drop"))
        XCTAssertTrue(body.contains("t_keep"))
    }

    func testDeleteTodoMissingIdIsNoOp() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)],
                                at: now)
        try store.deleteTodo(id: "t_nope", on: now)
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_001"])
    }

    // MARK: - Edit time (SC3)

    func testUpdateTodoTimeSetsTimeBlockAndPreservesCalEvent() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let oldStart = makeDate(2026, 5, 8, h: 14, m: 0)
        let oldEnd = makeDate(2026, 5, 8, h: 15, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_001", text: "review", createdAt: now,
                 timeBlock: TimeBlock(start: oldStart, end: oldEnd),
                 calEventID: "evt-abc")
        ], at: now)

        let newStart = makeDate(2026, 5, 8, h: 16, m: 0)
        let newEnd = makeDate(2026, 5, 8, h: 17, m: 0)
        try store.updateTodoTime(id: "t_001",
                                 timeBlock: TimeBlock(start: newStart, end: newEnd),
                                 on: now)

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first { $0.id == "t_001" })
        XCTAssertEqual(task.timeBlock, TimeBlock(start: newStart, end: newEnd))
        // cal_event preserved across the edit.
        XCTAssertEqual(task.calEventID, "evt-abc")
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("time:16:00-17:00"), "time: token must update")
        XCTAssertTrue(body.contains("cal_event:evt-abc"))
    }

    func testUpdateTodoTimeMissingIdIsNoOp() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)],
                                at: now)
        try store.updateTodoTime(id: "t_nope",
                                 timeBlock: TimeBlock(start: makeDate(2026, 5, 8, h: 9, m: 0),
                                                      end: makeDate(2026, 5, 8, h: 10, m: 0)),
                                 on: now)
        let doc = try store.readDoc(on: now)
        XCTAssertNil(try XCTUnwrap(doc.tasks.first).timeBlock)
    }

    // MARK: - Snooze + recurrence Store ops (Phase 8, CALX-03)

    func testSnoozeTodoSetsSnoozeOnDiskPreservingIdAndOtherTokens() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_snz", text: "write report", createdAt: now,
                 dueDate: makeDate(2026, 5, 9, h: 0, m: 0))
        ], at: now)

        try store.snoozeTodo(id: "t_snz", to: makeDate(2026, 5, 10, h: 9, m: 0), on: now)

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first { $0.id == "t_snz" })
        // snooze: is date-only (yyyy-MM-dd) — round-trips to midnight of the snooze day.
        XCTAssertEqual(task.snooze, makeDate(2026, 5, 10, h: 0, m: 0))
        // Copy-mutate whole Todo: id + every other token unchanged.
        XCTAssertEqual(task.id, "t_snz")
        XCTAssertEqual(task.text, "write report")
        XCTAssertEqual(task.createdAt, now)
        XCTAssertEqual(task.dueDate, makeDate(2026, 5, 9, h: 0, m: 0))
        XCTAssertFalse(task.done)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("snooze:2026-05-10"), "snooze: token written to disk")
    }

    func testSnoozeTodoMissingIdIsNoOpFileByteIdentical() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_001", text: "x", createdAt: now)],
                                at: now)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let before = try String(contentsOf: url, encoding: .utf8)

        try store.snoozeTodo(id: "t_nope", to: makeDate(2026, 5, 10, h: 0, m: 0), on: now)

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(before, after, "absent id must be a no-op (file byte-identical)")
    }

    func testSetTodoRecurrenceSetsAndNilClearsPreservingOtherFields() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_rec", text: "standup", createdAt: now,
                 dueDate: makeDate(2026, 5, 9, h: 0, m: 0))
        ], at: now)

        try store.setTodoRecurrence(id: "t_rec", to: .custom([1, 3, 5]), on: now)

        var doc = try store.readDoc(on: now)
        var task = try XCTUnwrap(doc.tasks.first { $0.id == "t_rec" })
        XCTAssertEqual(task.recur, .custom([1, 3, 5]))
        // All other fields survive the copy-mutate.
        XCTAssertEqual(task.text, "standup")
        XCTAssertEqual(task.createdAt, now)
        XCTAssertEqual(task.dueDate, makeDate(2026, 5, 9, h: 0, m: 0))
        let url = folder.appendingPathComponent("2026-05-08.md")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("recur:custom:1,3,5"))

        // The "None" Repeat choice: nil clears the token.
        try store.setTodoRecurrence(id: "t_rec", to: nil, on: now)
        doc = try store.readDoc(on: now)
        task = try XCTUnwrap(doc.tasks.first { $0.id == "t_rec" })
        XCTAssertNil(task.recur)
        XCTAssertEqual(task.text, "standup", "clear preserves the other fields too")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("recur:"))

        // Absent id is a no-op (byte-identical), mirroring snoozeTodo.
        let before = try String(contentsOf: url, encoding: .utf8)
        try store.setTodoRecurrence(id: "t_nope", to: .daily, on: now)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    func testSnoozePreservesCalEventTimeAndSourceTokens() throws {
        // Phase 7 CR-01 regression guard: snoozing a task that already carries
        // cal_event + time + source/source_url must preserve ALL of them — the
        // Store op copy-mutates the WHOLE Todo, never rebuilds field-by-field.
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let start = makeDate(2026, 5, 8, h: 14, m: 0)
        let end = makeDate(2026, 5, 8, h: 15, m: 0)
        try store.appendCapture(noteText: "", noteId: nil, tasks: [
            Todo(id: "t_full", text: "review PR", createdAt: now,
                 timeBlock: TimeBlock(start: start, end: end),
                 calEventID: "evt-abc",
                 source: "github:42",
                 sourceURL: "https://github.com/org/repo/issues/42")
        ], at: now)

        try store.snoozeTodo(id: "t_full", to: makeDate(2026, 5, 12, h: 0, m: 0), on: now)

        let doc = try store.readDoc(on: now)
        let task = try XCTUnwrap(doc.tasks.first { $0.id == "t_full" })
        XCTAssertEqual(task.snooze, makeDate(2026, 5, 12, h: 0, m: 0))
        XCTAssertEqual(task.timeBlock, TimeBlock(start: start, end: end),
                       "time: survives the snooze write")
        XCTAssertEqual(task.calEventID, "evt-abc", "cal_event: survives the snooze write")
        XCTAssertEqual(task.source, "github:42", "source: survives the snooze write")
        XCTAssertEqual(task.sourceURL, "https://github.com/org/repo/issues/42",
                       "source_url: survives the snooze write")
        XCTAssertEqual(task.text, "review PR")
    }

    // MARK: - #4 Quarantine an unparseable day file before overwriting it

    /// (a) Writing over a present-but-unparseable file copies the ORIGINAL bytes
    /// to exactly one `.corrupt-*` sidecar (surfaced via onCorruptQuarantine) and
    /// still lands the new capture — a day file broken by an external editor or
    /// sync conflict is preserved, never silently destroyed, and no capture lost.
    func testAppendCaptureOverUnparseableFileQuarantinesOriginalBytesAndKeepsNewContent() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let corrupt = "CONFLICT <<<<<<< sync garbage, not a valid jotty file\nrandom bytes\n"
        try corrupt.write(to: url, atomically: true, encoding: .utf8)

        var surfaced: [URL] = []
        store.onCorruptQuarantine = { surfaced.append($0) }

        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_new", text: "new capture", createdAt: now)],
                                at: now)

        // Exactly one sidecar, holding the original bytes verbatim.
        let sidecars = try sidecarFiles()
        XCTAssertEqual(sidecars.count, 1, "exactly one .corrupt-* sidecar")
        XCTAssertEqual(try String(contentsOf: sidecars[0], encoding: .utf8), corrupt,
                       "sidecar holds the original bytes verbatim")
        // Compare by name: the surfaced URL is built from `folder` while the
        // directory listing resolves the /var -> /private/var symlink.
        XCTAssertEqual(surfaced.map(\.lastPathComponent),
                       sidecars.map(\.lastPathComponent),
                       "quarantine is surfaced via onCorruptQuarantine")

        // The new capture is not lost — the day file now parses and contains it.
        let doc = try store.readDoc(on: now)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_new"])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("new capture"))
    }

    /// (a2) A present-but-NON-UTF8 day file (an editor or sync client re-encoded it
    /// as UTF-16) is CORRUPT, not absent: the next capture must quarantine the
    /// original bytes verbatim and still land — the old single-step
    /// `String(contentsOf:encoding:)` read collapsed the decode failure into
    /// "absent", so the day's entire contents were clobbered with no sidecar.
    func testAppendCaptureOverNonUTF8FileQuarantinesRawBytesAndKeepsNewContent() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let url = folder.appendingPathComponent("2026-05-08.md")
        // A real day's content, saved as UTF-16 (BOM + 2-byte units): valid text,
        // full of tasks, but not decodable as UTF-8.
        let original = "---\ndate: 2026-05-08\n---\n\n## Tasks\n\n- [ ] precious task <!-- id:t_keep -->\n"
        let utf16Bytes = original.data(using: .utf16)!
        try utf16Bytes.write(to: url)

        var surfaced: [URL] = []
        store.onCorruptQuarantine = { surfaced.append($0) }

        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_new", text: "new capture", createdAt: now)],
                                at: now)

        let sidecars = try sidecarFiles()
        XCTAssertEqual(sidecars.count, 1, "the non-UTF8 original must be quarantined, not clobbered")
        XCTAssertEqual(try Data(contentsOf: sidecars[0]), utf16Bytes,
                       "sidecar holds the original bytes verbatim, un-transcoded")
        XCTAssertEqual(surfaced.count, 1, "the recovery notice fires")
        XCTAssertEqual(try store.readDoc(on: now).tasks.map(\.id), ["t_new"])
    }

    /// (b) The happy paths (absent file, valid file) never quarantine.
    func testAbsentAndValidFilePathsCreateNoSidecar() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)

        // Absent → first capture creates the file, nothing to quarantine.
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_1", text: "one", createdAt: now)], at: now)
        XCTAssertEqual(try sidecarFiles().count, 0, "absent-file path quarantines nothing")

        // Valid → second capture appends to a parseable file, still nothing.
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_2", text: "two", createdAt: now)], at: now)
        XCTAssertEqual(try sidecarFiles().count, 0, "valid-file path quarantines nothing")
    }

    /// (c) A second overwrite of a re-corrupted file does not clobber the first
    /// sidecar — both original byte-sets survive as distinct files.
    func testSecondOverwriteDoesNotClobberFirstSidecar() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let now = makeDate(2026, 5, 8, h: 7, m: 30)
        let url = folder.appendingPathComponent("2026-05-08.md")

        let bytesA = "corruption A, no frontmatter\n"
        try bytesA.write(to: url, atomically: true, encoding: .utf8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_a", text: "a", createdAt: now)], at: now)
        XCTAssertEqual(try sidecarFiles().count, 1)

        // Re-corrupt the SAME day file with different bytes, capture again.
        let bytesB = "corruption B, different but still no frontmatter\n"
        try bytesB.write(to: url, atomically: true, encoding: .utf8)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_b", text: "b", createdAt: now)], at: now)

        let sidecars = try sidecarFiles()
        XCTAssertEqual(sidecars.count, 2, "second overwrite must not clobber the first sidecar")
        let contents = Set(try sidecars.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents, [bytesA, bytesB], "both original byte-sets preserved distinctly")
    }

    /// Sidecars matching `<name>.corrupt-*.md` in the store folder, name-sorted.
    private func sidecarFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - #12 ensureDayFile creates the day file when absent

    /// The ⌘K "Open Today's File" action must have a file to open before the
    /// day's first capture — ensureDayFile writes an empty scaffold on disk.
    func testEnsureDayFileCreatesFileWhenAbsent() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        let url = folder.appendingPathComponent("2026-05-08.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "precondition: no file yet")

        let returned = try store.ensureDayFile(on: date)
        XCTAssertEqual(returned.lastPathComponent, "2026-05-08.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "ensureDayFile creates the day file on disk")
        // The scaffold is a valid, empty day doc.
        XCTAssertTrue(try store.readDoc(on: date).tasks.isEmpty)
    }

    /// A present, valid file is left byte-identical (no rewrite/churn).
    func testEnsureDayFileLeavesExistingFileByteIdentical() throws {
        let store = Store(folder: folder, timezone: TimeZone(identifier: "Australia/Sydney")!)
        let date = makeDate(2026, 5, 8, h: 9, m: 0)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_1", text: "one", createdAt: date)], at: date)
        let url = folder.appendingPathComponent("2026-05-08.md")
        let before = try String(contentsOf: url, encoding: .utf8)

        _ = try store.ensureDayFile(on: date)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before,
                       "ensureDayFile must not rewrite an existing file")
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int, m mn: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mn
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
