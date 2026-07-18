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
    /// +10:30 in October (post-Oct-4 DST) — a distinct :30 offset between Brisbane
    /// (+10) and Sydney (+11), the intermediate zone for the A→B→C partition test.
    let adelaide = TimeZone(identifier: "Australia/Adelaide")!

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

    // MARK: - One-shot bulk TZ-shift re-anchor prompt (roadmap 3.3 slice 2, Task 3)
    //
    // These drive the WHOLE integration: seed linked task(s) on disk under an
    // original zone, build the model there (no drift — block == event), then
    // `replace(...)` to the NEW zone (the live-rebuild entry Task 2 wired). The
    // rebuild re-pins the store so today's file reparses under the new zone; the
    // bare wall-clock block shifts by the per-block offset delta while the linked
    // EVENT stays put — pure TZ-shift drift that the ONE bulk prompt intercepts
    // BEFORE the normal per-set drift prompt can show it (Task 2 review handoff).
    //
    // Zone idiom: Brisbane→Sydney in OCTOBER (the adversarial-review star case) —
    // offset-identical in July but +1h after Oct 4, and small enough (+1h) that
    // "today" is the same calendar day and file in both zones, so the reparse is
    // exercised without cross-midnight file-name drift. A mid-morning `now` keeps
    // every block inside the day window in both zones.

    /// (a) One linked task + a real TZ flip surfaces exactly ONE bulk re-anchor
    /// prompt carrying every shifted pair — never a per-task drift storm, and the
    /// tz-shifted pairs do NOT leak into the normal drift prompt.
    @MainActor
    func testTZFlipSurfacesOneBulkReanchorPromptNotPerTaskStorm() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        let bStart = makeDate(2026, 10, 10, h: 16, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
            (id: "t_b", eventID: "ev_b", text: "review", start: bStart, end: bStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        // Events stay at their ORIGINAL Brisbane-anchored instants (unmoved appointments).
        fake.cannedEvents = [
            event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800)),
            event("ev_b", "review", bStart, bStart.addingTimeInterval(1800)),
        ]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()
        XCTAssertNil(model.reanchorPrompt, "no rebuild yet → no bulk prompt")

        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()

        let prompt = try XCTUnwrap(model.reanchorPrompt, "a real TZ flip must arm the bulk prompt")
        XCTAssertEqual(Set(prompt.tzShift.map(\.task.id)), ["t_a", "t_b"],
                       "ONE prompt carries every shifted pair (no per-task storm)")
        XCTAssertNil(model.driftPrompt, "tz-shifted pairs must NOT leak into the normal drift prompt")
    }

    /// (b) "Times moved with you" pushes each task's wall-clock instants onto its
    /// event; an `.eventNotFound` pair skips with the Task-1 notice, siblings still
    /// processed (per-pair isolation — no all-or-nothing batch).
    @MainActor
    func testMoveWithMePushesWallClockAndToleratesNotFoundPerPair() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        let bStart = makeDate(2026, 10, 10, h: 16, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
            (id: "t_b", eventID: "ev_b", text: "review", start: bStart, end: bStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [
            event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800)),
            event("ev_b", "review", bStart, bStart.addingTimeInterval(1800)),
        ]
        // ev_a is gone in Calendar (deleted) → its push reports .notFound and is skipped.
        fake.updateErrorsByID = ["ev_a": .eventNotFound]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt)

        model.confirmReanchorMoveWithMe()
        await model.awaitCalendarRefresh()

        // Both pairs attempted (no early return); ev_b pushed the TASK's NEW-zone wall-clock.
        XCTAssertEqual(Set(fake.updatedEventIDs), ["ev_a", "ev_b"], "every pair attempted")
        let bReanchored = makeDate(2026, 10, 10, h: 16, tz: sydney) // "16:00" now reparsed under Sydney
        XCTAssertTrue(fake.updatedEvents.contains(
            FakeCalendarService.UpdatedEvent(id: "ev_b", title: "review",
                                             start: bReanchored, end: bReanchored.addingTimeInterval(1800))),
            "the surviving pair pushes the task's re-anchored wall-clock instant")
        XCTAssertEqual(model.driftUpdateSkipNotice,
                       "1 calendar event could not be found and was not updated.")
        XCTAssertNil(model.reanchorPrompt, "prompt cleared on choice")
    }

    /// (c) "Keep appointment times" rewrites each block from its event's absolute
    /// instants (calendar-wins, the existing SC4 per-pair path), pinning the task
    /// to the appointment rather than the moved wall-clock.
    @MainActor
    func testKeepAppointmentTimesRewritesBlocksFromEvents() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt)

        model.confirmReanchorKeepTimes()
        await model.awaitCalendarRefresh()

        // Calendar wins: the block on disk now reparses to the EVENT's absolute instant.
        let doc = try Store(folder: folder, timezone: sydney).readDoc(on: day)
        let stored = try XCTUnwrap(doc.tasks.first { $0.id == "t_a" })
        XCTAssertEqual(stored.timeBlock, TimeBlock(start: aStart, end: aStart.addingTimeInterval(1800)),
                       "the block is pinned to the appointment's absolute instant")
        XCTAssertNil(model.reanchorPrompt)
        XCTAssertNil(model.driftPrompt, "calendar-wins resolves the drift")
    }

    /// (d) Mixed set: a pair that moved by exactly the offset delta is TZ-shift (bulk
    /// prompt); a pair that moved by some OTHER amount is genuine drift and falls
    /// through to the normal per-set drift prompt.
    @MainActor
    func testMixedSetTZShiftBulkGenuineDriftFallsThrough() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let tzStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        let userStart = makeDate(2026, 10, 10, h: 16, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_tz", eventID: "ev_tz", text: "standup", start: tzStart, end: tzStart.addingTimeInterval(1800)),
            (id: "t_user", eventID: "ev_user", text: "review", start: userStart, end: userStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        // ev_tz stays put (pure TZ-shift after reparse). ev_user moved +2h in ADDITION,
        // so its post-reparse delta ≠ the +1h offset delta → genuine drift.
        let userStartSyd = makeDate(2026, 10, 10, h: 16, tz: sydney)
        fake.cannedEvents = [
            event("ev_tz", "standup", tzStart, tzStart.addingTimeInterval(1800)),
            event("ev_user", "review", userStartSyd.addingTimeInterval(7200),
                  userStartSyd.addingTimeInterval(7200 + 1800)),
        ]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()

        let bulk = try XCTUnwrap(model.reanchorPrompt)
        XCTAssertEqual(bulk.tzShift.map(\.task.id), ["t_tz"], "only the offset-delta pair is TZ-shift")
        let drift = try XCTUnwrap(model.driftPrompt, "the genuine-drift pair falls through")
        XCTAssertEqual(drift.drifted.map(\.task.id), ["t_user"])
    }

    /// (e) Dismissing persists NOTHING; the next reload re-detects the still-present
    /// drift (idempotent by construction — the prompt writes nothing about itself).
    @MainActor
    func testDismissReanchorPersistsNothingNextReloadReDetects() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt)

        let before = folderSnapshot(folder)
        model.dismissReanchorPrompt()
        XCTAssertNil(model.reanchorPrompt)
        XCTAssertEqual(folderSnapshot(folder), before, "dismiss persists nothing")

        // A plain reload (no rebuild) re-detects the still-present drift — now as the
        // normal per-set prompt (decide-later falls back to the granular path).
        model.reload()
        await model.awaitCalendarRefresh()
        XCTAssertNotNil(model.driftPrompt, "nothing was persisted, so the drift re-detects")
    }

    /// Correction: an identifier-only rebuild between OFFSET-IDENTICAL zones
    /// (Melbourne→Sydney) shows NO bulk prompt — the partition yields zero pairs
    /// because every block's per-block offset delta is zero, so it stays silent
    /// naturally (the arm fires on the identifier change; the partition decides).
    @MainActor
    func testMelbourneToSydneyRebuildShowsNoBulkPrompt() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: melbourne)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: melbourne)
        try seedLinked(folder: folder, zone: melbourne, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: melbourne, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()

        XCTAssertNil(model.reanchorPrompt, "offset-identical rebuild → partition empty → no bulk prompt")
        XCTAssertNil(model.driftPrompt, "and nothing drifted, so no normal prompt either")
    }

    /// Byte-identity through the whole rebuild→partition→prompt-display path (Task 2
    /// review): with a real calendar coordinator and a drifting linked task, the
    /// populated folder stays byte-identical — the bulk prompt DISPLAYS, and not one
    /// byte is written until the user makes a choice.
    @MainActor
    func testRebuildWithCoordinatorLeavesFolderByteIdenticalUntilChoice() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        let before = folderSnapshot(folder)
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()

        _ = try XCTUnwrap(model.reanchorPrompt, "the prompt displays")
        XCTAssertEqual(folderSnapshot(folder), before,
                       "rebuild + partition + prompt display must write zero bytes")
    }

    // MARK: - Arm lifecycle (C1 + I1a/b/c, final adversarial review)

    /// Required test 1 (C1 demotion repro): an armed rebuild publishes the bulk prompt,
    /// then a PLAIN popover-open reload (no arm) must NOT demote the still-unanswered
    /// prompt into the ordinary per-task drift storm. Fails on d8a9166 (the unarmed
    /// else-branch nilled `reanchorPrompt`, dropping the pair into `driftPrompt`).
    @MainActor
    func testArmedRebuildThenPlainReloadKeepsBulkPromptC1() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt, "armed rebuild arms the bulk prompt")

        // The production culprit: a fresh unarmed reload (popover open) BEFORE the user answers.
        model.reload()
        await model.awaitCalendarRefresh()

        let prompt = try XCTUnwrap(model.reanchorPrompt,
                                   "an unarmed reload before the user answers must keep the bulk prompt (C1)")
        XCTAssertEqual(prompt.tzShift.map(\.task.id), ["t_a"])
        XCTAssertEqual(prompt.fromZone.identifier, brisbane.identifier,
                       "the surviving prompt re-partitions against the ORIGINAL from-zone")
        XCTAssertNil(model.driftPrompt, "the pair must NOT fall into the per-task drift prompt")
    }

    /// Required test 2 (I1a): a FAILED armed pass (fetch error) must NOT consume the arm —
    /// the next classifying open still partitions the shift. Fails on d8a9166 (the arm was
    /// consumed at reloadCalendar's entry, before the fetch could fail, so it was lost).
    @MainActor
    func testFailedArmedPassKeepsArmNextOpenPartitions() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        // The armed pass fails its fetch → early return, no classification.
        fake.errorToThrow = .underlying(message: "fetch failed")
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        XCTAssertNil(model.reanchorPrompt, "a failed pass classifies nothing")

        // Recover: the arm survived the non-classifying pass, so this open partitions.
        fake.errorToThrow = nil
        model.reload()
        await model.awaitCalendarRefresh()
        let prompt = try XCTUnwrap(model.reanchorPrompt, "the arm survived the failed pass (I1a)")
        XCTAssertEqual(prompt.tzShift.map(\.task.id), ["t_a"])
    }

    /// Required test 3 (I1b): a double change A→B→C partitions against the ORIGINAL
    /// from-zone (A→C), not the intermediate (B→C). Brisbane(+10)→Adelaide(+10:30)→
    /// Sydney(+11): the event stays Brisbane-anchored, so only an A→C partition (+1h)
    /// matches its instant delta; a B→C partition (+0.5h) would misclassify it as
    /// genuine drift. Fails on d8a9166 (armed from the intermediate zone at :402).
    @MainActor
    func testDoubleChangePartitionsFromOriginalZone() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        // A→B: prompt shows, unanswered.
        model.replace(store: Store(folder: folder, timezone: adelaide), timezone: adelaide)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt, "the first change surfaces the bulk prompt")

        // B→C while the first is unresolved: must arm from the ORIGINAL A, not B.
        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()

        let prompt = try XCTUnwrap(model.reanchorPrompt,
                                   "A→C partition classifies the Brisbane-anchored event as TZ-shift")
        XCTAssertEqual(prompt.tzShift.map(\.task.id), ["t_a"])
        XCTAssertEqual(prompt.fromZone.identifier, brisbane.identifier, "partition pair is (A→C)")
        XCTAssertNil(model.driftPrompt, "a B→C partition would misclassify it into drift; A→C must not")
    }

    /// Required test 4 (I1b): a round trip A→B→A yields NO prompt — the origin-zone arm
    /// makes the partition A→A (per-block delta zero → empty). The block reparses back to
    /// its original instant, so no ordinary drift surfaces either. Fails on d8a9166 (armed
    /// from the intermediate B, an A→? partition against the returned-home block drifts).
    @MainActor
    func testRoundTripYieldsNoPrompt() async throws {
        let folder = makeTempFolder(); defer { removeFolder(folder) }
        let day = makeDate(2026, 10, 10, h: 9, tz: brisbane)
        let aStart = makeDate(2026, 10, 10, h: 14, tz: brisbane)
        try seedLinked(folder: folder, zone: brisbane, day: day, tasks: [
            (id: "t_a", eventID: "ev_a", text: "standup", start: aStart, end: aStart.addingTimeInterval(1800)),
        ])
        let fake = FakeCalendarService()
        fake.cannedEvents = [event("ev_a", "standup", aStart, aStart.addingTimeInterval(1800))]
        let model = buildModel(folder: folder, zone: brisbane, fake: fake, now: day)
        await model.awaitCalendarRefresh()

        model.replace(store: Store(folder: folder, timezone: sydney), timezone: sydney)
        await model.awaitCalendarRefresh()
        _ = try XCTUnwrap(model.reanchorPrompt, "the outbound change surfaces the bulk prompt")

        // Back home: arm from the ORIGINAL Brisbane → partition Brisbane→Brisbane → empty.
        model.replace(store: Store(folder: folder, timezone: brisbane), timezone: brisbane)
        await model.awaitCalendarRefresh()

        XCTAssertNil(model.reanchorPrompt, "A→B→A: origin-zone arm makes the partition empty")
        XCTAssertNil(model.driftPrompt, "the block reparsed home to its original instant — no drift")
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

    /// Seeds linked (timeBlock + calEventID) tasks on disk under `zone`, so the block's
    /// bare wall-clock `time:` token reparses per-zone on a later rebuild.
    private func seedLinked(folder: URL, zone: TimeZone, day: Date,
                            tasks: [(id: String, eventID: String, text: String, start: Date, end: Date)]) throws {
        let store = Store(folder: folder, timezone: zone)
        let todos: [Todo] = tasks.map { spec in
            var t = Todo(id: spec.id, text: spec.text, createdAt: day)
            t.timeBlock = TimeBlock(start: spec.start, end: spec.end)
            t.calEventID = spec.eventID
            return t
        }
        try store.appendCapture(noteText: "", noteId: nil, tasks: todos, at: day)
    }

    private func event(_ id: String, _ title: String, _ start: Date, _ end: Date) -> CalendarEvent {
        CalendarEvent(eventKitID: id, title: title, start: start, end: end, calendarTitle: "Work")
    }

    @MainActor
    private func buildModel(folder: URL, zone: TimeZone, fake: FakeCalendarService,
                            now: Date) -> MenubarListModel {
        MenubarListModel(store: Store(folder: folder, timezone: zone), timezone: zone,
                         defaults: throwawayDefaults(), now: { now }, calendar: fake)
    }

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
