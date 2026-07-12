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
}
