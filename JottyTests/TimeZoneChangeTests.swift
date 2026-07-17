import XCTest
@testable import Jotty

/// Roadmap 3.3 — timezone semantics. Design note:
/// brain/projects/jotty/2026-07-12-timezone-semantics-design.md
/// Reviewed 2026-07-12: the monitor reports the zone PAIR (not a scalar offset
/// delta measured at one instant) because a block's re-anchor shift depends on
/// the offsets AT THE BLOCK'S DATE — a Sydney→LA move shifts a July block by
/// −17h but an October block by −18h (Sydney springs forward Oct 4 first), and
/// Brisbane→Sydney is a zero-delta "silent" change in July that still shifts
/// every post-Oct-4 block by +1h.
final class TimeZoneChangeTests: XCTestCase {
    let sydney = TimeZone(identifier: "Australia/Sydney")!
    let brisbane = TimeZone(identifier: "Australia/Brisbane")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    /// Offset-IDENTICAL to Sydney at every instant (same AEST/AEDT rules) — the
    /// canonical "identifier changed but nothing shifts" silent-rebuild case.
    let melbourne = TimeZone(identifier: "Australia/Melbourne")!

    private func makeDate(_ y: Int, _ mo: Int, _ d: Int, h: Int = 0, m: Int = 0,
                          tz: TimeZone? = nil) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = m
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? sydney
        return cal.date(from: comps)!
    }

    // MARK: - Pure decision (TimeZoneMonitor.decision)

    /// Same zone identifier (spurious notification) → no action. DST fires no
    /// zone-change notification, and wall-clock tokens are DST-agnostic anyway.
    func testSameIdentifierIsNoChange() {
        XCTAssertEqual(TimeZoneMonitor.decision(active: sydney, current: sydney), .none)
    }

    /// ANY identifier change reports the zone pair — even Brisbane → Sydney,
    /// which is offset-identical in July but shifts every post-DST block by
    /// +1h. Whether to prompt is decided downstream per-block by the
    /// partition, never by a single-instant offset comparison (review F2).
    func testIdentifierChangeReportsZonePair() {
        XCTAssertEqual(TimeZoneMonitor.decision(active: brisbane, current: sydney),
                       .zoneChanged(from: brisbane, to: sydney))
        XCTAssertEqual(TimeZoneMonitor.decision(active: sydney, current: losAngeles),
                       .zoneChanged(from: sydney, to: losAngeles))
    }

    // MARK: - Observer wiring

    /// Posting NSSystemTimeZoneDidChange drives the callback with the decision
    /// computed from the injected closures — no singletons, test-swappable.
    func testMonitorFiresCallbackOnNotification() {
        let center = NotificationCenter()
        var reportedCurrent = sydney
        var decisions: [TimeZoneMonitor.Decision] = []

        let monitor = TimeZoneMonitor(
            notificationCenter: center,
            activeTZ: { self.sydney },
            currentTZ: { reportedCurrent },
            onChange: { decisions.append($0) }
        )

        withExtendedLifetime(monitor) {
            // Spurious: same zone → callback suppressed entirely.
            center.post(name: .NSSystemTimeZoneDidChange, object: nil)
            XCTAssertTrue(decisions.isEmpty)

            // Real move: Sydney → LA.
            reportedCurrent = losAngeles
            center.post(name: .NSSystemTimeZoneDidChange, object: nil)
            XCTAssertEqual(decisions, [.zoneChanged(from: sydney, to: losAngeles)])
        }
    }

    /// A deallocated monitor must not keep observing (review F1: deinit was
    /// removing the observer from NotificationCenter.default instead of the
    /// injected center — the stale block kept firing with captured closures).
    func testDeallocatedMonitorStopsObserving() {
        let center = NotificationCenter()
        var decisions: [TimeZoneMonitor.Decision] = []

        var monitor: TimeZoneMonitor? = TimeZoneMonitor(
            notificationCenter: center,
            activeTZ: { self.sydney },
            currentTZ: { self.losAngeles },
            onChange: { decisions.append($0) }
        )
        _ = monitor
        monitor = nil

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertTrue(decisions.isEmpty,
                      "observer must be removed from the INJECTED center on deinit")
    }

    // MARK: - TZ-shift drift partition (pure, feeds the one-shot bulk prompt)

    private func pair(taskStart: Date, eventStart: Date, id: String = "t_1")
        -> (task: Todo, event: CalendarEvent) {
        var task = Todo(id: id, text: "x", createdAt: taskStart)
        task.timeBlock = TimeBlock(start: taskStart, end: taskStart.addingTimeInterval(1800))
        task.calEventID = "ev_\(id)"
        let event = CalendarEvent(eventKitID: "ev_\(id)", title: "x",
                                  start: eventStart, end: eventStart.addingTimeInterval(1800))
        return (task, event)
    }

    /// A drifted pair whose instant delta equals the zones' offset delta AT THE
    /// BLOCK'S DATE is TZ-shift drift (bulk prompt); anything else is genuine
    /// user drift (normal per-set prompt).
    func testPartitionSplitsTZShiftFromRealDrift() {
        let base = makeDate(2026, 7, 12, h: 9)
        let delta: TimeInterval = -61200 // Sydney(+10) → LA(−7) at a July date

        let shifted = pair(taskStart: base, eventStart: base.addingTimeInterval(delta), id: "t_tz")
        let userMoved = pair(taskStart: base, eventStart: base.addingTimeInterval(7200), id: "t_user")

        let result = CalendarDrift.partitionForTZShift([shifted, userMoved],
                                                       from: sydney, to: losAngeles)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_tz"])
        XCTAssertEqual(result.other.map(\.task.id), ["t_user"])
    }

    /// Review F2, failure 1: the delta must be computed per-block. A far-future
    /// block sitting between the two zones' DST transitions (Sydney springs
    /// forward Oct 4; LA falls back Nov 1) shifts by −18h, not July's −17h —
    /// it must still classify as TZ-shift.
    func testPartitionUsesPerBlockDeltaAcrossDSTBoundary() {
        let octoberBlock = makeDate(2026, 10, 10, h: 9)   // AEDT +11, PDT −7 → −18h
        let perBlockDelta = TimeInterval(
            losAngeles.secondsFromGMT(for: octoberBlock) - sydney.secondsFromGMT(for: octoberBlock))
        XCTAssertEqual(perBlockDelta, -64800, "sanity: October Sydney→LA is −18h")

        let shifted = pair(taskStart: octoberBlock,
                           eventStart: octoberBlock.addingTimeInterval(perBlockDelta), id: "t_oct")
        let result = CalendarDrift.partitionForTZShift([shifted], from: sydney, to: losAngeles)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_oct"],
                       "far-future blocks must not fall into the per-pair drift storm")
    }

    /// Review F2, failure 2: Brisbane → Sydney is offset-identical at a July
    /// "now" but a post-Oct-4 block shifts +1h — the pair must be classified
    /// TZ-shift so the bulk prompt still covers it. A July block between the
    /// same zones has a per-block delta of zero → other (no false bulk-sync).
    func testPartitionBrisbaneToSydneyClassifiesOnlyPostDSTBlocks() {
        let julyBlock = makeDate(2026, 7, 12, h: 9)
        let octoberBlock = makeDate(2026, 10, 10, h: 9)

        // July: same offset → any drift is genuine user drift.
        let julyMoved = pair(taskStart: julyBlock,
                             eventStart: julyBlock.addingTimeInterval(3600), id: "t_july")
        // October: Sydney is +1h ahead of Brisbane → re-anchor shifts −1h... measured
        // as event.start − block.start = to − from = +3600? No: instant = wall − offset,
        // so the new instant is EARLIER when the offset grows; the event stays put:
        // event.start − block.start_new = off_new − off_old = +3600.
        let octDelta = TimeInterval(
            sydney.secondsFromGMT(for: octoberBlock) - brisbane.secondsFromGMT(for: octoberBlock))
        XCTAssertEqual(octDelta, 3600)
        let octShifted = pair(taskStart: octoberBlock,
                              eventStart: octoberBlock.addingTimeInterval(octDelta), id: "t_oct")

        let result = CalendarDrift.partitionForTZShift([julyMoved, octShifted],
                                                       from: brisbane, to: sydney)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_oct"])
        XCTAssertEqual(result.other.map(\.task.id), ["t_july"])
    }

    /// The ±60s tolerance mirrors driftedTasks: within tolerance of the
    /// per-block delta is TZ-shift; beyond it is not.
    func testPartitionToleranceBoundary() {
        let base = makeDate(2026, 7, 12, h: 9)
        let delta: TimeInterval = -61200

        let justInside = pair(taskStart: base,
                              eventStart: base.addingTimeInterval(delta + 59), id: "t_in")
        let justOutside = pair(taskStart: base,
                               eventStart: base.addingTimeInterval(delta + 61), id: "t_out")

        let result = CalendarDrift.partitionForTZShift([justInside, justOutside],
                                                       from: sydney, to: losAngeles)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_in"])
        XCTAssertEqual(result.other.map(\.task.id), ["t_out"])
    }

    /// Identical zones (defensive) → per-block delta is always zero → nothing
    /// is TZ-shift; ordinary drift can never be silently bulk-synced.
    func testPartitionWithSameZoneClassifiesNothingAsTZShift() {
        let base = makeDate(2026, 7, 12, h: 9)
        let moved = pair(taskStart: base, eventStart: base.addingTimeInterval(3600), id: "t_m")
        let result = CalendarDrift.partitionForTZShift([moved], from: sydney, to: sydney)
        XCTAssertTrue(result.tzShift.isEmpty)
        XCTAssertEqual(result.other.map(\.task.id), ["t_m"])
    }

    /// A task without a time block cannot be TZ-shift-classified — falls through
    /// to `other` (defensive; driftedTasks shouldn't produce such pairs).
    func testPartitionPairWithoutTimeBlockFallsThrough() {
        let base = makeDate(2026, 7, 12, h: 9)
        var noBlock = pair(taskStart: base, eventStart: base.addingTimeInterval(-61200), id: "t_nb")
        noBlock.task.timeBlock = nil
        let result = CalendarDrift.partitionForTZShift([noBlock], from: sydney, to: losAngeles)
        XCTAssertTrue(result.tzShift.isEmpty)
        XCTAssertEqual(result.other.map(\.task.id), ["t_nb"])
    }

    // MARK: - Rebuild arm classification (roadmap 3.3 slice 2, Task 3 signal)

    /// The live-TZ rebuild ALWAYS runs on any identifier change, but it ARMS the
    /// one-shot bulk re-anchor prompt (Task 3) only when the wall-clock→UTC offset
    /// actually changes at the rebuild instant. Melbourne→Sydney is offset-identical
    /// at every instant, so it rebuilds SILENTLY (no arm) — the brief's canonical
    /// identifier-only case.
    func testMelbourneToSydneyRebuildDoesNotArmPrompt() {
        let now = makeDate(2026, 7, 12, h: 9)
        XCTAssertFalse(AppDelegate.shouldArmReanchorPrompt(from: melbourne, to: sydney, at: now),
                       "an offset-identical identifier change must rebuild silently")
    }

    /// A genuine offset change (Sydney→LA) arms the prompt.
    func testSydneyToLosAngelesRebuildArmsPrompt() {
        let now = makeDate(2026, 7, 12, h: 9)
        XCTAssertTrue(AppDelegate.shouldArmReanchorPrompt(from: sydney, to: losAngeles, at: now),
                      "a UTC-offset change must arm the bulk re-anchor prompt")
    }

    /// The arm decision is evaluated at the rebuild INSTANT (the sole decision
    /// point): Brisbane→Sydney is offset-identical in July (both +10, no arm) but
    /// differs after Oct 4 (Sydney +11 → arm). Mirrors the "offsets match now"
    /// discriminator the brief specifies for the coarse arm gate; the per-block
    /// partition (Task 3) still refines WHICH blocks are prompted.
    func testArmDecisionIsEvaluatedAtRebuildInstant() {
        let july = makeDate(2026, 7, 12, h: 9)
        let october = makeDate(2026, 10, 10, h: 9)
        XCTAssertFalse(AppDelegate.shouldArmReanchorPrompt(from: brisbane, to: sydney, at: july))
        XCTAssertTrue(AppDelegate.shouldArmReanchorPrompt(from: brisbane, to: sydney, at: october))
    }

    // MARK: - Live rebuild: render-only (zero bytes written)

    /// The rebuild is render-only: swapping the model's Store+timezone onto a NEW
    /// zone and reloading must not rewrite a single byte of a populated folder.
    /// History: a prior rollover feature destroyed data by acting automatically on
    /// re-anchored blocks — the rebuild only re-renders.
    @MainActor
    func testRebuildLeavesPopulatedFolderByteIdentical() throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 7, 12, h: 9)
        let prevDay = makeDate(2026, 7, 11, h: 8)
        let storeSyd = Store(folder: folder, timezone: sydney)
        var timed = Todo(id: "t_1", text: "standup", createdAt: day)
        timed.timeBlock = TimeBlock(start: makeDate(2026, 7, 12, h: 9),
                                    end: makeDate(2026, 7, 12, h: 9, m: 30))
        try storeSyd.appendCapture(noteText: "note body", noteId: "n_1",
                                   tasks: [timed, Todo(id: "t_2", text: "plain", createdAt: day)],
                                   at: day)
        try storeSyd.appendCapture(noteText: "", noteId: nil,
                                   tasks: [Todo(id: "t_0", text: "prev", createdAt: prevDay)],
                                   at: prevDay)

        let before = folderSnapshot(folder)

        let model = MenubarListModel(store: storeSyd, timezone: sydney,
                                     defaults: throwawayDefaults(), now: { day })
        model.replace(store: Store(folder: folder, timezone: losAngeles), timezone: losAngeles)

        XCTAssertEqual(folderSnapshot(folder), before,
                       "the timezone rebuild must write zero bytes to the populated folder")
    }

    /// A cross-midnight block (23:00–00:30) must survive the rebuild byte-identical
    /// — the day-qualified/rolled-end serialization is TZ-agnostic on disk.
    @MainActor
    func testCrossMidnightBlockSurvivesRebuildUnchanged() throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 7, 12, h: 12)
        let store = Store(folder: folder, timezone: sydney)
        var t = Todo(id: "t_x", text: "late night", createdAt: day)
        t.timeBlock = TimeBlock(start: makeDate(2026, 7, 12, h: 23),
                                end: makeDate(2026, 7, 13, h: 0, m: 30))
        try store.appendCapture(noteText: "", noteId: nil, tasks: [t], at: day)

        let before = folderSnapshot(folder)
        let model = MenubarListModel(store: store, timezone: sydney,
                                     defaults: throwawayDefaults(), now: { day })
        model.replace(store: Store(folder: folder, timezone: losAngeles), timezone: losAngeles)

        XCTAssertEqual(folderSnapshot(folder), before,
                       "cross-midnight block must survive the rebuild unchanged on disk")
    }

    // MARK: - Reparse under the new zone (the visible render shifts, disk does not)

    /// Reading the SAME day file under the rebuilt (new-zone) Store re-anchors the
    /// bare wall-clock `time:` token onto the new zone, so the parsed instant shifts
    /// by exactly the per-block offset delta — while the bytes on disk are untouched.
    func testReparsedBlockInstantShiftsByPerBlockDelta() throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 7, 12, h: 9)
        let store = Store(folder: folder, timezone: sydney)
        var t = Todo(id: "t_b", text: "standup", createdAt: day)
        t.timeBlock = TimeBlock(start: makeDate(2026, 7, 12, h: 9),
                                end: makeDate(2026, 7, 12, h: 9, m: 30))
        try store.appendCapture(noteText: "", noteId: nil, tasks: [t], at: day)

        let sydParsed = try XCTUnwrap(
            store.readDoc(on: day).tasks.first { $0.id == "t_b" }?.timeBlock?.start)

        // The rebuild renders through a new-zone Store on the SAME file (no write).
        let storeLA = Store(folder: folder, timezone: losAngeles)
        let laDay = makeDate(2026, 7, 12, h: 9, tz: losAngeles) // same file name under LA
        let laParsed = try XCTUnwrap(
            storeLA.readDoc(on: laDay).tasks.first { $0.id == "t_b" }?.timeBlock?.start)

        let expected = TimeInterval(sydney.secondsFromGMT(for: sydParsed)
                                    - losAngeles.secondsFromGMT(for: sydParsed))
        XCTAssertEqual(laParsed.timeIntervalSince(sydParsed), expected, accuracy: 1,
                       "the reparsed block instant must shift by the per-block zone delta")
        XCTAssertEqual(expected, 61200, "sanity: July Sydney→LA is +17h on reparse")
    }

    // MARK: - Date-line rollover robustness across a zone flip

    /// Date-line EAST (moving to a zone whose local date is BEHIND): the rollover
    /// state file holds a "future" day, so collect + instancing no-op until the
    /// local date catches up — a future-dated state must not re-collect or resurrect.
    func testDateLineEastRolloverNoOpsUntilLocalDateCatchesUp() throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let statePath = folder.appendingPathComponent("last-rollover.txt")
        let store = Store(folder: folder, timezone: sydney)

        let today = makeDate(2026, 7, 12)          // local "today" after moving west
        let futureDay = makeDate(2026, 7, 13, h: 8) // state says we already rolled ahead
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_future", text: "ahead", createdAt: futureDay)],
                                at: futureDay)
        try "2026-07-13".write(to: statePath, atomically: true, encoding: .utf8)

        let svc = RolloverService(store: store, statePath: statePath, timezone: sydney)
        try svc.run(now: today)

        // Nothing is pulled onto today; the future day's task is left untouched.
        let todayDoc = try store.readDoc(on: today)
        XCTAssertTrue(todayDoc.tasks.isEmpty, "a future-dated state must not collect anything onto today")
        let futureDoc = try store.readDoc(on: futureDay)
        XCTAssertEqual(futureDoc.tasks.map(\.id), ["t_future"])
        XCTAssertNil(futureDoc.tasks.first?.rolledTo, "the future day must not be stamped rolled")
    }

    /// Date-line WEST (moving to a zone whose local date is AHEAD): a local day is
    /// skipped, so rollover must catch up the skipped day AND be idempotent — a
    /// second run collects nothing new (id guards), never duplicating.
    func testDateLineWestRolloverReRunsIdempotently() throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let statePath = folder.appendingPathComponent("last-rollover.txt")
        let store = Store(folder: folder, timezone: sydney)

        let skipped = makeDate(2026, 7, 11, h: 9)  // a local day jumped over
        let today = makeDate(2026, 7, 12)
        try store.appendCapture(noteText: "", noteId: nil,
                                tasks: [Todo(id: "t_skip", text: "left over", createdAt: skipped)],
                                at: skipped)
        try "2026-07-10".write(to: statePath, atomically: true, encoding: .utf8)

        let svc = RolloverService(store: store, statePath: statePath, timezone: sydney)
        try svc.run(now: today)
        var todayDoc = try store.readDoc(on: today)
        XCTAssertEqual(todayDoc.tasks.filter { $0.id == "t_skip" }.count, 1,
                       "the skipped day's leftover must be caught up exactly once")

        // Idempotent re-run (same day): no duplication.
        try svc.run(now: today)
        todayDoc = try store.readDoc(on: today)
        XCTAssertEqual(todayDoc.tasks.filter { $0.id == "t_skip" }.count, 1,
                       "a same-day re-run must not duplicate the caught-up leftover")
    }

    // MARK: - Test helpers

    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeFolder(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A throwaway UserDefaults suite so the model's collapse-key housekeeping never
    /// touches (or is polluted by) the shared standard defaults.
    private func throwawayDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tzchange-\(UUID().uuidString)")!
    }

    /// Byte-exact snapshot of every regular file in `folder` (relative name → bytes),
    /// so a rebuild that rewrites even one byte fails the equality assertion.
    private func folderSnapshot(_ folder: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return out
        }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            out[url.lastPathComponent] = data
        }
        return out
    }
}
