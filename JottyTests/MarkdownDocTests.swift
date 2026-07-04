import XCTest
@testable import Jotty

final class MarkdownDocTests: XCTestCase {
    func testEmptyDocSerializes() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let text = doc.serialize(timezone: tz)
        XCTAssertTrue(text.contains("date: 2026-05-08"))
        XCTAssertTrue(text.contains("## Notes"))
    }

    func testAppendNoteAddsTimestampedEntry() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        doc.appendNote(text: "first thought",
                       at: timeFor("2026-05-08T07:30:00+10:00"),
                       id: "n_001")
        let text = doc.serialize(timezone: tz)
        XCTAssertTrue(text.contains("### 07:30 <!-- id:n_001 -->"))
        XCTAssertTrue(text.contains("first thought"))
    }

    // A time block that crosses midnight in the pinned/serialization timezone
    // (wall-clock end <= start, e.g. 23:00-00:00) must reconstruct with the end
    // rolled to the next day, not lose a day. Pinning UTC makes this deterministic
    // everywhere (regression for the CI/UTC-only failure).
    func testTimeBlockCrossingMidnightRoundTripsInUTC() throws {
        let utc = TimeZone(identifier: "UTC")!
        let day = timeFor("2026-06-12T12:00:00+00:00")   // noon UTC → UTC calendar day is the 12th
        var doc1 = MarkdownDoc(date: day)
        let start = timeFor("2026-06-12T23:00:00+00:00")
        let end = timeFor("2026-06-13T00:00:00+00:00")   // crosses UTC midnight
        doc1.appendTodo(Todo(id: "t_cross001", text: "late block", createdAt: day,
                             timeBlock: TimeBlock(start: start, end: end)))
        let text = doc1.serialize(timezone: utc)
        let doc2 = try MarkdownDoc.parse(text, timezone: utc)
        let tb = try XCTUnwrap(doc2.tasks.first(where: { $0.id == "t_cross001" })?.timeBlock)
        XCTAssertEqual(tb.start, start, "start reconstructs unchanged")
        XCTAssertEqual(tb.end, end, "end rolls to next day, not back a day")
    }

    func testRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: "hello",
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_001")
        doc1.appendNote(text: "world",
                        at: timeFor("2026-05-08T08:15:00+10:00"),
                        id: "n_002")
        let serialized = doc1.serialize(timezone: tz)

        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 2)
        XCTAssertEqual(doc2.notes[0].id, "n_001")
        XCTAssertEqual(doc2.notes[0].text, "hello")
        XCTAssertEqual(doc2.notes[1].id, "n_002")
        XCTAssertEqual(doc2.notes[1].text, "world")
    }

    private func dateFor(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Australia/Sydney")
        return f.date(from: s)!
    }

    private func timeFor(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    func testNoteBodyContainingHashHashHashIsPreserved() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: "before\n### inline heading not a section\nafter",
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_x")
        let serialized = doc1.serialize(timezone: tz)
        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 1)
        XCTAssertEqual(doc2.notes[0].text,
                       "before\n### inline heading not a section\nafter")
    }

    func testTasksRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")

        doc.appendTodo(Todo(id: "t_001", text: "first", createdAt: now))
        doc.appendTodo(Todo(id: "t_002", text: "second",
                            createdAt: now,
                            done: true,
                            completedAt: timeFor("2026-05-08T09:30:00+10:00")))
        doc.appendTodo(Todo(id: "t_003", text: "future",
                            createdAt: now,
                            dueDate: dateFor("2026-05-09")))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("- [ ] first <!-- id:t_001"))
        XCTAssertTrue(serialized.contains("- [x] second <!-- id:t_002"))
        XCTAssertTrue(serialized.contains("due:2026-05-09"))

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 3)
        XCTAssertEqual(parsed.tasks[0].id, "t_001")
        XCTAssertFalse(parsed.tasks[0].done)
        XCTAssertEqual(parsed.tasks[0].createdAt.timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(parsed.tasks[1].id, "t_002")
        XCTAssertTrue(parsed.tasks[1].done)
        XCTAssertNotNil(parsed.tasks[1].completedAt)
        XCTAssertEqual(parsed.tasks[2].dueDate.flatMap(dateOnlyString), "2026-05-09")
    }

    // IN-01: task text containing the comment delimiters must not corrupt the round-trip.
    func testTaskTextWithCommentDelimitersDoesNotCorruptRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        // A calendar-sourced title (via SC4 sync) could carry these delimiters.
        doc.appendTodo(Todo(id: "t_x", text: "plan <!-- secret --> review", createdAt: now))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)

        // The metadata still parses cleanly (id survives, exactly one task).
        XCTAssertEqual(parsed.tasks.count, 1)
        let task = try XCTUnwrap(parsed.tasks.first)
        XCTAssertEqual(task.id, "t_x", "metadata boundary must not be shifted by delimiters in text")
        // Cluster 1 / INFO: ONLY the comment-open `<!--` is neutralized (it is the
        // sole sequence that can forge the ` <!-- ` metadata boundary). The
        // comment-close `-->` cannot collide (the meta region begins only AFTER
        // the real ` <!-- `), so it is preserved rather than mangled to `->`.
        XCTAssertFalse(task.text.contains("<!--"), "comment-open delimiter must be neutralized")
        XCTAssertTrue(task.text.contains("-->"), "comment-close delimiter is preserved (never collides)")
        XCTAssertEqual(task.text, "plan <!- secret --> review",
                       "only the ambiguous <!-- open is altered; the rest of the text is intact")
    }

    // Cluster 1 / INFO: a lone `-->` (the common typed arrow, e.g. calendar
    // titles synced via SC4) must round-trip BYTE-IDENTICAL. It never collides
    // with the metadata boundary, so the old blanket `-->`->`->` rewrite was
    // pure, irreversible data loss on every serialize.
    func testTaskTextWithArrowRoundTripsFaithfully() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let text = "deploy step 2 --> production, then --> done"
        doc.appendTodo(Todo(id: "t_arrow", text: text, createdAt: now))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let task = try XCTUnwrap(parsed.tasks.first)
        XCTAssertEqual(task.id, "t_arrow", "metadata boundary intact with arrows in text")
        XCTAssertEqual(task.text, text, "--> arrows in task text must round-trip intact")
    }

    private func dateOnlyString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Australia/Sydney")
        return f.string(from: d)
    }

    // Phase 5 plan 01: time:HH:MM-HH:MM serializes and re-parses to the same
    // wall-clock start/end on the doc's date.
    func testTimeBlockRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_001", text: "deep work", createdAt: now,
                            timeBlock: tb))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("time:08:00-09:30"),
                      "serialized line should carry time:08:00-09:30")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let parsedTB = try XCTUnwrap(parsed.tasks[0].timeBlock)
        XCTAssertEqual(parsedTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(parsedTB.end.timeIntervalSince1970,
                       tb.end.timeIntervalSince1970, accuracy: 1.0)
    }

    // Phase 5 plan 01: cal_event:<id> serializes and re-parses to the identical id.
    func testCalEventRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_001", text: "linked", createdAt: now,
                            calEventID: "ABC123:DEF456"))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("cal_event:ABC123:DEF456"),
                      "serialized line should carry cal_event:ABC123:DEF456")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].calEventID, "ABC123:DEF456")
    }

    // Phase 5 plan 01: done + due + rolled_to + source_note + time + cal_event
    // all together round-trip with no token clobbering another.
    func testAllTokensRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_777", text: "everything", createdAt: now,
                            done: true,
                            completedAt: timeFor("2026-05-08T10:00:00+10:00"),
                            dueDate: dateFor("2026-05-09"),
                            rolledTo: dateFor("2026-05-10"),
                            sourceNote: "n_042",
                            timeBlock: tb,
                            calEventID: "EVT:9001"))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_777")
        XCTAssertEqual(t.text, "everything")
        XCTAssertTrue(t.done)
        XCTAssertNotNil(t.completedAt)
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(t.rolledTo.flatMap(dateOnlyString), "2026-05-10")
        XCTAssertEqual(t.sourceNote, "n_042")
        let allTB = try XCTUnwrap(t.timeBlock)
        XCTAssertEqual(allTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(allTB.end.timeIntervalSince1970,
                       tb.end.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(t.calEventID, "EVT:9001")
    }

    // WR-04: a hand-edited `- [X]` (uppercase — standard in hand-edited markdown and
    // many editors' checkbox toggles) must parse as DONE. The old lowercase-only
    // comparison parsed it as not-done, and the next re-serialize silently rewrote
    // the user's completion state as `- [ ]`.
    func testUppercaseXParsesAsDoneAndSurvivesRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let handEdited = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [X] hand-completed <!-- id:t_upper created:2026-05-08T07:30:00+10:00 -->

        ## Notes

        """
        let parsed = try MarkdownDoc.parse(handEdited, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertTrue(parsed.tasks[0].done, "uppercase [X] must parse as done")

        // Round-trip: the re-serialized doc must keep the task completed
        // (normalized to the canonical lowercase form), never un-complete it.
        let reserialized = parsed.serialize(timezone: tz)
        XCTAssertTrue(reserialized.contains("- [x] hand-completed"),
                      "re-serialize must preserve completion, not rewrite [X] as [ ]")
        let reparsed = try MarkdownDoc.parse(reserialized, timezone: tz)
        XCTAssertTrue(reparsed.tasks[0].done)
    }

    // Phase 5 plan 01: a legacy task line WITHOUT time:/cal_event: still parses
    // (new fields nil) — back-compat with pre-Phase-5 files. Includes a
    // createdAt-based line to protect Phase 2.5 leftover detection.
    func testLegacyTaskLineParsesWithNilCalendarFields() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let legacy = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] old task <!-- id:t_legacy created:2026-05-08T07:30:00+10:00 due:2026-05-09 rolled_to:2026-05-10 source_note:n_001 -->

        ## Notes

        """
        let parsed = try MarkdownDoc.parse(legacy, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_legacy")
        XCTAssertNil(t.timeBlock, "legacy line has no time: -> timeBlock nil")
        XCTAssertNil(t.calEventID, "legacy line has no cal_event: -> calEventID nil")
        // Phase 2.5 createdAt-based detection still resolves the original created date.
        XCTAssertEqual(t.createdAt.timeIntervalSince1970,
                       timeFor("2026-05-08T07:30:00+10:00").timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(t.rolledTo.flatMap(dateOnlyString), "2026-05-10")
        XCTAssertEqual(t.sourceNote, "n_001")
    }

    // Phase 5 plan 01 / T-5-01: a calEventID containing whitespace must NOT be
    // written as a token (would split into a bogus token and corrupt the line).
    func testCalEventWithWhitespaceIsNotSerialized() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_001", text: "spaced id", createdAt: now,
                            calEventID: "BAD ID 123"))
        let serialized = doc.serialize(timezone: tz)
        XCTAssertFalse(serialized.contains("cal_event:"),
                       "a whitespace-bearing event id must be skipped, not corrupt the line")
        // The line must still be well-formed and re-parse.
        XCTAssertNoThrow(try MarkdownDoc.parse(serialized, timezone: tz))
    }

    // Phase 7 plan 01 / SC2: source:<sourceID:itemID> + source_url:<link> serialize
    // and re-parse to the identical values (provenance round-trip for accepted inbox items).
    func testSourceTokensRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_inbox", text: "review PR", createdAt: now,
                            source: "github:123",
                            sourceURL: "https://github.com/o/r/issues/1"))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("source:github:123"),
                      "serialized line should carry source:github:123")
        XCTAssertTrue(serialized.contains("source_url:https://github.com/o/r/issues/1"),
                      "serialized line should carry the source_url: token")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].source, "github:123")
        XCTAssertEqual(parsed.tasks[0].sourceURL, "https://github.com/o/r/issues/1")
    }

    // Phase 7 plan 01 / SC2: an old daily file WITHOUT source/source_url tokens parses
    // to a Todo whose source and sourceURL are nil (backward compatibility).
    func testLegacyTaskLineParsesWithNilSourceFields() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let legacy = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] old task <!-- id:t_legacy created:2026-05-08T07:30:00+10:00 cal_event:EVT:1 -->

        ## Notes

        """
        let parsed = try MarkdownDoc.parse(legacy, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_legacy")
        XCTAssertNil(t.source, "legacy line has no source: -> source nil")
        XCTAssertNil(t.sourceURL, "legacy line has no source_url: -> sourceURL nil")
        // Pre-existing token on the same legacy line must still parse.
        XCTAssertEqual(t.calEventID, "EVT:1")
    }

    // Phase 7 plan 01 / T-7-01: a sourceURL containing whitespace must NOT be written
    // into the meta line (would split into a bogus token and corrupt the round-trip),
    // mirroring the cal_event: whitespace guard.
    func testSourceURLWithWhitespaceIsNotSerialized() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_002", text: "bad url", createdAt: now,
                            source: "github:9",
                            sourceURL: "https://x.com/a b c"))
        let serialized = doc.serialize(timezone: tz)
        XCTAssertFalse(serialized.contains("source_url:"),
                       "a whitespace-bearing source_url must be skipped, not corrupt the line")
        // source: (space-free) is still written; the line must re-parse cleanly.
        XCTAssertTrue(serialized.contains("source:github:9"))
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].source, "github:9")
        XCTAssertNil(parsed.tasks[0].sourceURL,
                     "whitespace-bearing url was dropped -> sourceURL nil on parse")
    }

    // Phase 7 plan 01: source/source_url coexist with created + cal_event + time on the
    // same meta line and all round-trip with no token clobbering another.
    func testSourceTokensCoexistWithOtherTokens() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_mix", text: "mixed", createdAt: now,
                            timeBlock: tb,
                            calEventID: "EVT:7",
                            source: "github:42",
                            sourceURL: "https://github.com/o/r/pull/42"))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_mix")
        XCTAssertEqual(t.calEventID, "EVT:7")
        XCTAssertEqual(t.source, "github:42")
        XCTAssertEqual(t.sourceURL, "https://github.com/o/r/pull/42")
        let mixTB = try XCTUnwrap(t.timeBlock)
        XCTAssertEqual(mixTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
    }

    // Phase 8 plan 01 / CALX-02: recur:<rule> serializes and re-parses to the
    // identical Recurrence (template token round-trip).
    func testRecurDailyRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_r1", text: "standup", createdAt: now,
                            recur: .daily))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("recur:daily"),
                      "serialized line should carry recur:daily")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].recur, .daily)
    }

    // Phase 8 plan 01 / CALX-02: custom weekday sets serialize as a stable
    // SORTED csv so the round-trip is deterministic.
    func testRecurCustomRoundTripsWithStableSortedCSV() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_r2", text: "gym", createdAt: now,
                            recur: .custom([5, 1, 3])))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("recur:custom:1,3,5"),
                      "custom csv must serialize sorted ascending")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].recur, .custom([1, 3, 5]))
    }

    // Phase 8 plan 01 / CALX-02: recur_src:<templateId>:<yyyy-MM-dd> (the
    // idempotency marker on instances) round-trips verbatim.
    func testRecurSrcRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_r3", text: "instance", createdAt: now,
                            recurSrc: "t_abc123:2026-06-14"))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("recur_src:t_abc123:2026-06-14"),
                      "serialized line should carry the recur_src marker")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].recurSrc, "t_abc123:2026-06-14")
    }

    // Phase 8 plan 01 / CALX-03: snooze:<yyyy-MM-dd> round-trips via the
    // dateOnly formatter, identical to due: handling.
    func testSnoozeRoundTrip() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_s1", text: "later", createdAt: now,
                            snooze: dateFor("2026-05-15")))

        let serialized = doc.serialize(timezone: tz)
        XCTAssertTrue(serialized.contains("snooze:2026-05-15"),
                      "serialized line should carry snooze:2026-05-15")

        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].snooze.flatMap(dateOnlyString), "2026-05-15")
    }

    // Phase 8 plan 01: an old daily file WITHOUT recur/recur_src/snooze tokens
    // parses to nil for all three (backward compatibility).
    func testLegacyTaskLineParsesWithNilRecurrenceFields() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let legacy = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] old task <!-- id:t_legacy created:2026-05-08T07:30:00+10:00 due:2026-05-09 cal_event:EVT:1 -->

        ## Notes

        """
        let parsed = try MarkdownDoc.parse(legacy, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertNil(t.recur, "legacy line has no recur: -> recur nil")
        XCTAssertNil(t.recurSrc, "legacy line has no recur_src: -> recurSrc nil")
        XCTAssertNil(t.snooze, "legacy line has no snooze: -> snooze nil")
        // Pre-existing tokens on the same legacy line must still parse.
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(t.calEventID, "EVT:1")
    }

    // Phase 8 plan 01 / T-8-01: all three new tokens coexist with EVERY existing
    // token on one meta line and each field round-trips (additive-not-breaking
    // regression guard: the space-split meta line is not corrupted).
    func testRecurrenceTokensCoexistWithAllExistingTokens() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_all", text: "everything", createdAt: now,
                            dueDate: dateFor("2026-05-09"),
                            timeBlock: tb,
                            calEventID: "EVT:7",
                            source: "github:42",
                            sourceURL: "https://github.com/o/r/pull/42",
                            recur: .custom([2, 4]),
                            recurSrc: "t_tmpl99:2026-05-08",
                            snooze: dateFor("2026-05-12")))

        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        let t = parsed.tasks[0]
        XCTAssertEqual(t.id, "t_all")
        XCTAssertEqual(t.text, "everything")
        XCTAssertEqual(t.createdAt.timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(t.dueDate.flatMap(dateOnlyString), "2026-05-09")
        let allTB = try XCTUnwrap(t.timeBlock)
        XCTAssertEqual(allTB.start.timeIntervalSince1970,
                       tb.start.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(allTB.end.timeIntervalSince1970,
                       tb.end.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(t.calEventID, "EVT:7")
        XCTAssertEqual(t.source, "github:42")
        XCTAssertEqual(t.sourceURL, "https://github.com/o/r/pull/42")
        XCTAssertEqual(t.recur, .custom([2, 4]))
        XCTAssertEqual(t.recurSrc, "t_tmpl99:2026-05-08")
        XCTAssertEqual(t.snooze.flatMap(dateOnlyString), "2026-05-12")
    }

    // Phase 8 plan 01 / T-8-01: a whitespace-bearing recurSrc must NOT be written
    // into the meta line (would split into a bogus token), mirroring the
    // cal_event:/source_url: guards.
    func testRecurSrcWithWhitespaceIsNotSerialized() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_bad", text: "bad marker", createdAt: now,
                            recur: .daily,
                            recurSrc: "t_x 2026-05-08"))
        let serialized = doc.serialize(timezone: tz)
        XCTAssertFalse(serialized.contains("recur_src:"),
                       "a whitespace-bearing recur_src must be skipped, not corrupt the line")
        // recur: (space-free) is still written; the line must re-parse cleanly.
        XCTAssertTrue(serialized.contains("recur:daily"))
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.tasks[0].recur, .daily)
        XCTAssertNil(parsed.tasks[0].recurSrc,
                     "whitespace-bearing marker was dropped -> recurSrc nil on parse")
    }

    // Cluster 1 / CRITICAL: a note body containing a blank line followed by an
    // ordinary markdown H3 (`\n\n### Heading`) must round-trip intact. The old
    // terminator `(?=\n\n### |\z)` mistook ANY blank-line+H3 for the next note
    // header and silently truncated the body -> permanent data loss on save.
    func testNoteBodyWithBlankLineThenHeadingRoundTrips() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let body = "intro paragraph\n\n### Section Heading\n\nmore body text"
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: body,
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_hdr")
        let serialized = doc1.serialize(timezone: tz)
        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 1)
        XCTAssertEqual(doc2.notes[0].text, body,
                       "blank-line + non-header H3 inside a note must not truncate the body")
    }

    // A blank-line + H3 that IS followed by a real note header must still split
    // into two notes (regression guard for the tightened terminator).
    func testTwoNotesWithHeadingInFirstBodyStillSplit() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendNote(text: "first note\n\n### inner heading\ntail",
                        at: timeFor("2026-05-08T07:30:00+10:00"),
                        id: "n_a")
        doc1.appendNote(text: "second note",
                        at: timeFor("2026-05-08T08:15:00+10:00"),
                        id: "n_b")
        let serialized = doc1.serialize(timezone: tz)
        let doc2 = try MarkdownDoc.parse(serialized, timezone: tz)
        XCTAssertEqual(doc2.notes.count, 2)
        XCTAssertEqual(doc2.notes[0].text, "first note\n\n### inner heading\ntail")
        XCTAssertEqual(doc2.notes[1].text, "second note")
    }

    // Cluster 1 / WARNING: a daily file saved with CRLF line endings must parse
    // its NOTES as well as its tasks. The note header regex requires `-->\n`
    // (LF only); before normalization a CRLF file lost every note while tasks
    // survived. parse() must normalize \r\n and lone \r to \n up front.
    func testCRLFLineEndingsParseNotesAndTasks() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let now = timeFor("2026-05-08T07:30:00+10:00")
        var doc1 = MarkdownDoc(date: dateFor("2026-05-08"))
        doc1.appendTodo(Todo(id: "t_crlf", text: "ship it", createdAt: now))
        doc1.appendNote(text: "a crlf note", at: now, id: "n_crlf")
        let lf = doc1.serialize(timezone: tz)
        // Simulate a Windows / CRLF-saved daily file.
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        let doc2 = try MarkdownDoc.parse(crlf, timezone: tz)
        XCTAssertEqual(doc2.tasks.count, 1, "tasks must survive CRLF")
        XCTAssertEqual(doc2.tasks[0].id, "t_crlf")
        XCTAssertEqual(doc2.notes.count, 1, "notes must survive CRLF (regression)")
        XCTAssertEqual(doc2.notes[0].id, "n_crlf")
        XCTAssertEqual(doc2.notes[0].text, "a crlf note",
                       "normalized body must not carry stray \\r")
    }
}
