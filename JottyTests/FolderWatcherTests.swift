// JottyTests/FolderWatcherTests.swift
// Roadmap 3.4 phase 2, Task 7: external-change watcher → debounced reload.
// Design note (verbatim, Phase 2.4): lightweight FSEvents on the storage folder →
// debounced menubar.listModel.reload() (reuse the EKEventStoreChanged debounce
// idiom). Every scenario here drives FolderWatcher purely through the injectable
// FolderEventStreaming seam + an injected Sleeper — never a real FSEvents stream
// and never real wall-clock waiting for the debounce window (mirrors
// RetryPolicyTests' injected-Sleeper idiom).

import XCTest
@testable import Jotty

@MainActor
final class FolderWatcherTests: XCTestCase {

    // MARK: - Helpers

    /// Records reload() calls off the main actor so tests can await a settled
    /// count without racing the watcher's own MainActor-isolated delivery.
    private actor ReloadRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// A sleeper that resolves immediately (no real wait) but still lets every
    /// `await` in the debounce Task's chain actually suspend/resume, so cancellation
    /// races (burst coalescing) are exercised for real rather than skipped.
    private func makeInstantSleeper() -> FolderWatcher.Sleeper {
        { _ in try? await Task.sleep(nanoseconds: 1) }
    }

    /// Lets the pending debounce Task(s) actually run to completion. The injected
    /// sleeper above resolves near-instantly, so this margin is generous relative
    /// to actual scheduling latency, never a real 400ms wait.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeWatcher(
        eventSource: FakeFolderEventStream,
        recorder: ReloadRecorder
    ) -> FolderWatcher {
        FolderWatcher(
            eventSource: eventSource,
            sleeper: makeInstantSleeper(),
            onReload: { Task { await recorder.record() } })
    }

    // MARK: - (a) injected FS event → exactly one reload after the debounce window

    func testSingleRelevantEventCausesExactlyOneReload() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")

        watcher.start(folder: folder)
        fake.fire([folder.appendingPathComponent("2026-07-17.md").path])
        await settle()

        let count = await recorder.count
        XCTAssertEqual(count, 1, "one relevant event must produce exactly one reload")
    }

    /// An event with no relevant day-file path must never arm the debounce at all.
    func testIrrelevantEventCausesNoReload() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")

        watcher.start(folder: folder)
        fake.fire([folder.appendingPathComponent(".DS_Store").path])
        await settle()

        let count = await recorder.count
        XCTAssertEqual(count, 0, "an irrelevant path must never trigger a reload")
    }

    // MARK: - (b) burst of events → one reload

    func testBurstOfEventsWithinDebounceWindowCausesOneReload() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")
        let dayFile = folder.appendingPathComponent("2026-07-17.md").path

        watcher.start(folder: folder)
        // A rapid burst (e.g. an editor's multi-write save) — each fire cancels the
        // prior pending reload and re-arms, so this must collapse to ONE reload.
        fake.fire([dayFile])
        fake.fire([dayFile])
        fake.fire([dayFile])
        fake.fire([dayFile])
        await settle()

        let count = await recorder.count
        XCTAssertEqual(count, 1, "a burst within the debounce window must coalesce to one reload")
    }

    /// Two bursts separated by a settled gap must each produce their own reload —
    /// the debounce coalesces WITHIN a window, not across unrelated windows.
    func testTwoSeparatedBurstsProduceTwoReloads() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")
        let dayFile = folder.appendingPathComponent("2026-07-17.md").path

        watcher.start(folder: folder)
        fake.fire([dayFile])
        await settle()
        fake.fire([dayFile])
        await settle()

        let count = await recorder.count
        XCTAssertEqual(count, 2, "two settled bursts must each produce their own reload")
    }

    // MARK: - (c) Jotty's own funnel write does not cause an infinite reload loop

    /// Jotty's own atomic write (`Data.write(options:.atomic)`) lands as a
    /// temp-create-then-rename pair — model that as two rapid events for the SAME
    /// day-file path. `reload()` (the recorder here) CAN itself write (a
    /// `.conflict-*` sidecar via `checkForUnresolvedConflicts`, see
    /// `testConflictSidecarWriteThroughWatcherCausesNoReload` below), but that write
    /// never lands on the day-file path this burst is modeling, so there is still no
    /// possible feedback loop here: after the debounce settles, the count must stay
    /// at exactly one and never grow on its own.
    func testSelfWriteBurstCausesExactlyOneReloadAndNoLoop() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")
        let dayFile = folder.appendingPathComponent("2026-07-17.md").path

        watcher.start(folder: folder)
        // Simulates the funnel's own write: a create-ish event then the rename-over.
        fake.fire([dayFile])
        fake.fire([dayFile])
        await settle()
        var count = await recorder.count
        XCTAssertEqual(count, 1, "a self-write burst must coalesce to one reload")

        // No further external stimulus, and even a `.conflict-*` sidecar reload()
        // might write can't produce a NEW FS event THIS watcher reacts to (path
        // filtering, see below) — the count must NOT keep growing on its own.
        await settle()
        count = await recorder.count
        XCTAssertEqual(count, 1,
                       "with no further events, the reload count must never grow by itself (no feedback loop)")
    }

    /// Review fix (roadmap 3.4 phase 2, Task 7): locks in the ACTUAL no-loop
    /// mechanism. `reload()` is not write-free — it drives
    /// `Store.checkForUnresolvedConflicts(on:)`, which can itself write a
    /// `.conflict-*` sidecar (Task 6, `Store.writeSidecar`, Store.swift:827-836)
    /// when iCloud surfaces a losing sync version. That write can't loop back into
    /// this watcher because `isRelevantDayFile` requires an exact `yyyy-MM-dd.md`
    /// stem, which the sidecar's `.conflict-<stamp>` suffix always fails — NOT
    /// because reload() never writes. Drives a real sidecar-shaped path (matching
    /// `writeSidecar`'s "<day>.<kind>-<stamp>.md" naming) through the FULL watcher
    /// pipeline (start → fire → debounce → recorder), not just the static filter,
    /// so a future regression in the filter — not just in `isRelevantDayFile`'s
    /// unit test below — fails here too.
    func testConflictSidecarWriteThroughWatcherCausesNoReload() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")
        let conflictSidecar = folder
            .appendingPathComponent("2026-07-18.conflict-20260718T101010123.md").path

        watcher.start(folder: folder)
        fake.fire([conflictSidecar])
        await settle()

        let count = await recorder.count
        XCTAssertEqual(count, 0,
                       "a .conflict-* sidecar write must never re-trigger the watcher")
    }

    // MARK: - (d) watcher follows folder change AND TZ rebuild; old path stops triggering

    func testRestartTearsDownPriorStreamAndSwitchesPath() async {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folderA = URL(fileURLWithPath: "/tmp/jotty-store-a")
        let folderB = URL(fileURLWithPath: "/tmp/jotty-store-b")

        watcher.start(folder: folderA)
        XCTAssertEqual(fake.startedPaths, [folderA.path])
        XCTAssertEqual(fake.stopCallCount, 1, "start() must tear down any (none-yet) prior stream first")

        // Folder change (Settings → Storage) AND, separately, a TZ rebuild both
        // funnel through the SAME restart call in AppDelegate.
        watcher.start(folder: folderB)
        XCTAssertEqual(fake.startedPaths, [folderA.path, folderB.path])
        XCTAssertEqual(fake.stopCallCount, 2, "restarting must tear down the OLD stream before starting the new one")
        XCTAssertEqual(watcher.watchedPath, folderB.path)

        // The live stream now only reacts for folder B.
        fake.fire([folderB.appendingPathComponent("2026-07-17.md").path])
        await settle()
        let count = await recorder.count
        XCTAssertEqual(count, 1, "the new path triggers normally")
    }

    /// A stale in-flight callback from the OLD (already-replaced) stream — e.g. one
    /// racing the main queue microseconds before `start(folder:)` tears it down —
    /// must be discarded, not fire a reload against the dead watch.
    func testStaleCallbackFromReplacedStreamNeverReloads() async throws {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folderA = URL(fileURLWithPath: "/tmp/jotty-store-a")
        let folderB = URL(fileURLWithPath: "/tmp/jotty-store-b")

        watcher.start(folder: folderA)
        let staleCallback = try XCTUnwrap(fake.capturedCallback(at: 0))

        watcher.start(folder: folderB)

        // Invoke the FIRST stream's captured callback directly — simulating a
        // delivery that was already queued before the restart tore it down.
        staleCallback([folderA.appendingPathComponent("2026-07-17.md").path])
        await settle()
        var count = await recorder.count
        XCTAssertEqual(count, 0,
                       "a stale callback from a torn-down stream must never trigger a reload")

        // The CURRENT (folder B) stream still works normally afterward.
        fake.fire([folderB.appendingPathComponent("2026-07-17.md").path])
        await settle()
        count = await recorder.count
        XCTAssertEqual(count, 1, "the live stream is unaffected by the discarded stale callback")
    }

    /// `stop()` also bumps the generation, so a callback racing a plain stop (not
    /// just a restart) is discarded the same way.
    func testStopDiscardsSubsequentStaleCallback() async throws {
        let fake = FakeFolderEventStream()
        let recorder = ReloadRecorder()
        let watcher = makeWatcher(eventSource: fake, recorder: recorder)
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")

        watcher.start(folder: folder)
        let staleCallback = try XCTUnwrap(fake.capturedCallback(at: 0))
        watcher.stop()

        staleCallback([folder.appendingPathComponent("2026-07-17.md").path])
        await settle()
        let count = await recorder.count
        XCTAssertEqual(count, 0, "a callback firing after stop() must never reload")
    }

    // MARK: - Path filtering (isRelevantDayFile)

    func testExactDayFileNameIsRelevant() {
        XCTAssertTrue(FolderWatcher.isRelevantDayFile("/Users/x/Storage/2026-07-17.md"))
    }

    func testCorruptSidecarIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile(
            "/Users/x/Storage/2026-07-17.corrupt-20260717T091500123.md"))
    }

    func testConflictSidecarIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile(
            "/Users/x/Storage/2026-07-17.conflict-20260717T091500123-2.md"))
    }

    func testHiddenDotfileIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile("/Users/x/Storage/.DS_Store"))
    }

    /// A hidden shadow copy that happens to share the exact day-file stem must
    /// still be excluded — the leading dot alone disqualifies it.
    func testHiddenDayFileNameIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile("/Users/x/Storage/.2026-07-17.md"))
    }

    func testNonMarkdownFileIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile("/Users/x/Storage/notes.txt"))
    }

    func testMalformedDateShapeIsNotRelevant() {
        XCTAssertFalse(FolderWatcher.isRelevantDayFile("/Users/x/Storage/2026-7-17.md"))
        XCTAssertFalse(FolderWatcher.isRelevantDayFile("/Users/x/Storage/not-a-date.md"))
    }

    // MARK: - Debounce parameter is honored

    /// The Sleeper is invoked with the configured debounce window, not some other
    /// value — asserted via a recording sleeper (RetryPolicyTests idiom).
    func testDebounceUsesConfiguredWindow() async {
        let fake = FakeFolderEventStream()
        let delayRecorder = DelayRecorder()
        let watcher = FolderWatcher(
            eventSource: fake,
            debounceNanoseconds: 123_456_789,
            sleeper: { nanoseconds in await delayRecorder.record(nanoseconds) },
            onReload: {})
        let folder = URL(fileURLWithPath: "/tmp/jotty-store")

        watcher.start(folder: folder)
        fake.fire([folder.appendingPathComponent("2026-07-17.md").path])
        await settle()

        let delays = await delayRecorder.delays
        XCTAssertEqual(delays, [123_456_789])
    }
}

/// Records every nanoseconds value passed to an injected Sleeper (mirrors
/// RetryPolicyTests' SleepRecorder).
private actor DelayRecorder {
    private(set) var delays: [UInt64] = []
    func record(_ nanoseconds: UInt64) { delays.append(nanoseconds) }
}

// MARK: - Fake FolderEventStreaming

/// Injectable fake for `FolderEventStreaming` (roadmap 3.4 phase 2, Task 7):
/// records every `start`/`stop` call and lets tests fire synthetic path-change
/// batches directly into the CURRENT callback, or reach back into an EARLIER
/// call's captured callback to simulate a stale/racing delivery.
final class FakeFolderEventStream: FolderEventStreaming {
    private(set) var startedPaths: [String] = []
    private(set) var stopCallCount = 0
    private var capturedCallbacks: [([String]) -> Void] = []

    func start(path: String, onPaths: @escaping ([String]) -> Void) {
        startedPaths.append(path)
        capturedCallbacks.append(onPaths)
    }

    func stop() {
        stopCallCount += 1
    }

    /// Simulates FSEvents delivering `paths` on the MOST RECENT stream.
    func fire(_ paths: [String]) {
        capturedCallbacks.last?(paths)
    }

    /// The onPaths closure captured by the Nth `start` call (0-indexed).
    func capturedCallback(at index: Int) -> (([String]) -> Void)? {
        guard capturedCallbacks.indices.contains(index) else { return nil }
        return capturedCallbacks[index]
    }
}
