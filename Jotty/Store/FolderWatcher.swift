import CoreServices
import Foundation

/// Injectable FSEvents seam (roadmap 3.4 phase 2, Task 7). The real FSEvents C API
/// (`FSEventStreamCreate`/`FSEventStreamSetDispatchQueue`/…) has no meaningful fake
/// surface — a test cannot synthesize a real kernel-level filesystem event stream —
/// so, exactly like `TimeZoneMonitor` wraps its `NotificationCenter` source, every
/// piece of LOGIC (debounce, path filtering, restart-on-folder-change) lives above
/// this seam in `FolderWatcher` and is driven through a fake in tests; only the thin
/// `RealFolderEventStream` below touches the real API, and it is untested at the
/// stream level.
protocol FolderEventStreaming {
    /// Begins watching `path`. `onPaths` is called with the changed paths whenever
    /// the stream reports activity (delivered on the main thread —
    /// `RealFolderEventStream` pins its dispatch queue to `.main`). A stream already
    /// watching MUST be torn down first: mirrors `FSEventStreamCreate`'s
    /// one-shot-per-stream discipline (there is no "add a second watch"; `start`
    /// always replaces whatever was running).
    func start(path: String, onPaths: @escaping ([String]) -> Void)

    /// Tears down the current watch, if any. Safe to call when not watching.
    func stop()
}

/// Real FSEvents wrapper. Deliberately thin: it only asks the kernel to watch one
/// folder and forwards the changed paths — no filtering, no debounce, no state
/// beyond the live stream handle. `kFSEventStreamCreateFlagFileEvents` is what makes
/// `onPaths` receive individual FILE paths (day-file vs. sidecar vs. temp file)
/// rather than just "something in this directory changed" (the coarser default).
final class RealFolderEventStream: FolderEventStreaming {
    /// OS-level coalescing window BEFORE FSEvents delivers a batch at all — separate
    /// from, and upstream of, `FolderWatcher`'s own software debounce. Short: the
    /// software debounce (tested) is what actually absorbs bursts/self-writes; this
    /// just avoids one stream callback per raw kernel event.
    private let latency: CFTimeInterval
    private var streamRef: FSEventStreamRef?
    private var callback: (([String]) -> Void)?

    init(latency: CFTimeInterval = 0.2) {
        self.latency = latency
    }

    func start(path: String, onPaths: @escaping ([String]) -> Void) {
        stop()
        callback = onPaths
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientCallBackInfo, _, eventPaths, _, _) in
                guard let clientCallBackInfo else { return }
                let watcher = Unmanaged<RealFolderEventStream>
                    .fromOpaque(clientCallBackInfo).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                watcher.callback?(paths)
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let streamRef {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
        }
        streamRef = nil
        callback = nil
    }

    deinit { stop() }
}

/// Watches the storage folder for external day-file changes (Obsidian/iCloud edits,
/// design Phase 2.4) and drives a debounced `reload()` — reusing the
/// `storeChangedReload` idiom in `AppDelegate` (CR-02): every relevant event cancels
/// the prior pending reload and re-arms a short delay, so a burst of events
/// collapses to exactly one reload.
///
/// Self-write suppression mechanism: the watcher does NOT try to distinguish "Jotty
/// wrote this" from "Obsidian wrote this" at the FSEvents layer — both land as a
/// plain rename onto the same day-file path (`Store`'s write funnel is
/// `Data.write(to:options:.atomic)`, the same temp-write-then-rename shape any other
/// editor's atomic save produces), so origin is not reliably recoverable from the
/// event alone. Instead the invariant is two-layered:
///   1. DEBOUNCE-ABSORBED: a self-write's rename event cancels/re-arms the same
///      pending-reload task as any other event, so it costs at most one extra,
///      coalesced reload — never a dedicated one per write.
///   2. NO FEEDBACK LOOP BY CONSTRUCTION: `reload()` is documented to never itself
///      write (design constraint carried over this task), so a self-triggered
///      reload cannot produce a NEW FS event for this watcher to react to. There is
///      no amplifying cycle to suppress — only the bounded "one harmless extra
///      reload per Jotty write" cost, which the debounce already minimizes.
///
/// Path filtering: `isRelevantDayFile` accepts ONLY the exact `yyyy-MM-dd.md`
/// day-file shape (mirrors `DailyFile`'s strict formatter) — `.corrupt-*`/
/// `.conflict-*` sidecars (also `.md`, Task 5/6) and hidden/temp files never reach
/// the debounce, so quarantine writes and conflict-sidecar archival cause zero
/// pointless reloads.
///
/// Restart discipline: `start(folder:)` always tears down any prior stream AND
/// bumps a generation counter, so a stale in-flight callback from an
/// already-replaced stream (e.g. one queued on the main queue microseconds before a
/// folder-change or TZ-rebuild restart) is discarded rather than firing a reload
/// against the OLD watch.
///
/// Injectable event source (seam, mirrors `TimeZoneMonitor`'s `NotificationCenter`
/// seam): everything above is exercised in tests through `FolderEventStreaming`;
/// only `RealFolderEventStream` touches the real FSEvents API.
@MainActor
final class FolderWatcher {
    /// Pluggable sleeper so tests do not wait real wall-clock time for the debounce
    /// window (mirrors `RetryPolicy.Sleeper`).
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let eventSource: FolderEventStreaming
    private let debounceNanoseconds: UInt64
    private let sleeper: Sleeper
    /// `@MainActor`-typed (mirrors `EventKitCalendarService.onStoreChanged`) so the
    /// caller's closure literal — which reaches into `menubar.listModel`, itself
    /// `@MainActor` — type-checks at its AppDelegate construction site with no
    /// `MainActor.assumeIsolated` wrapping needed there.
    private let onReload: @MainActor () -> Void

    /// Bumped on every `start`/`stop` so a callback captured by a torn-down stream
    /// recognizes itself as stale and no-ops (see the restart-discipline doc above).
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private(set) var watchedPath: String?

    /// - Parameters:
    ///   - debounceNanoseconds: 400ms, matching `storeChangedReload`'s window — long
    ///     enough to coalesce an editor's multi-write save (or Jotty's own
    ///     temp-write-then-rename) into one reload, short enough that an external
    ///     edit is visible near-instantly against the "minutes" staleness this task
    ///     replaces.
    ///   - onReload: called on the main actor once the debounce window elapses with
    ///     no further relevant event.
    init(eventSource: FolderEventStreaming = RealFolderEventStream(),
         debounceNanoseconds: UInt64 = 400_000_000,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
         onReload: @escaping @MainActor () -> Void) {
        self.eventSource = eventSource
        self.debounceNanoseconds = debounceNanoseconds
        self.sleeper = sleeper
        self.onReload = onReload
    }

    /// Starts (or restarts) watching `folder`. Safe to call repeatedly — a Settings
    /// storage-folder change and a live TZ rebuild both call this again with the
    /// (possibly new) folder; each call tears down any prior stream and cancels any
    /// pending debounce FIRST, and bumps the generation counter, so the old watch
    /// can never fire a reload after this call returns.
    func start(folder: URL) {
        eventSource.stop()
        debounceTask?.cancel()
        debounceTask = nil
        generation += 1
        let thisGeneration = generation
        watchedPath = folder.path
        eventSource.start(path: folder.path) { [weak self] paths in
            MainActor.assumeIsolated {
                self?.handle(paths: paths, generation: thisGeneration)
            }
        }
    }

    /// Stops watching. Safe to call when not started.
    func stop() {
        eventSource.stop()
        debounceTask?.cancel()
        debounceTask = nil
        watchedPath = nil
        generation += 1
    }

    private func handle(paths: [String], generation callGeneration: Int) {
        // A callback delivered by a stream that has since been torn down (restart
        // raced an in-flight delivery) — discard rather than reload for a dead watch.
        guard callGeneration == generation else { return }
        guard paths.contains(where: Self.isRelevantDayFile) else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, sleeper, debounceNanoseconds] in
            try? await sleeper(debounceNanoseconds)
            guard !Task.isCancelled else { return }
            // Defensive hop (mirrors `MenubarListModel.reloadOnMain`'s
            // `await MainActor.run { self.reload(...) }`): guarantees the
            // `@MainActor` closure runs isolated regardless of whether this
            // Task's body itself inherited actor context.
            await MainActor.run { self?.onReload() }
        }
    }

    /// True iff `path`'s last component is exactly a day-file name (`yyyy-MM-dd.md`)
    /// — never a `.corrupt-*`/`.conflict-*` sidecar (both also end in `.md` but carry
    /// an extra `.<kind>-<stamp>` component, which fails the exact 10-character stem
    /// check below) and never a hidden/dotfile (`.DS_Store`, an editor's hidden swap
    /// copy, …).
    static func isRelevantDayFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), name.hasSuffix(".md") else { return false }
        let stem = String(name.dropLast(3))
        return isDayFileStem(stem)
    }

    /// Exactly `yyyy-MM-dd`: three digit groups (4/2/2) joined by `-`, nothing else —
    /// the same discipline `DailyFile.dayFormatter` writes with, so a sidecar's extra
    /// `.corrupt-…`/`.conflict-…` suffix always fails this check.
    private static func isDayFileStem(_ stem: String) -> Bool {
        guard stem.count == 10 else { return false }
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
