import XCTest
@testable import Jotty

/// Phase 8 plan 05 / SC4 (CALX-04): the canvas VIEW MODEL — positioned blocks
/// (events + time-blocked tasks) composed via the pure `CanvasLayout` math, the
/// unscheduled-tasks rail, and drop-y → snapped-slot resolution. The model reads
/// the menubar model's already-fetched data (FakeCalendarService — the suite
/// never touches a real EKEventStore) and does no I/O of its own.
@MainActor
final class CalendarCanvasModelTests: XCTestCase {
    var folder: URL!
    var defaults: UserDefaults!
    var suiteName: String!
    let tz = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Positioned blocks (CanvasLayout composition)

    // A 09:00–10:00 event on a canvas whose dayStart is 00:00 at pph 60 sits at
    // y == 9*60 == 540 with height == 60 (composes CanvasLayout.y/height).
    func testEventBlockPositionedViaCanvasLayout() async throws {
        let now = makeDate(2026, 6, 12, h: 8)
        let event = CalendarEvent(eventKitID: "ev1", title: "Standup",
                                  start: makeDate(2026, 6, 12, h: 9),
                                  end: makeDate(2026, 6, 12, h: 10),
                                  calendarTitle: "Work")
        let canvas = try await makeCanvas(now: now, events: [event])

        XCTAssertEqual(canvas.blocks.count, 1)
        let block = try XCTUnwrap(canvas.blocks.first)
        XCTAssertEqual(block.kind, .event)
        XCTAssertEqual(block.title, "Standup")
        XCTAssertEqual(block.y, 540)
        XCTAssertEqual(block.height, 60)
    }

    // A time-blocked 14:00–14:30 task renders as a positioned block (y==840,
    // height==30) whose kind is DISTINCT from event blocks.
    func testTimeBlockedTaskBlockPositionedAndKindDistinct() async throws {
        let now = makeDate(2026, 6, 12, h: 8)
        let event = CalendarEvent(eventKitID: "ev1", title: "Standup",
                                  start: makeDate(2026, 6, 12, h: 9),
                                  end: makeDate(2026, 6, 12, h: 10),
                                  calendarTitle: nil)
        let blocked = Todo(id: "t_tb", text: "deep work", createdAt: now,
                           timeBlock: TimeBlock(start: makeDate(2026, 6, 12, h: 14),
                                                end: makeDate(2026, 6, 12, h: 14, min: 30)))
        let canvas = try await makeCanvas(now: now, events: [event], tasks: [blocked])

        XCTAssertEqual(canvas.blocks.count, 2)
        let taskBlock = try XCTUnwrap(canvas.blocks.first(where: { $0.kind == .task }))
        XCTAssertEqual(taskBlock.title, "deep work")
        XCTAssertEqual(taskBlock.y, 840)
        XCTAssertEqual(taskBlock.height, 30)
        let eventBlock = try XCTUnwrap(canvas.blocks.first(where: { $0.kind == .event }))
        XCTAssertNotEqual(taskBlock.kind, eventBlock.kind,
                          "task blocks must be distinguishable (by kind) from event blocks")
    }

    // Unscheduled tasks (timeBlock == nil) are the RAIL, never positioned blocks.
    func testUnscheduledTasksExposedAsRailNotPositioned() async throws {
        let now = makeDate(2026, 6, 12, h: 8)
        let unscheduled = Todo(id: "t_rail", text: "someday soon", createdAt: now)
        let blocked = Todo(id: "t_tb", text: "scheduled", createdAt: now,
                           timeBlock: TimeBlock(start: makeDate(2026, 6, 12, h: 11),
                                                end: makeDate(2026, 6, 12, h: 12)))
        let canvas = try await makeCanvas(now: now, tasks: [unscheduled, blocked])

        XCTAssertEqual(canvas.rail.map(\.id), ["t_rail"],
                       "only timeBlock==nil tasks belong in the rail")
        XCTAssertEqual(canvas.blocks.map(\.title), ["scheduled"],
                       "an unscheduled task must never appear as a positioned block")
    }

    // MARK: - Drop-slot resolution (CanvasLayout.slot delegation)

    // slot(atY:) delegates to CanvasLayout.slot with the model's own
    // dayStart/pph/snapMinutes: a drop y maps to the expected snapped Date.
    func testSlotDelegatesToCanvasLayout() async throws {
        let now = makeDate(2026, 6, 12, h: 8)
        let canvas = try await makeCanvas(now: now)

        XCTAssertEqual(canvas.pixelsPerHour, CanvasLayout.defaultPixelsPerHour)
        XCTAssertEqual(canvas.snapMinutes, CanvasLayout.defaultSnapMinutes)

        // Grid-aligned: y 540 at pph 60 is exactly 09:00.
        XCTAssertEqual(canvas.slot(atY: 540), makeDate(2026, 6, 12, h: 9, min: 0))
        // Off-grid: y 550 → 550 min → 09:10 → snaps to the nearest 15 (09:15).
        XCTAssertEqual(canvas.slot(atY: 550), makeDate(2026, 6, 12, h: 9, min: 15))
        // Byte-identical to calling the pure math directly (true delegation).
        XCTAssertEqual(canvas.slot(atY: 550),
                       CanvasLayout.slot(atY: 550, dayStart: canvas.dayStart,
                                         pixelsPerHour: canvas.pixelsPerHour,
                                         snapMinutes: canvas.snapMinutes))
    }

    // MARK: - dayStart derivation (tz-pinned)

    // dayStart == startOfDay(now()) in the MODEL timezone, so every block
    // position is tz-correct (an 09:00 Sydney event sits at y 540 regardless
    // of the machine's locale).
    func testDayStartDerivedFromNowInModelTimezone() async throws {
        let now = makeDate(2026, 6, 12, h: 8, min: 41)
        let canvas = try await makeCanvas(now: now)

        XCTAssertEqual(canvas.dayStart, makeDate(2026, 6, 12, h: 0, min: 0),
                       "dayStart must be startOfDay(now()) in the model timezone")
    }

    // MARK: - Helpers

    /// Builds a MenubarListModel over a temp Store + FakeCalendarService (canned
    /// events, no EKEventStore) with a FIXED now, awaits its calendar refresh so
    /// `calendarEvents` is populated, then wraps it in the canvas model.
    private func makeCanvas(now: Date,
                            events: [CalendarEvent] = [],
                            tasks: [Todo] = []) async throws -> CalendarCanvasModel {
        let store = Store(folder: folder, timezone: tz)
        if !tasks.isEmpty {
            try store.appendCapture(noteText: "", noteId: nil, tasks: tasks, at: now)
        }
        let fake = FakeCalendarService()
        fake.cannedEvents = events
        let list = MenubarListModel(store: store, timezone: tz,
                                    defaults: defaults, now: { now }, calendar: fake)
        await list.awaitCalendarRefresh()
        return CalendarCanvasModel(list: list)
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, h: Int = 12, min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Axis geometry: real-day span, wall-clock hour marks, now indicator

    func testAxisGeometryOnANormalDay() async throws {
        let canvas = try await makeCanvas(now: makeDate(2026, 6, 12, h: 8))
        XCTAssertEqual(canvas.axisHeight, 24 * canvas.pixelsPerHour)
        let marks = canvas.hourMarks
        XCTAssertEqual(marks.count, 25, "0…24 so the day is visibly closed")
        XCTAssertEqual(marks.first?.label, "00:00")
        XCTAssertEqual(marks.last?.label, "00:00")
        // On a plain 24h day the marks reduce to the old fixed spacing.
        XCTAssertEqual(marks.first { $0.idx == 9 }?.y, 9 * canvas.pixelsPerHour)
    }

    /// Sydney DST ENDS 2026-04-05 (3am → 2am): a 25-hour day. The axis must span
    /// the real day, and "09:00" sits at its PHYSICAL offset (10h after dayStart) —
    /// the old fixed `hour × scale` labels disagreed with the (physical, correct)
    /// drop-slot math by an hour after the transition, and the fixed 24h axis
    /// clipped the day's last hour entirely.
    func testAxisGeometryOnDSTFallBackDay() async throws {
        let canvas = try await makeCanvas(now: makeDate(2026, 4, 5, h: 12))
        XCTAssertEqual(canvas.axisHeight, 25 * canvas.pixelsPerHour, "a 25h day renders 25h tall")
        let nine = try XCTUnwrap(canvas.hourMarks.first { $0.idx == 9 })
        XCTAssertEqual(nine.y, 10 * canvas.pixelsPerHour,
                       "wall-clock 09:00 is 10 PHYSICAL hours after dayStart on the 25h day")
        // Cross-check with the inverse: a drop released exactly on the 09:00 line
        // resolves to wall-clock 09:00.
        XCTAssertEqual(canvas.slot(atY: nine.y), makeDate(2026, 4, 5, h: 9),
                       "hour label and drop-slot resolution agree on the DST day")
    }

    /// Sydney DST STARTS 2026-10-04 (2am → 3am): a 23-hour day. Wall-clock 02:00
    /// does not exist — no gridline for it (bySettingHour: 2 returns the 3am
    /// instant, which would otherwise render a phantom "02:00" on top of "03:00")
    /// — and the axis spans 23h.
    func testAxisGeometryOnDSTSpringForwardDay() async throws {
        let canvas = try await makeCanvas(now: makeDate(2026, 10, 4, h: 12))
        XCTAssertEqual(canvas.axisHeight, 23 * canvas.pixelsPerHour, "a 23h day renders 23h tall")
        XCTAssertNil(canvas.hourMarks.first { $0.idx == 2 },
                     "the skipped wall-clock hour draws no gridline")
        XCTAssertEqual(canvas.hourMarks.filter { $0.y == 2 * canvas.pixelsPerHour }.count, 1,
                       "exactly ONE mark at the 3am physical position — no overlapping labels")
        let nine = try XCTUnwrap(canvas.hourMarks.first { $0.idx == 9 })
        XCTAssertEqual(nine.y, 8 * canvas.pixelsPerHour,
                       "wall-clock 09:00 is 8 PHYSICAL hours after dayStart on the 23h day")
        XCTAssertEqual(canvas.slot(atY: nine.y), makeDate(2026, 10, 4, h: 9))
    }

    func testNowYTracksTheCurrentInstantAndNilsOutsideToday() async throws {
        let now = makeDate(2026, 6, 12, h: 9, min: 30)
        let canvas = try await makeCanvas(now: now)
        XCTAssertEqual(canvas.nowY(at: now), 9.5 * canvas.pixelsPerHour)
        XCTAssertNil(canvas.nowY(at: makeDate(2026, 6, 13, h: 1)), "tomorrow is off-axis")
        XCTAssertNil(canvas.nowY(at: makeDate(2026, 6, 11, h: 23)), "yesterday is off-axis")
    }

    func testScrollAnchorHourIsOneAboveNowClampedAtZero() async throws {
        let canvas = try await makeCanvas(now: makeDate(2026, 6, 12, h: 9, min: 30))
        XCTAssertEqual(canvas.scrollAnchorHour(at: makeDate(2026, 6, 12, h: 9, min: 30)), 8)
        XCTAssertEqual(canvas.scrollAnchorHour(at: makeDate(2026, 6, 12, h: 0, min: 20)), 0,
                       "clamped at the top of the axis")
    }
}
