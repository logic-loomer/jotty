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
        let event = CalendarEvent(id: "ev1", title: "Standup",
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
        let event = CalendarEvent(id: "ev1", title: "Standup",
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
}
