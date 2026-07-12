import XCTest
@testable import Jotty

/// Roadmap 3.3 — timezone semantics. Design note:
/// brain/projects/jotty/2026-07-12-timezone-semantics-design.md
final class TimeZoneChangeTests: XCTestCase {
    let sydney = TimeZone(identifier: "Australia/Sydney")!
    let melbourne = TimeZone(identifier: "Australia/Melbourne")!
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

    /// Same zone identifier (spurious notification, DST transition) → no action.
    /// DST fires no zone-change notification, and even if something re-posts,
    /// wall-clock tokens are DST-agnostic by construction — never rebuild/prompt.
    func testSameIdentifierIsNoChange() {
        let now = makeDate(2026, 7, 12, h: 12)
        XCTAssertEqual(TimeZoneMonitor.decision(active: sydney, current: sydney, at: now),
                       .none)
    }

    /// Different identifier but identical current offset (Melbourne → Sydney):
    /// silent rebuild, no prompt — no instant moved.
    func testSameOffsetDifferentIdentifierIsSilentRebuild() {
        let now = makeDate(2026, 7, 12, h: 12)
        XCTAssertEqual(TimeZoneMonitor.decision(active: melbourne, current: sydney, at: now),
                       .silentRebuild)
    }

    /// Offset actually changed (Sydney winter +10 → LA −7): rebuild AND prompt,
    /// carrying the offset delta (new − old) the drift partition needs.
    func testOffsetChangeIsRebuildAndPrompt() {
        let now = makeDate(2026, 7, 12, h: 12)
        let expectedDelta = TimeInterval(losAngeles.secondsFromGMT(for: now)
            - sydney.secondsFromGMT(for: now))
        XCTAssertEqual(TimeZoneMonitor.decision(active: sydney, current: losAngeles, at: now),
                       .rebuildAndPrompt(offsetDelta: expectedDelta))
        XCTAssertEqual(expectedDelta, -61200) // −17h in July (AEST +10, PDT −7)
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
            now: { self.makeDate(2026, 7, 12, h: 12) },
            onChange: { decisions.append($0) }
        )
        _ = monitor

        // Spurious: same zone → callback suppressed entirely.
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertTrue(decisions.isEmpty)

        // Real move: Sydney → LA.
        reportedCurrent = losAngeles
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(decisions.count, 1)
        if case .rebuildAndPrompt = decisions[0] {} else {
            XCTFail("expected rebuildAndPrompt, got \(decisions[0])")
        }
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

    /// A drifted pair whose instant delta equals the zone-offset delta is
    /// TZ-shift drift (belongs in the single bulk prompt); anything else is
    /// genuine user drift (normal per-set prompt).
    func testPartitionSplitsTZShiftFromRealDrift() {
        let base = makeDate(2026, 7, 12, h: 9)
        let delta: TimeInterval = -61200 // Sydney → LA in July

        // event.start − block.start == delta → TZ-shift
        let shifted = pair(taskStart: base, eventStart: base.addingTimeInterval(delta), id: "t_tz")
        // 2h user move → real drift
        let userMoved = pair(taskStart: base, eventStart: base.addingTimeInterval(7200), id: "t_user")

        let result = CalendarDrift.partitionForTZShift([shifted, userMoved], offsetDelta: delta)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_tz"])
        XCTAssertEqual(result.other.map(\.task.id), ["t_user"])
    }

    /// The ±60s tolerance mirrors driftedTasks: within tolerance of the delta is
    /// TZ-shift; beyond it is not.
    func testPartitionToleranceBoundary() {
        let base = makeDate(2026, 7, 12, h: 9)
        let delta: TimeInterval = -61200

        let justInside = pair(taskStart: base,
                              eventStart: base.addingTimeInterval(delta + 59), id: "t_in")
        let justOutside = pair(taskStart: base,
                               eventStart: base.addingTimeInterval(delta + 61), id: "t_out")

        let result = CalendarDrift.partitionForTZShift([justInside, justOutside], offsetDelta: delta)
        XCTAssertEqual(result.tzShift.map(\.task.id), ["t_in"])
        XCTAssertEqual(result.other.map(\.task.id), ["t_out"])
    }

    /// Zero offset delta means no TZ shift happened — everything is real drift;
    /// the partition must never classify ordinary drift as TZ-shift (which would
    /// silently bulk-sync a user's genuine edits).
    func testPartitionWithZeroDeltaClassifiesNothingAsTZShift() {
        let base = makeDate(2026, 7, 12, h: 9)
        let moved = pair(taskStart: base, eventStart: base.addingTimeInterval(3600), id: "t_m")
        let result = CalendarDrift.partitionForTZShift([moved], offsetDelta: 0)
        XCTAssertTrue(result.tzShift.isEmpty)
        XCTAssertEqual(result.other.map(\.task.id), ["t_m"])
    }

    /// A task without a time block cannot be TZ-shift-classified — falls through
    /// to `other` (defensive; driftedTasks shouldn't produce such pairs).
    func testPartitionPairWithoutTimeBlockFallsThrough() {
        let base = makeDate(2026, 7, 12, h: 9)
        var noBlock = pair(taskStart: base, eventStart: base.addingTimeInterval(-61200), id: "t_nb")
        noBlock.task.timeBlock = nil
        let result = CalendarDrift.partitionForTZShift([noBlock], offsetDelta: -61200)
        XCTAssertTrue(result.tzShift.isEmpty)
        XCTAssertEqual(result.other.map(\.task.id), ["t_nb"])
    }
}
