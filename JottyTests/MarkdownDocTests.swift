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

    // WR-04 / I6 + phase 10-02 lossless contract: a hand-edited `- [X]` (uppercase,
    // standard in hand-edited markdown and many editors' checkbox toggles) must
    // parse as DONE. Under the lossless byte-stable round-trip an UNTOUCHED `[X]`
    // line is reused VERBATIM — it stays `- [X]` (NOT normalized to `[x]`) because
    // value-equality keeps the captured originalText. Canonical `[x]` normalization
    // happens ONLY when the line is actually mutated (P-Churn / I6). This replaces
    // the pre-phase-10 assertion that a plain parse->serialize normalized `[X]`->`[x]`.
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

        // No-mutation round-trip: the untouched `[X]` line is byte-stable — it
        // stays `- [X]` verbatim (lossless), never rewritten, and still done==true.
        let reserialized = parsed.serialize(timezone: tz)
        XCTAssertTrue(reserialized.contains("- [X] hand-completed"),
                      "an untouched [X] stays [X] byte-stable (lossless), never rewritten")
        XCTAssertFalse(reserialized.contains("- [x] hand-completed"),
                       "no canonical [x] normalization on a no-op round-trip")
        let reparsed = try MarkdownDoc.parse(reserialized, timezone: tz)
        XCTAssertTrue(reparsed.tasks[0].done)

        // Mutation path: renaming the task forces a canonical re-render, and the
        // state normalizes to the canonical lowercase `[x]` (done is preserved).
        // So normalization happens on mutation ONLY.
        var mutated = parsed
        mutated.tasks[0].text = "hand-completed and edited"
        let remutated = mutated.serialize(timezone: tz)
        XCTAssertTrue(remutated.contains("- [x] hand-completed and edited"),
                      "a MUTATED line re-renders to canonical [x] (normalization on mutation only)")
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

    // MARK: - Phase 10-01: span model + line-tokenizer parse

    /// Coalesce consecutive `raw` runs so tests assert the ORDER of span classes
    /// without pinning exact raw-run boundaries (finalized in plan 02). Distinct
    /// Jotty spans (taskLine/note/frontmatter) are always kept individually.
    private func compressedKinds(_ doc: MarkdownDoc) -> [String] {
        var out: [String] = []
        for k in doc.spanKindsForTesting {
            if k == "raw", out.last == "raw" { continue }
            out.append(k)
        }
        return out
    }

    /// Pull the ordered TaskSpans out of a parsed doc's skeleton.
    private func taskSpans(_ doc: MarkdownDoc) -> [TaskSpan] {
        doc.spans.compactMap { if case let .taskLine(ts) = $0 { return ts } else { return nil } }
    }

    /// Pull the ordered NoteSpans out of a parsed doc's skeleton.
    private func noteSpans(_ doc: MarkdownDoc) -> [NoteSpan] {
        doc.spans.compactMap { if case let .note(ns) = $0 { return ns } else { return nil } }
    }

    private func rawTexts(_ doc: MarkdownDoc) -> [String] {
        doc.spans.compactMap { if case let .raw(s) = $0 { return s } else { return nil } }
    }

    // A canonical Jotty file classifies into ordered spans and populates the
    // flat tasks/notes projections in span order.
    func testParseBuildsOrderedSpansForCanonicalFile() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T09:12:33+10:00
        ---

        ## Tasks

        - [x] ship PR <!-- id:t_a created:2026-05-08T09:20:00+10:00 -->
        - [ ] call bank <!-- id:t_b created:2026-05-08T10:00:00+10:00 -->

        ## Notes

        ### 09:30 <!-- id:n_1 -->
        standup notes
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)

        XCTAssertEqual(compressedKinds(doc),
                       ["frontmatter", "raw", "taskLine", "taskLine", "raw", "note"],
                       "document order must be captured, not discarded")
        XCTAssertEqual(doc.tasks.count, 2)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_a", "t_b"], "projection kept in span order")
        XCTAssertEqual(doc.notes.count, 1)
        XCTAssertEqual(doc.notes[0].id, "n_1")
    }

    // P-Foreign: a plain checkbox WITHOUT a Jotty id (or with an empty id) is a
    // raw span — never adopted, never assigned an id, never in tasks.
    func testForeignCheckboxIsRawAndNotAdopted() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] buy milk
        - [x] no id here <!-- created:2026-05-08T00:00:00+10:00 -->
        - [ ] real one <!-- id:t_real created:2026-05-08T00:00:00+10:00 -->
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)

        XCTAssertEqual(doc.tasks.map(\.id), ["t_real"],
                       "only the id-bearing Jotty line is a task")
        XCTAssertFalse(doc.tasks.contains { $0.id.isEmpty }, "no empty-id task ever adopted")
        let raws = rawTexts(doc).joined(separator: "\n")
        XCTAssertTrue(raws.contains("- [ ] buy milk"), "foreign checkbox preserved as raw")
        XCTAssertTrue(raws.contains("- [x] no id here"),
                      "empty-id checkbox (comment but no id) is raw, mirroring the L255 guard")
    }

    // SC3 capture half: an unrecognized key:value token on a recognized Jotty
    // task line is captured verbatim into TaskSpan.unknownTokens, not discarded.
    func testUnknownTaskTokenIsCaptured() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [x] ship PR <!-- id:t_a created:2026-05-08T09:20:00+10:00 priority:high -->
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)

        let spans = taskSpans(doc)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].unknownTokens, ["priority:high"],
                       "unknown token captured verbatim (SC3 capture)")
        XCTAssertEqual(spans[0].pristine.id, "t_a")
        XCTAssertTrue(spans[0].pristine.done, "recognized fields still parse correctly")
        XCTAssertEqual(spans[0].pristine.createdAt.timeIntervalSince1970,
                       timeFor("2026-05-08T09:20:00+10:00").timeIntervalSince1970,
                       accuracy: 1.0)
        // The flat projection agrees with the span's pristine Todo.
        XCTAssertEqual(doc.tasks.first, spans[0].pristine)
    }

    // I7: missing frontmatter date still throws (Store quarantine unchanged) —
    // but a valid-date file whose body is foreign prose + H1 + H2 now parses
    // (foreign -> raw spans) instead of throwing (the I7 bar rises).
    func testMissingDateThrowsButForeignBodyParses() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let noDate = """
        ---
        created: 2026-05-08T00:00:00+10:00
        ---

        # Journal
        """
        XCTAssertThrowsError(try MarkdownDoc.parse(noDate, timezone: tz),
                             "missing frontmatter date must still throw (I7)")

        let foreign = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        tags: [daily, work]
        ---

        # Journal
        woke up late, coffee first.

        ## Retro
        - learned spans
        """
        var parsed: MarkdownDoc?
        XCTAssertNoThrow(parsed = try MarkdownDoc.parse(foreign, timezone: tz),
                         "valid-date foreign file must parse to raw spans, not throw")
        let doc = try XCTUnwrap(parsed)
        XCTAssertTrue(doc.tasks.isEmpty, "no Jotty tasks in a foreign file")
        XCTAssertTrue(doc.notes.isEmpty, "no Jotty notes in a foreign file")
        let raws = rawTexts(doc).joined(separator: "\n")
        XCTAssertTrue(raws.contains("# Journal"), "foreign H1 preserved as raw")
        XCTAssertTrue(raws.contains("## Retro"), "foreign H2 preserved as raw")
        XCTAssertTrue(raws.contains("tags: [daily, work]") || {
            if case let .frontmatter(fm) = doc.spans.first { return fm.originalBlock.contains("tags:") }
            return false
        }(), "unknown frontmatter key survives (in frontmatter block or raw)")
    }

    // I2 + Obsidian-fixture regression: a non-note `### heading` inside a note
    // body stays in the body; a trailing `## ` H2 terminates the note so it is
    // its own raw span (NOT swallowed into the last note body).
    func testNoteTerminatorAnchoredToHeaderOrH2Boundary() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Notes

        ### 09:30 <!-- id:n_1 -->
        standup notes
        ### inner heading
        more notes

        ## Retro
        - learned spans
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)

        XCTAssertEqual(doc.notes.count, 1)
        XCTAssertEqual(doc.notes[0].text, "standup notes\n### inner heading\nmore notes",
                       "non-note ### heading stays inside the body (I2)")
        XCTAssertFalse(doc.notes[0].text.contains("Retro"),
                       "a trailing ## H2 must terminate the note, not be swallowed")
        let raws = rawTexts(doc).joined(separator: "\n")
        XCTAssertTrue(raws.contains("## Retro"), "## Retro is its own raw span")
        XCTAssertTrue(raws.contains("- learned spans"))
        // The note span's originalText carries the header verbatim.
        let ns = try XCTUnwrap(noteSpans(doc).first)
        XCTAssertTrue(ns.originalText.hasPrefix("### 09:30 <!-- id:n_1 -->"))
    }

    // Parse-side invariants survive at the projection level under the tokenizer.
    func testTokenizerPreservesParseInvariants() throws {
        let utc = TimeZone(identifier: "UTC")!
        // I3: midnight-crossing time block reconstructs end = start + 1 day.
        // I8: malformed recur degrades to nil (and is NOT captured as unknown).
        // I6: uppercase [X] parses done == true.
        let file = """
        ---
        date: 2026-06-12
        created: 2026-06-12T00:00:00+00:00
        ---

        ## Tasks

        - [X] cross <!-- id:t_x created:2026-06-12T00:00:00+00:00 time:23:00-00:00 recur:garbage -->
        """
        let doc = try MarkdownDoc.parse(file, timezone: utc)
        XCTAssertEqual(doc.tasks.count, 1)
        let t = doc.tasks[0]
        XCTAssertTrue(t.done, "uppercase [X] parses as done (I6)")
        let tb = try XCTUnwrap(t.timeBlock)
        XCTAssertEqual(tb.end.timeIntervalSince(tb.start), 3600, accuracy: 1.0,
                       "23:00-00:00 reconstructs end = start + 1h across midnight (I3)")
        XCTAssertNil(t.recur, "malformed recur degrades to nil (I8)")
        let ts = try XCTUnwrap(taskSpans(doc).first)
        XCTAssertEqual(ts.unknownTokens, [],
                       "recur:garbage is a RECOGNIZED key -> nil, never captured as unknown")
    }

    // MARK: - Phase 10-01 Task 2: projection-parity regression sweep

    // Linchpin of this plan: because parse keeps the tasks/notes projections
    // byte-identical AND serialize is untouched, a Jotty-serialized file
    // round-trips byte-identically through parse -> serialize (projections drive
    // the unchanged canonical rebuild). If the tokenizer perturbed a projection,
    // this idempotence would break.
    func testParseThenOldSerializeIsByteStableForCanonicalFile() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_1", text: "first", createdAt: now))
        doc.appendTodo(Todo(id: "t_2", text: "second", createdAt: now,
                            done: true, completedAt: now,
                            dueDate: dateFor("2026-05-09")))
        doc.appendNote(text: "a note", at: now, id: "n_1")
        let canonical = doc.serialize(timezone: tz)

        let parsed = try MarkdownDoc.parse(canonical, timezone: tz)
        XCTAssertEqual(parsed.serialize(timezone: tz), canonical,
                       "parse -> old serialize must stay byte-identical (projection parity)")
        // The projections themselves match the source doc field-for-field.
        XCTAssertEqual(parsed.tasks, doc.tasks)
        XCTAssertEqual(parsed.notes, doc.notes)
    }

    // A legacy line carrying only recognized tokens parses with the optional
    // fields nil AND an EMPTY unknownTokens (the default: branch never
    // over-captures a token it actually recognizes).
    func testLegacyRecognizedOnlyLineHasEmptyUnknownTokens() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] plain <!-- id:t_plain created:2026-05-08T07:30:00+10:00 -->
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)
        let ts = try XCTUnwrap(taskSpans(doc).first)
        XCTAssertEqual(ts.unknownTokens, [], "recognized-only line captures nothing unknown")
        XCTAssertNil(ts.pristine.timeBlock)
        XCTAssertNil(ts.pristine.recur)
        XCTAssertNil(ts.pristine.source)
    }

    // A line mixing recognized tokens AND an unknown priority:high yields the
    // correct Todo fields AND unknownTokens == ["priority:high"] — recognized
    // tokens NEVER leak into unknownTokens.
    func testMixedTokensCaptureOnlyTheUnknownOne() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [x] mixed <!-- id:t_m created:2026-05-08T07:30:00+10:00 due:2026-05-09 priority:high cal_event:EVT:7 -->
        """
        let doc = try MarkdownDoc.parse(file, timezone: tz)
        let ts = try XCTUnwrap(taskSpans(doc).first)
        XCTAssertEqual(ts.unknownTokens, ["priority:high"],
                       "only the unrecognized token is captured; recognized tokens never leak")
        XCTAssertTrue(ts.pristine.done)
        XCTAssertEqual(ts.pristine.dueDate.flatMap(dateOnlyString), "2026-05-09")
        XCTAssertEqual(ts.pristine.calEventID, "EVT:7")
    }

    // Every recognized token present at once -> unknownTokens stays EMPTY (the
    // strong no-over-capture guard across the full token vocabulary).
    func testEveryRecognizedTokenYieldsEmptyUnknownTokens() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        let tb = TimeBlock(start: timeFor("2026-05-08T08:00:00+10:00"),
                           end: timeFor("2026-05-08T09:30:00+10:00"))
        doc.appendTodo(Todo(id: "t_all", text: "everything", createdAt: now,
                            done: true, completedAt: now,
                            dueDate: dateFor("2026-05-09"),
                            rolledTo: dateFor("2026-05-10"),
                            sourceNote: "n_042",
                            timeBlock: tb,
                            calEventID: "EVT:7",
                            source: "github:42",
                            sourceURL: "https://github.com/o/r/pull/42",
                            recur: .custom([2, 4]),
                            recurSrc: "t_tmpl99:2026-05-08",
                            snooze: dateFor("2026-05-12")))
        let serialized = doc.serialize(timezone: tz)
        let parsed = try MarkdownDoc.parse(serialized, timezone: tz)
        let ts = try XCTUnwrap(taskSpans(parsed).first)
        XCTAssertEqual(ts.unknownTokens, [],
                       "a line built from ONLY recognized tokens captures nothing unknown")
    }

    // MARK: - Phase 10-02 Task 1: span-aware serialize (canonicalSynthesize + reconcile walk)

    /// A hand-written day file exercising every preservation class at once: an
    /// unknown frontmatter key, a foreign section + prose, a foreign checkbox,
    /// Jotty task lines (one carrying an unknown `priority:high` token), a note,
    /// and a trailing foreign `## Retro` section.
    private func losslessFixture() -> String {
        """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        custom_key: keep me
        ---

        # Journal

        Some prose here.

        ## Tasks

        - [ ] buy milk
        - [ ] jotty one <!-- id:t_a created:2026-05-08T07:30:00+10:00 -->
        - [x] jotty two <!-- id:t_b created:2026-05-08T07:30:00+10:00 done:2026-05-08T09:00:00+10:00 priority:high -->

        ## Notes

        ### 07:30 <!-- id:n_1 -->
        first note

        ## Retro

        trailing foreign section
        """
    }

    /// Indices of lines that differ between two multi-line strings.
    private func lineDiffIndices(_ a: String, _ b: String) -> [Int] {
        let la = a.components(separatedBy: "\n")
        let lb = b.components(separatedBy: "\n")
        var diffs: [Int] = []
        for i in 0..<max(la.count, lb.count) {
            let x = i < la.count ? la[i] : nil
            let y = i < lb.count ? lb[i] : nil
            if x != y { diffs.append(i) }
        }
        return diffs
    }

    // SC1: parse a canonical file carrying foreign content, serialize with NO
    // mutation -> byte-identical (reconcile reuses originalText/originalBlock for
    // every span; the "\n" join reinserts the line-boundary newlines).
    func testUntouchedRoundTripIsByteStable() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        let parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        XCTAssertEqual(parsed.serialize(timezone: tz), fixture,
                       "untouched parse->serialize must be byte-identical (SC1)")
    }

    // SC2: toggling one task's done touches ONLY that task's line; frontmatter
    // (incl. custom_key + created:), every other task, the foreign checkbox, and
    // the note stay byte-identical to the input.
    func testToggleTouchesOnlyThatTaskLine() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        let idx = try XCTUnwrap(parsed.tasks.firstIndex(where: { $0.id == "t_a" }))
        parsed.tasks[idx].done = true
        parsed.tasks[idx].completedAt = timeFor("2026-05-08T10:15:00+10:00")
        let out = parsed.serialize(timezone: tz)
        let diffs = lineDiffIndices(fixture, out)
        XCTAssertEqual(diffs.count, 1, "only the toggled task line differs")
        let changed = out.components(separatedBy: "\n")[diffs[0]]
        XCTAssertTrue(changed.contains("- [x] jotty one"), "state flips to [x]")
        XCTAssertTrue(changed.contains("done:"), "done: token added on mutation")
    }

    // P-Churn: a hand-reordered-but-semantically-identical Jotty line (tokens in
    // a non-canonical order) is reused VERBATIM on a no-mutation round-trip
    // (value-equality is true, so no canonical rewrite / no churn).
    func testHandReorderedTokensReusedVerbatim() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let file = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] reordered <!-- created:2026-05-08T07:30:00+10:00 id:t_r due:2026-05-09 -->
        """
        let parsed = try MarkdownDoc.parse(file, timezone: tz)
        XCTAssertEqual(parsed.serialize(timezone: tz), file,
                       "a semantically-identical hand-reorder must round-trip verbatim (P-Churn)")
    }

    // SC3: renaming a task carrying an unknown `priority:high` token re-renders
    // the line canonically AND re-emits priority:high verbatim before ` -->`.
    func testRenameReRendersAndReEmitsUnknownToken() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        let idx = try XCTUnwrap(parsed.tasks.firstIndex(where: { $0.id == "t_b" }))
        parsed.tasks[idx].text = "renamed jotty two"
        let out = parsed.serialize(timezone: tz)
        XCTAssertTrue(out.contains("- [x] renamed jotty two <!-- id:t_b"),
                      "renamed line re-renders canonically")
        XCTAssertTrue(out.contains("priority:high -->"),
                      "unknown token re-emitted verbatim before the closing -->")
        XCTAssertFalse(out.contains("- [x] jotty two <!--"),
                       "old text gone from the re-rendered line")
    }

    // P-Delete: deleting a Jotty task omits its line (and its single terminating
    // newline); the foreign checkbox, the other Jotty task, and the note stay
    // byte-identical.
    func testDeleteOmitsOnlyThatLine() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.tasks.removeAll { $0.id == "t_a" }
        let out = parsed.serialize(timezone: tz)
        let expected = fixture.components(separatedBy: "\n")
            .filter { $0 != "- [ ] jotty one <!-- id:t_a created:2026-05-08T07:30:00+10:00 -->" }
            .joined(separator: "\n")
        XCTAssertEqual(out, expected,
                       "deleting t_a removes exactly its line; all else byte-identical (P-Delete)")
    }

    // SC4 / P-Insert: appendTodo into a parsed doc injects the new task line
    // immediately after the LAST existing Jotty task line, inside `## Tasks`.
    // The output is the fixture with EXACTLY that one line spliced in -> every
    // foreign span (# Journal, buy milk, ## Retro) is byte-identical and unmoved.
    func testAppendTaskInjectsAfterLastTaskWithoutMovingForeign() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.appendTodo(Todo(id: "t_new", text: "new task",
                               createdAt: timeFor("2026-05-08T11:00:00+10:00")))
        let out = parsed.serialize(timezone: tz)

        let newLine = "- [ ] new task <!-- id:t_new created:2026-05-08T11:00:00+10:00 -->"
        var lines = fixture.components(separatedBy: "\n")
        let anchor = try XCTUnwrap(lines.firstIndex(where: { $0.contains("id:t_b") }))
        lines.insert(newLine, at: anchor + 1)
        XCTAssertEqual(out, lines.joined(separator: "\n"),
                       "new task lands after the last Jotty task line; foreign byte-identical (SC4)")

        // Injected id is now a real span; foreign content survives a re-parse.
        let reparsed = try MarkdownDoc.parse(out, timezone: tz)
        XCTAssertEqual(reparsed.tasks.map(\.id), ["t_a", "t_b", "t_new"])
        XCTAssertTrue(out.contains("- [ ] buy milk"), "foreign checkbox preserved")
        XCTAssertTrue(out.contains("## Retro"), "trailing foreign section preserved")
    }

    // SC4: appendNote injects a new note block into `## Notes` after the last
    // existing note; the trailing foreign `## Retro` section is not moved.
    func testAppendNoteInjectsIntoNotesRegionWithoutMovingForeign() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = losslessFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.appendNote(text: "second note",
                          at: timeFor("2026-05-08T08:15:00+10:00"), id: "n_2")
        let out = parsed.serialize(timezone: tz)

        XCTAssertTrue(out.contains("### 08:15 <!-- id:n_2 -->\nsecond note"),
                      "new note rendered canonically in the ## Notes region")
        let iN1 = try XCTUnwrap(out.range(of: "id:n_1"))
        let iN2 = try XCTUnwrap(out.range(of: "id:n_2"))
        let iRetro = try XCTUnwrap(out.range(of: "## Retro"))
        XCTAssertTrue(iN1.lowerBound < iN2.lowerBound, "new note after existing note")
        XCTAssertTrue(iN2.lowerBound < iRetro.lowerBound, "new note before foreign ## Retro")

        let reparsed = try MarkdownDoc.parse(out, timezone: tz)
        XCTAssertEqual(reparsed.notes.map(\.id), ["n_1", "n_2"])
        XCTAssertTrue(out.contains("trailing foreign section"), "foreign tail preserved")
    }

    // SC4 / P-Insert: appendTodo into a parsed foreign doc with NO `## Tasks`
    // region synthesizes the header at the canonical position (after frontmatter,
    // before the foreign body) and places the new line there; foreign unmoved.
    func testAppendTaskSynthesizesTasksHeaderWhenAbsent() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let foreign = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        # Journal
        some prose
        """
        var parsed = try MarkdownDoc.parse(foreign, timezone: tz)
        parsed.appendTodo(Todo(id: "t_new", text: "task",
                               createdAt: timeFor("2026-05-08T11:00:00+10:00")))
        let out = parsed.serialize(timezone: tz)

        let expected = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] task <!-- id:t_new created:2026-05-08T11:00:00+10:00 -->

        # Journal
        some prose
        """
        XCTAssertEqual(out, expected,
                       "## Tasks synthesized after frontmatter, before foreign body; foreign preserved")
        let reparsed = try MarkdownDoc.parse(out, timezone: tz)
        XCTAssertEqual(reparsed.tasks.map(\.id), ["t_new"])
    }

    // SC5 fresh leg: a fresh MarkdownDoc(date:) has NO spans -> canonicalSynthesize;
    // its output is a fixed point of the reconcile walk (parse->serialize == synth).
    func testFreshSynthesisIsAReconcileFixedPoint() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        var doc = MarkdownDoc(date: dateFor("2026-05-08"))
        let now = timeFor("2026-05-08T07:30:00+10:00")
        doc.appendTodo(Todo(id: "t_1", text: "first", createdAt: now))
        doc.appendNote(text: "hello", at: now, id: "n_1")
        let synth = doc.serialize(timezone: tz)
        let reparsed = try MarkdownDoc.parse(synth, timezone: tz)
        XCTAssertEqual(reparsed.serialize(timezone: tz), synth,
                       "canonicalSynthesize output round-trips byte-identically through the walk")
    }

    // MARK: - Phase 10-03: acceptance suite (byte-stable property + Obsidian fixture + matrix)

    /// The LOCKED Obsidian-style acceptance fixture (10-03 interfaces block). One
    /// hand-written day file exercising every loss class at once: unknown
    /// frontmatter keys (`tags`, multi-line `aliases`), a real non-midnight
    /// `created:` (09:12:33), a `# Journal` foreign H1 + prose, a `## Tasks`
    /// mixing a foreign `- [ ]` checkbox (no id) with two Jotty tasks (t_a done +
    /// carrying `priority:high`, t_b open), a note whose body contains a non-note
    /// `### inner heading`, and a trailing foreign `## Retro` section. Distinct
    /// from `losslessFixture()` (there priority:high rides the OPEN task; here it
    /// rides the DONE task t_a, the frontmatter is multi-line, and n_1's body
    /// carries the inner heading — stressing frontmatter + note-terminator reuse).
    private func obsidianFixture() -> String {
        """
        ---
        date: 2026-05-08
        created: 2026-05-08T09:12:33+10:00
        tags: [daily, work]
        aliases:
          - eight-may
        ---

        # Journal
        woke up late, coffee first.

        ## Tasks

        - [ ] buy milk
        - [x] ship PR <!-- id:t_a created:2026-05-08T09:20:00+10:00 priority:high -->
        - [ ] call bank <!-- id:t_b created:2026-05-08T10:00:00+10:00 -->

        ## Notes

        ### 09:30 <!-- id:n_1 -->
        standup notes
        ### inner heading
        more notes

        ## Retro
        - learned spans
        """
    }

    /// Foreign lines that MUST stay byte-identical across every mutation of the
    /// Obsidian fixture (P-Foreign + document order preservation).
    private let obsidianForeignLines = [
        "# Journal", "woke up late, coffee first.",
        "- [ ] buy milk", "## Retro", "- learned spans",
    ]

    /// A canonical Jotty corpus fixture (full token set). Round-trips byte-stable
    /// because reconcile reuses each span's captured bytes on a no-op serialize.
    private func canonicalCorpusFixture() -> String {
        """
        ---
        date: 2026-05-08
        created: 2026-05-08T09:00:00+10:00
        ---

        ## Tasks

        - [x] full <!-- id:t_c created:2026-05-08T07:30:00+10:00 done:2026-05-08T09:00:00+10:00 due:2026-05-09 time:08:00-09:30 cal_event:EVT:7 source:github:42 recur:daily -->

        ## Notes

        ### 07:30 <!-- id:n_c -->
        canonical note body
        """
    }

    /// A legacy corpus fixture: NO time/cal/source/recur tokens (pre-Phase-5
    /// shape). Guards back-compat byte-stability.
    private func legacyCorpusFixture() -> String {
        """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] legacy one <!-- id:t_l1 created:2026-05-08T07:30:00+10:00 due:2026-05-09 -->
        - [x] legacy two <!-- id:t_l2 created:2026-05-08T08:00:00+10:00 -->

        ## Notes

        ### 08:15 <!-- id:n_l -->
        legacy note
        """
    }

    // SC1 acceptance property: for a CORPUS of inputs with NO model mutation,
    // `parse(text).serialize(tz)` is byte-identical to the expected LF form. The
    // corpus is {canonical, legacy, Obsidian} asserted verbatim, plus a CRLF
    // fixture (built from canonical) asserted against the LF-normalized form (I1:
    // a CRLF input round-trips as LF — the documented contract). No such
    // multi-fixture byte-equality property existed before this plan.
    func testRoundTripByteStable_Corpus() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let lfCorpus: [(String, String)] = [
            ("canonical", canonicalCorpusFixture()),
            ("legacy", legacyCorpusFixture()),
            ("obsidian", obsidianFixture()),
        ]
        for (name, text) in lfCorpus {
            let out = try MarkdownDoc.parse(text, timezone: tz).serialize(timezone: tz)
            XCTAssertEqual(out, text, "\(name): untouched parse->serialize must be byte-identical (SC1)")
        }
        // CRLF leg (I1): the same bytes with \n->\r\n must round-trip to the LF form.
        let canonical = canonicalCorpusFixture()
        let crlf = canonical.replacingOccurrences(of: "\n", with: "\r\n")
        let crlfOut = try MarkdownDoc.parse(crlf, timezone: tz).serialize(timezone: tz)
        XCTAssertEqual(crlfOut, canonical, "CRLF input round-trips as the LF-normalized form (I1)")
    }

    // SC1/P-Foreign: the Obsidian fixture parses to Jotty content ONLY — the two
    // id-bearing lines are tasks, the note is n_1, and the foreign `- [ ] buy
    // milk` checkbox is never adopted.
    func testObsidianFixtureParsesJottyContentOnly() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let doc = try MarkdownDoc.parse(obsidianFixture(), timezone: tz)
        XCTAssertEqual(doc.tasks.map(\.id), ["t_a", "t_b"], "only id-bearing lines are tasks")
        XCTAssertEqual(doc.notes.map(\.id), ["n_1"], "the single Jotty note is n_1")
        XCTAssertFalse(doc.tasks.contains { $0.text == "buy milk" },
                       "foreign checkbox excluded from tasks (P-Foreign)")
        XCTAssertEqual(doc.notes[0].text, "standup notes\n### inner heading\nmore notes",
                       "inner ### heading stays in the note body; ## Retro not swallowed (I2)")
    }

    // SC3: the unknown `priority:high` token on t_a survives a no-op round-trip
    // (captured at parse, re-emitted verbatim) and stays on the t_a line.
    func testObsidianFixtureUnknownTokenSurvives() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let out = try MarkdownDoc.parse(obsidianFixture(), timezone: tz).serialize(timezone: tz)
        XCTAssertTrue(out.contains("priority:high"), "unknown token re-emitted (SC3)")
        let taLine = try XCTUnwrap(out.components(separatedBy: "\n").first { $0.contains("id:t_a") })
        XCTAssertTrue(taLine.contains("priority:high"), "priority:high stays on the t_a line")
    }

    // L1/L2: unknown frontmatter keys (`tags`, multi-line `aliases`) AND the real
    // non-midnight `created:` (09:12:33, NOT a midnight re-derivation from `date`)
    // survive verbatim — the frontmatter originalBlock is reused, never rebuilt.
    func testObsidianFixtureUnknownFrontmatterSurvives() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let out = try MarkdownDoc.parse(obsidianFixture(), timezone: tz).serialize(timezone: tz)
        XCTAssertTrue(out.contains("tags: [daily, work]"), "unknown scalar-list key survives (L1)")
        XCTAssertTrue(out.contains("aliases:\n  - eight-may"), "multi-line unknown key survives (L1)")
        XCTAssertTrue(out.contains("created: 2026-05-08T09:12:33+10:00"),
                      "real created: instant preserved, not re-derived to midnight (L2)")
    }

    // L8/I2: the trailing foreign `## Retro` / `- learned spans` block is emitted
    // byte-identical at the document tail (NOT swallowed into n_1's body).
    func testObsidianFixtureTrailingSectionSurvives() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let out = try MarkdownDoc.parse(obsidianFixture(), timezone: tz).serialize(timezone: tz)
        XCTAssertTrue(out.hasSuffix("## Retro\n- learned spans"),
                      "trailing foreign section survives byte-identical at the tail (L8/I2)")
    }

    /// Assert every foreign line of the Obsidian fixture is present byte-identical
    /// AND in original relative order in `out` (P-Foreign + order preservation).
    private func assertObsidianForeignSurvives(_ out: String, _ msg: String) {
        var cursor = out.startIndex
        for line in obsidianForeignLines {
            guard let r = out.range(of: line, range: cursor..<out.endIndex) else {
                XCTFail("\(msg): foreign line missing or out of order: \(line)")
                return
            }
            cursor = r.upperBound
        }
    }

    // MATRIX / SC2: toggling t_b done touches ONLY t_b's line; t_a (with
    // priority:high), the foreign checkbox, # Journal, n_1 and ## Retro are all
    // byte-identical and in order.
    func testObsidianToggleTBTouchesOnlyThatLine() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        let idx = try XCTUnwrap(parsed.tasks.firstIndex(where: { $0.id == "t_b" }))
        parsed.tasks[idx].done = true
        parsed.tasks[idx].completedAt = timeFor("2026-05-08T11:00:00+10:00")
        let out = parsed.serialize(timezone: tz)
        let diffs = lineDiffIndices(fixture, out)
        XCTAssertEqual(diffs.count, 1, "only t_b's line differs")
        let changed = out.components(separatedBy: "\n")[diffs[0]]
        XCTAssertTrue(changed.contains("- [x] call bank") && changed.contains("done:"),
                      "t_b flips to [x] with a done: token")
        XCTAssertTrue(out.contains("id:t_a created:2026-05-08T09:20:00+10:00 priority:high"),
                      "t_a line (incl priority:high) untouched")
        assertObsidianForeignSurvives(out, "toggle t_b")
    }

    // MATRIX / SC3: renaming t_a re-renders its line canonically and re-emits its
    // unknown priority:high token; only t_a's line differs; foreign survives.
    func testObsidianRenameTAKeepsPriorityHigh() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        let idx = try XCTUnwrap(parsed.tasks.firstIndex(where: { $0.id == "t_a" }))
        parsed.tasks[idx].text = "ship the release"
        let out = parsed.serialize(timezone: tz)
        let diffs = lineDiffIndices(fixture, out)
        XCTAssertEqual(diffs.count, 1, "only t_a's line differs")
        XCTAssertTrue(out.contains("- [x] ship the release <!-- id:t_a"), "renamed canonically")
        XCTAssertTrue(out.contains("priority:high -->"), "priority:high re-emitted (SC3)")
        assertObsidianForeignSurvives(out, "rename t_a")
    }

    // MATRIX / SC2+SC3: rolling t_a (set rolledTo) re-renders ONLY t_a with a
    // rolled_to: token while its priority:high still survives; foreign untouched.
    // (New mutation class not exercised elsewhere.)
    func testObsidianRollTARewritesOnlyThatLine() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        let idx = try XCTUnwrap(parsed.tasks.firstIndex(where: { $0.id == "t_a" }))
        parsed.tasks[idx].rolledTo = dateFor("2026-05-09")
        let out = parsed.serialize(timezone: tz)
        let diffs = lineDiffIndices(fixture, out)
        XCTAssertEqual(diffs.count, 1, "only t_a's line differs on roll")
        let changed = out.components(separatedBy: "\n")[diffs[0]]
        XCTAssertTrue(changed.contains("rolled_to:2026-05-09"), "rolled_to: token added")
        XCTAssertTrue(changed.contains("priority:high"), "priority:high survives the roll (SC3)")
        assertObsidianForeignSurvives(out, "roll t_a")
    }

    // MATRIX / SC4: appendTodo splices the new line AFTER the last Jotty task
    // (t_b) and BEFORE `## Notes`; the output is the fixture with exactly that one
    // line inserted (foreign byte-identical, unmoved).
    func testObsidianAppendTodoInjectsAfterLastTask() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.appendTodo(Todo(id: "t_new", text: "new task",
                               createdAt: timeFor("2026-05-08T12:00:00+10:00")))
        let out = parsed.serialize(timezone: tz)
        let newLine = "- [ ] new task <!-- id:t_new created:2026-05-08T12:00:00+10:00 -->"
        var lines = fixture.components(separatedBy: "\n")
        let anchor = try XCTUnwrap(lines.firstIndex(where: { $0.contains("id:t_b") }))
        lines.insert(newLine, at: anchor + 1)
        XCTAssertEqual(out, lines.joined(separator: "\n"),
                       "new task lands after t_b; everything else byte-identical (SC4)")
    }

    // MATRIX / SC4: appendNote injects a new block into `## Notes` after n_1 and
    // BEFORE the trailing foreign `## Retro`; foreign survives, order preserved.
    func testObsidianAppendNoteInjectsBeforeRetro() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.appendNote(text: "second note",
                          at: timeFor("2026-05-08T10:30:00+10:00"), id: "n_2")
        let out = parsed.serialize(timezone: tz)
        XCTAssertTrue(out.contains("### 10:30 <!-- id:n_2 -->\nsecond note"),
                      "new note rendered canonically in ## Notes")
        let iN1 = try XCTUnwrap(out.range(of: "id:n_1"))
        let iN2 = try XCTUnwrap(out.range(of: "id:n_2"))
        let iRetro = try XCTUnwrap(out.range(of: "## Retro"))
        XCTAssertTrue(iN1.lowerBound < iN2.lowerBound && iN2.lowerBound < iRetro.lowerBound,
                      "n_2 sits after n_1 and before foreign ## Retro")
        assertObsidianForeignSurvives(out, "append note")
        XCTAssertEqual(try MarkdownDoc.parse(out, timezone: tz).notes.map(\.id), ["n_1", "n_2"])
    }

    // MATRIX / P-Delete: deleting t_a omits exactly its line; the foreign checkbox
    // above it, t_b, n_1 and ## Retro are byte-identical (fixture minus one line).
    func testObsidianDeleteTARemovesOnlyThatLine() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = obsidianFixture()
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.tasks.removeAll { $0.id == "t_a" }
        let out = parsed.serialize(timezone: tz)
        let expected = fixture.components(separatedBy: "\n")
            .filter { !$0.contains("id:t_a") }
            .joined(separator: "\n")
        XCTAssertEqual(out, expected, "only t_a's line removed; all else byte-identical (P-Delete)")
        assertObsidianForeignSurvives(out, "delete t_a")
    }

    // MATRIX / SC4: appendTodo to a file with NO `## Tasks` region synthesizes the
    // header at the canonical position (after frontmatter, before the foreign
    // body) while the foreign `# Journal` prose, a foreign checkbox, and a
    // trailing `## Retro` are all left in place, byte-identical.
    func testObsidianAppendTodoToNoTasksFile() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let noTasks = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        # Journal
        some prose
        - [ ] foreign box

        ## Retro
        - learned spans
        """
        var parsed = try MarkdownDoc.parse(noTasks, timezone: tz)
        parsed.appendTodo(Todo(id: "t_new", text: "task",
                               createdAt: timeFor("2026-05-08T11:00:00+10:00")))
        let out = parsed.serialize(timezone: tz)
        let expected = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] task <!-- id:t_new created:2026-05-08T11:00:00+10:00 -->

        # Journal
        some prose
        - [ ] foreign box

        ## Retro
        - learned spans
        """
        XCTAssertEqual(out, expected,
                       "## Tasks synthesized after frontmatter; foreign prose/box/Retro unmoved (SC4)")
    }

    // P-Delete spacing: deleting the MIDDLE of three Jotty tasks removes exactly
    // its line — the foreign checkbox, the surrounding tasks, and the blank-line
    // count do NOT drift.
    func testDeleteMiddleTaskKeepsForeignSpacing() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let fixture = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks

        - [ ] one <!-- id:t_1 created:2026-05-08T07:00:00+10:00 -->
        - [ ] two <!-- id:t_2 created:2026-05-08T07:00:00+10:00 -->
        - [ ] three <!-- id:t_3 created:2026-05-08T07:00:00+10:00 -->
        - [ ] foreign box

        ## Notes
        """
        var parsed = try MarkdownDoc.parse(fixture, timezone: tz)
        parsed.tasks.removeAll { $0.id == "t_2" }
        let out = parsed.serialize(timezone: tz)
        let expected = fixture.components(separatedBy: "\n")
            .filter { !$0.contains("id:t_2") }
            .joined(separator: "\n")
        XCTAssertEqual(out, expected, "middle task removed; foreign box + spacing intact (P-Delete)")
        let blanksIn = fixture.components(separatedBy: "\n").filter { $0.isEmpty }.count
        let blanksOut = out.components(separatedBy: "\n").filter { $0.isEmpty }.count
        XCTAssertEqual(blanksIn, blanksOut, "blank-line count must not drift on a middle delete")
        XCTAssertTrue(out.contains("- [ ] foreign box"), "foreign checkbox byte-identical")
    }

    // SC5 / I7: a file whose frontmatter `date` is PRESENT but not a valid
    // calendar date still throws from parse — Store sidecars it unchanged. The
    // quarantine bar is date-scoped, not content-scoped.
    func testQuarantineThrowsOnInvalidFrontmatterDate() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let invalid = """
        ---
        date: 2026-13-40
        created: 2026-05-08T00:00:00+10:00
        ---

        ## Tasks
        """
        XCTAssertThrowsError(try MarkdownDoc.parse(invalid, timezone: tz),
                             "an invalid frontmatter date must still throw (I7 quarantine)")
    }

    // SC5 / I7 bar rises: a VALID-date file whose body is otherwise foreign/garbage
    // now PARSES (garbage -> raw spans) instead of throwing, and round-trips
    // byte-stable — so it reaches the model, never the corrupt sidecar.
    func testValidDateForeignHeavyFileParses() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let garbage = """
        ---
        date: 2026-05-08
        created: 2026-05-08T00:00:00+10:00
        ---

        !!! not markdown ###
        <html>oops</html>
        - [ ] orphan checkbox
        random | table | row
        > a blockquote
        """
        var doc: MarkdownDoc?
        XCTAssertNoThrow(doc = try MarkdownDoc.parse(garbage, timezone: tz),
                         "valid-date foreign-heavy body parses, never quarantined")
        let parsed = try XCTUnwrap(doc)
        XCTAssertTrue(parsed.tasks.isEmpty && parsed.notes.isEmpty, "no Jotty content in garbage")
        XCTAssertEqual(parsed.serialize(timezone: tz), garbage,
                       "garbage body captured as raw spans round-trips byte-identical")
    }

}
