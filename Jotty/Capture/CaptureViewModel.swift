import SwiftUI
import Combine
import Foundation

// MARK: - CaptureState

enum CaptureState: Equatable {
    case input
    case review(tasks: [ExtractedTask], noteBody: String, savedInput: String)
}

// MARK: - Calendar notice / conflict state (Phase 5, plan 05-05)

/// A non-blocking, user-visible notice raised by the best-effort calendar work on commit.
///
/// Calendar creation is best-effort: a denied permission or a write failure must NEVER roll
/// back the markdown commit or block capture (CONTEXT + RESEARCH anti-pattern). When one of
/// those happens we surface this lightweight notice instead, which the capture view renders
/// as a one-line affordance. Distinct from `lastError` (the AI-extraction error channel).
enum CalendarNotice: Equatable {
    /// Full calendar access was not granted; the time-blocked task still committed without an event.
    case accessDenied
    /// A calendar write failed; the task still committed to markdown (disk wins), just no `cal_event`.
    case writeFailed(message: String)
}

/// A pending conflict awaiting the user's commit-anyway / cancel decision (SC5).
///
/// Raised before a time-blocked event is written when its window overlaps an existing event.
/// The view reads `conflictTitle` for the "⚠️ overlaps with '<title>' — commit anyway?" copy and
/// drives `resolveConflict(commitAnyway:)`. Per CONTEXT: confirm commits both task+event; cancel
/// leaves that task uncommitted (it is never appended to markdown).
struct CalendarConflict: Equatable {
    /// Title of the first overlapping existing event, for the confirm copy.
    let conflictTitle: String
}

// MARK: - ViewModel

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var text: String = "" {
        didSet {
            // UX-08: the "Draft restored" affordance goes away once the user
            // edits the restored draft down to nothing (or clears it).
            if draftWasRestored,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftWasRestored = false
            }
            scheduleAutosave()
        }
    }
    @Published var state: CaptureState = .input
    /// Indices of rows the user has left checked. All rows checked by default on enterReview.
    @Published var acceptedRowIDs: Set<Int> = []
    /// UX-06: row indices whose per-item calendar toggle is ON. Seeded in `enterReview`
    /// from each ExtractedTask's `calendarBlock` (the AI's intent — ISOTaskMapper sets it
    /// true for every time-blocked task). `commitFromReview` routes a time-blocked task
    /// through the async calendar pass ONLY if its row is in this set; toggled-off rows
    /// commit synchronously WITH their timeBlock but create no event.
    @Published var calendarEnabledRowIDs: Set<Int> = []
    @Published var isExtracting: Bool = false
    @Published var lastError: AIProviderError?

    /// Cluster-2 WR: a distinct, honest signal for a COMMIT-TIME disk-write failure.
    /// Kept separate from `lastError` (the AI-extraction channel) so a failed
    /// `appendCapture` no longer borrows the misleading "saved as a plain note" copy —
    /// nothing was saved. Non-nil holds the user-facing message; the user stays in
    /// Review with their draft intact so they can retry.
    @Published var saveError: String?

    /// UX-03: true once a commit has landed on disk (manual fast path or Review
    /// commit). The view renders a brief "Saved" toast while set. A fresh VM is
    /// created per capture-window open, so this never leaks across sessions.
    @Published var showSavedConfirmation: Bool = false
    /// UX-03: true when the VM wants the capture window closed after a successful
    /// commit. CaptureView observes this and calls its onDismiss closure once the
    /// Saved confirmation has had a beat on screen. Set ONLY on commit success.
    @Published var dismissRequested: Bool = false
    /// UX-08: true when init restored a non-empty draft. Cleared when the user
    /// edits the text to empty or taps the banner's Clear (`clearRestoredDraft()`).
    @Published var draftWasRestored: Bool = false

    /// Non-blocking calendar notice (denied access / write failure). Cleared on each commit.
    @Published var calendarNotice: CalendarNotice?
    /// Pending overlap confirm; non-nil pauses the time-blocked write until the user decides (SC5).
    @Published var pendingConflict: CalendarConflict?

    private let store: Store
    private let draftURL: URL
    private let provider: any AIProvider
    /// Apple FM fallback for the failure toast (ROADMAP Phase 4 SC4).
    /// nil when the active provider already IS Apple FM — the "Use Apple FM
    /// instead" button hides via `fallbackAvailable`. Production call site
    /// passes an AppleFMProvider in plan 11.
    private let fallbackProvider: (any AIProvider)?
    /// Optional calendar seam. nil (default) means no calendar work happens — the commit path
    /// behaves exactly as before plan 05-05 (back-compat for existing call sites/tests). The
    /// production call site injects an `EventKitCalendarService`; tests inject `FakeCalendarService`.
    private let calendar: (any CalendarService)?
    private let clock: () -> Date
    private var autosaveTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    /// The in-flight best-effort calendar work for the most recent commit (test hook awaits it).
    private var calendarTask: Task<Void, Never>?
    /// Continuation the view fulfils via `resolveConflict(commitAnyway:)` to unblock a paused
    /// time-blocked write. Stored so the awaiting commit task can resume on the user's decision.
    private var conflictContinuation: CheckedContinuation<Bool, Never>?
    /// Set once by `teardown()` when the capture window goes away (CQ-02). A conflict raised
    /// AFTER teardown — the post-commit close leg, where the window closes immediately on
    /// commit and the calendar pass hits an overlap with no UI left to resolve it — must not
    /// suspend forever; `awaitConflictDecision` checks this flag and auto-cancels instead.
    private var isTornDown = false

    /// The prose that was in-flight when the provider threw, stashed so
    /// retryWithAppleFM() can re-run the SAME input through the fallback.
    private var lastFailedInput: String?
    private var lastFailedManualTasks: [ExtractedTask] = []
    /// Cluster-2 INFO: checkbox-done state for `lastFailedManualTasks`, so a
    /// retryWithAppleFM() rebuild preserves `- [x]` done-ness through Review.
    private var lastFailedManualDoneIndices: Set<Int> = []
    /// Cluster-2 INFO: review-row indices that must commit as DONE. Seeded by
    /// `enterReview(doneIndices:)` from the manual `- [x]` lines (which are always
    /// prepended, so their index in the review equals their manual index).
    private var reviewManualDoneIDs: Set<Int> = []

    /// True iff a fallback provider is wired — drives the toast button.
    var fallbackAvailable: Bool { fallbackProvider != nil }

    init(store: Store, draftURL: URL,
         provider: any AIProvider,
         fallbackProvider: (any AIProvider)? = nil,
         calendar: (any CalendarService)? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.draftURL = draftURL
        self.provider = provider
        self.fallbackProvider = fallbackProvider
        self.calendar = calendar
        self.clock = clock

        // Restore draft if present. A non-empty restore is announced (UX-08) so
        // the user knows why the editor isn't blank and can clear it in one tap.
        if let restored = try? String(contentsOf: draftURL, encoding: .utf8) {
            self.text = restored
            if !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.draftWasRestored = true
            }
        }
    }

    /// UX-08: banner action — drop the restored draft entirely: the editor text,
    /// the announcement flag, and the on-disk draft file (so a relaunch doesn't
    /// resurrect what the user explicitly discarded).
    func clearRestoredDraft() {
        text = ""                       // didSet also resets draftWasRestored
        draftWasRestored = false
        autosaveTask?.cancel()          // cancel the write the didSet just queued
        try? FileManager.default.removeItem(at: draftURL)
    }

    // MARK: - Manual syntax detection

    private static let manualTaskRegex = /^\s*[-*]\s\[([ xX])\]\s+(.+)$/

    private func hasManualSyntax(_ s: String) -> Bool {
        s.components(separatedBy: "\n").contains { $0.firstMatch(of: Self.manualTaskRegex) != nil }
    }

    // MARK: - Submit

    func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastError = nil
        saveError = nil

        // Per-line routing: extract manual `- [ ] ` lines as ExtractedTask
        // directly (bypass AI); send the remaining prose to the AI provider.
        // The Review state then shows manual + AI tasks combined.
        var manualTasks: [ExtractedTask] = []
        // Cluster-2 INFO: ExtractedTask carries no done flag (and is out of this
        // cluster's scope to change), so the mixed-path checkbox state is tracked
        // alongside. Manual tasks are ALWAYS prepended to the review list, so a
        // done flag at manual-index i maps directly to review-index i.
        var manualDoneFlags: [Bool] = []
        var remainingLines: [String] = []
        for line in trimmed.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: Self.manualTaskRegex) {
                let title = String(match.2).trimmingCharacters(in: .whitespaces)
                manualTasks.append(ExtractedTask(title: title))
                manualDoneFlags.append(match.1 != " ")
            } else {
                remainingLines.append(line)
            }
        }
        let manualDoneIndices = Set(manualDoneFlags.indices.filter { manualDoneFlags[$0] })
        let remainingText = remainingLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure-manual capture (no prose to extract from): commit directly,
        // skipping the Review state. Fast path for typed checklists.
        if !manualTasks.isEmpty && remainingText.isEmpty {
            do {
                try submitManual(trimmed)
            } catch {
                lastError = .underlying(message: error.localizedDescription)
            }
            return
        }

        // Mixed or pure-prose capture: send remaining text to AI, combine
        // any manual tasks into the Review state.
        isExtracting = true
        extractionTask?.cancel()
        let now = clock()
        let tz = TimeZone.current
        let manualTasksCopy = manualTasks
        let manualDoneIndicesCopy = manualDoneIndices
        let remainingTextCopy = remainingText
        extractionTask = Task { [weak self] in
            guard let self else { return }
            let p = self.provider
            do {
                let aiResult = remainingTextCopy.isEmpty
                    ? ExtractionResult(tasks: [], noteBody: "")
                    : try await p.extractTasks(from: remainingTextCopy, now: now, timezone: tz)
                try Task.checkCancellation()
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = nil   // success — clear any stale error from a prior attempt
                    self.enterReview(tasks: manualTasksCopy + aiResult.tasks,
                                     noteBody: aiResult.noteBody,
                                     doneIndices: manualDoneIndicesCopy)
                }
            } catch is CancellationError {
                return
            } catch let e as AIProviderError {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = e
                    // Stash the failed input so retryWithAppleFM can re-run it.
                    self.lastFailedInput = remainingTextCopy
                    self.lastFailedManualTasks = manualTasksCopy
                    self.lastFailedManualDoneIndices = manualDoneIndicesCopy
                    // Degraded review: keep manual tasks, raw remaining text as note body.
                    self.enterReview(tasks: manualTasksCopy, noteBody: remainingTextCopy,
                                     doneIndices: manualDoneIndicesCopy)
                }
            } catch {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = .underlying(message: error.localizedDescription)
                    self.lastFailedInput = remainingTextCopy
                    self.lastFailedManualTasks = manualTasksCopy
                    self.lastFailedManualDoneIndices = manualDoneIndicesCopy
                    self.enterReview(tasks: manualTasksCopy, noteBody: remainingTextCopy,
                                     doneIndices: manualDoneIndicesCopy)
                }
            }
        }
    }

    /// Awaits in-flight extraction; for tests only.
    func submitAndWait() async {
        submit()
        if let t = extractionTask { _ = await t.value }
    }

    // MARK: - Apple FM fallback (plan 04-10, ROADMAP Phase 4 SC4)

    /// Re-runs the last failed input through the injected fallback provider
    /// (Apple FM in production). On success the Review state rebuilds with
    /// the fallback's tasks and `lastError` clears; on failure `lastError`
    /// updates to the new error and nothing else changes. No-op when no
    /// fallback is wired or nothing has failed.
    func retryWithAppleFM() async {
        // Re-entry guard (MIN-04): a double-tap on "Use Apple FM instead" must
        // not launch two overlapping extractions that both mutate
        // isExtracting/state. No fallback wired or nothing failed → no-op.
        guard !isExtracting,
              let fallback = fallbackProvider,
              let failedInput = lastFailedInput else { return }

        isExtracting = true
        let now = clock()
        let tz = TimeZone.current
        do {
            let result = failedInput.isEmpty
                ? ExtractionResult(tasks: [], noteBody: "")
                : try await fallback.extractTasks(from: failedInput, now: now, timezone: tz)
            isExtracting = false
            lastError = nil
            enterReview(tasks: lastFailedManualTasks + result.tasks,
                        noteBody: result.noteBody,
                        doneIndices: lastFailedManualDoneIndices)
            lastFailedInput = nil
            lastFailedManualTasks = []
            lastFailedManualDoneIndices = []
        } catch let e as AIProviderError {
            isExtracting = false
            lastError = e
        } catch {
            isExtracting = false
            lastError = .underlying(message: error.localizedDescription)
        }
    }

    // MARK: - Manual path

    private func submitManual(_ input: String) throws {
        let now = clock()
        var noteLines: [String] = []
        var tasks: [Todo] = []

        for line in input.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: Self.manualTaskRegex) {
                let done = match.1 != " "
                let title = String(match.2).trimmingCharacters(in: .whitespaces)
                tasks.append(Todo(id: Todo.newID(), text: title, createdAt: now,
                                  done: done,
                                  completedAt: done ? now : nil))
            } else {
                noteLines.append(line)
            }
        }

        let noteBody = noteLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noteId = noteBody.isEmpty ? nil : Note.newID()

        try store.appendCapture(noteText: noteBody, noteId: noteId, tasks: tasks, at: now)

        text = ""
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: draftURL)

        // UX-03: the manual fast path used to clear the editor silently — signal
        // success so the view shows "Saved" and the window layer closes, matching
        // the prose path's commit feedback. Only reached when appendCapture didn't
        // throw, so these fire on genuine commit success only.
        showSavedConfirmation = true
        dismissRequested = true
    }

    func cancel() {
        // Draft is already on disk; do nothing else.
    }

    // MARK: - Plan 06: Review state machine

    func enterReview(tasks: [ExtractedTask], noteBody: String, doneIndices: Set<Int> = []) {
        let saved = self.text
        self.state = .review(tasks: tasks, noteBody: noteBody, savedInput: saved)
        self.acceptedRowIDs = Set(tasks.indices)   // all checked by default
        // UX-06: seed the calendar toggle from the AI's intent — a row starts ON
        // iff its task arrived with calendarBlock (mapper sets it for time-blocked tasks).
        self.calendarEnabledRowIDs = Set(tasks.indices.filter { tasks[$0].calendarBlock })
        // Cluster-2 INFO: which rows commit as done (manual `- [x]` lines). Scoped to
        // valid indices; a rename does NOT route through here, so done-ness survives edits.
        self.reviewManualDoneIDs = doneIndices.filter { tasks.indices.contains($0) }
    }

    func toggleRow(_ index: Int) {
        if acceptedRowIDs.contains(index) {
            acceptedRowIDs.remove(index)
        } else {
            acceptedRowIDs.insert(index)
        }
    }

    /// UX-06: flips a row's per-item calendar toggle. Membership in
    /// `calendarEnabledRowIDs` decides whether that row's time-blocked task goes
    /// through the calendar pass on commit.
    func toggleCalendarRow(_ index: Int) {
        if calendarEnabledRowIDs.contains(index) {
            calendarEnabledRowIDs.remove(index)
        } else {
            calendarEnabledRowIDs.insert(index)
        }
    }

    /// UX-10 (plan 07.1-11): renames the extracted task at `index` while in Review,
    /// rebuilding the immutable `.review` payload in place. Rules mirror the menubar
    /// inline rename:
    /// - whitespace-only titles revert (no change written);
    /// - out-of-bounds indices are a no-op;
    /// - `acceptedRowIDs` and `calendarEnabledRowIDs` are untouched — direct state
    ///   reassignment, NEVER `enterReview` (RESEARCH Pitfall 6: it re-checks every
    ///   row and re-seeds the calendar toggles, destroying the user's choices).
    func renameReviewRow(_ index: Int, title: String) {
        guard case .review(var tasks, let noteBody, let saved) = state,
              tasks.indices.contains(index) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // empty-after-trim reverts (menubar rule)
        tasks[index] = ExtractedTask(title: trimmed,
                                     dueDate: tasks[index].dueDate,
                                     timeBlock: tasks[index].timeBlock,
                                     calendarBlock: tasks[index].calendarBlock)
        state = .review(tasks: tasks, noteBody: noteBody, savedInput: saved)
    }

    func returnToInput() {
        // Cluster-2 WR: an in-flight fallback extraction (retryWithAppleFM) leaves
        // Review interactive. A ⌫ mid-await would flip to .input, and the fallback's
        // enterReview would then resurrect Review out from under the user. Swallow it.
        guard !isExtracting else { return }
        if case .review(_, _, let saved) = state {
            self.text = saved
        }
        self.state = .input
    }

    func commitFromReview() {
        // Cluster-2 WR: while an in-flight fallback extraction is running
        // (retryWithAppleFM), Review stays interactive. A ⌘↩ mid-await would commit
        // the STALE degraded review — dropping the fallback's about-to-arrive tasks,
        // or double-appending the prose on a second ⌘↩. Swallow the commit; the
        // fallback's enterReview lands the correct result when it resolves.
        guard !isExtracting else { return }
        guard case .review(let tasks, let noteBody, _) = state else { return }
        let now = clock()
        saveError = nil   // fresh attempt — drop any prior save-failure notice
        let acceptedIndices = acceptedRowIDs.sorted().filter { tasks.indices.contains($0) }

        let noteId: String? = noteBody.isEmpty
            ? nil
            : Note.newID()

        // Split accepted tasks: time-blocked tasks are conflict-gated and committed one at a
        // time inside the async calendar pass (so a cancel can leave that task uncommitted, SC5);
        // everything else commits immediately. The note commits with the plain tasks now.
        //
        // With NO calendar injected there is no calendar pass — time-blocked tasks must still
        // commit synchronously (carrying their timeBlock, no event) so they never silently
        // vanish (back-compat). Only gate time-blocked tasks through the async pass when a
        // calendar exists.
        //
        // UX-06: the per-row calendar toggle further narrows the calendar pass — a
        // time-blocked task enters it ONLY when its row's toggle is ON
        // (calendarEnabledRowIDs). Toggled-off rows take the same synchronous path as the
        // calendar-nil case: committed WITH their timeBlock, no event ever created.
        let calendarPresent = (self.calendar != nil)
        // Cluster-2 INFO: build plainTodos inside the loop so each carries its ROW
        // index — needed to honor `reviewManualDoneIDs` (a manual `- [x]` line commits
        // as done, not silently reopened). Manual done rows are never time-blocked, so
        // they always take the synchronous path here.
        var plainTodos: [Todo] = []
        var timeBlockedTasks: [ExtractedTask] = []
        for index in acceptedIndices {
            let t = tasks[index]
            if calendarPresent, t.timeBlock != nil, calendarEnabledRowIDs.contains(index) {
                timeBlockedTasks.append(t)
            } else {
                let done = reviewManualDoneIDs.contains(index)
                plainTodos.append(Todo(id: Todo.newID(),
                                       text: t.title, createdAt: now,
                                       done: done,
                                       completedAt: done ? now : nil,
                                       dueDate: t.dueDate, sourceNote: noteId, timeBlock: t.timeBlock))
            }
        }

        do {
            // Disk is source of truth — note + non-time-blocked tasks land FIRST, never gated
            // on the calendar.
            try store.appendCapture(noteText: noteBody, noteId: noteId, tasks: plainTodos, at: now)
        } catch {
            // Cluster-2 WR: a disk-write failure is NOT an AI-extraction failure. Routing
            // it through `lastError` borrowed the misleading "saved as a plain note" banner
            // (nothing was saved). Raise the honest, distinct save-failure signal instead
            // and keep the user in Review with their accepted rows + draft intact to retry.
            saveError = "Couldn't save. Try again."
            return
        }

        calendarNotice = nil
        text = ""
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: draftURL)   // best-effort cleanup; not user-visible
        state = .input
        acceptedRowIDs = []
        calendarEnabledRowIDs = []
        reviewManualDoneIDs = []

        // UX-03: both commit paths confirm — show "Saved" and ask the window
        // layer to close after the toast (replaces the view's old immediate
        // close-on-commit). The disk-error path above returned early, so this
        // fires on commit success only.
        showSavedConfirmation = true

        // Best-effort, off the synchronous commit: for each time-blocked task run the lazy
        // access gate, the conflict gate (SC5), then create the event and write `cal_event:`
        // back. A failure/denial NEVER rolls back the markdown commit above and never blocks
        // capture (CONTEXT). `calendarTask` lets `commitAndWait()` await this deterministically.
        //
        // CR-01: dismissal is requested only AFTER the calendar pass resolves. The pass can
        // raise a conflict prompt (SC5) that owns the window — arming the timed close BEFORE
        // the pass ran raced that prompt: the window closed ~0.6s after "Saved", teardown
        // auto-cancelled the pending conflict, and the user-accepted time-blocked task was
        // silently dropped. With no calendar work there is nothing to wait for.
        if calendarPresent, !timeBlockedTasks.isEmpty {
            calendarTask = Task { [weak self] in
                guard let self else { return }
                await self.processTimeBlockedTasks(timeBlockedTasks, noteId: noteId, at: now)
                self.dismissRequested = true
            }
        } else {
            calendarTask = nil
            dismissRequested = true
        }
    }

    /// Awaits the in-flight best-effort calendar work from the last `commitFromReview()`.
    /// For tests only (mirrors `submitAndWait()`); production fires-and-forgets.
    /// NOTE: when a conflict is expected, drive `commitFromReview()` + `resolveConflict(...)`
    /// manually and await `awaitCalendarWork()` instead — this helper would deadlock on the
    /// pending-conflict suspension.
    func commitAndWait() async {
        commitFromReview()
        if let t = calendarTask { _ = await t.value }
    }

    /// Awaits the calendar task spawned by the most recent `commitFromReview()`. Test hook for
    /// the conflict path where the test resolves the conflict before awaiting. No-op if none.
    func awaitCalendarWork() async {
        if let t = calendarTask { _ = await t.value }
    }

    // MARK: - Calendar commit pass (Phase 5, plan 05-05)

    /// Lazy access gate (RESEARCH): authorized → true; denied → false; notDetermined → request once.
    private func ensureCalendarAccess(_ cal: any CalendarService) async -> Bool {
        switch cal.access() {
        case .authorized: return true
        case .denied: return false
        case .notDetermined: return await cal.requestAccess() == .authorized
        }
    }

    /// For each just-accepted time-blocked task: gate access, gate conflicts (SC5), create the
    /// event, and persist `cal_event:<id>` onto that task's markdown line. Best-effort throughout.
    private func processTimeBlockedTasks(_ tasks: [ExtractedTask], noteId: String?, at now: Date) async {
        guard let cal = self.calendar else { return }

        // Lazy access gate, once for the whole batch.
        guard await ensureCalendarAccess(cal) else {
            // Denied: tasks still commit (disk wins); surface a one-line degraded notice,
            // never block. They commit WITHOUT a calendar event.
            for t in tasks {
                let todo = Todo(id: Todo.newID(),
                                text: t.title, createdAt: now, done: false,
                                dueDate: t.dueDate, sourceNote: noteId, timeBlock: t.timeBlock)
                appendSingle(todo, at: now)
            }
            calendarNotice = .accessDenied
            return
        }

        // WR-01: accumulate write failures across the batch instead of letting each
        // iteration overwrite the single `@Published` notice (last-writer-wins under-reports
        // a mixed-outcome batch). Track a count + the first message; surface once at the end.
        var failureCount = 0
        var firstFailureMessage: String?

        for t in tasks {
            guard let tb = t.timeBlock else { continue }

            // Conflict gate (SC5): query overlaps BEFORE committing this task so a cancel can
            // leave it uncommitted. A read failure is non-fatal — fall through to create.
            if let overlap = try? await cal.overlappingEvents(start: tb.start, end: tb.end),
               let first = overlap.first {
                let commitAnyway = await awaitConflictDecision(title: first.title)
                if !commitAnyway {
                    // Cancel: this task is NOT committed (CONTEXT). Skip entirely.
                    continue
                }
            }

            // Confirmed (or no conflict): commit the task to markdown, then create the event.
            let todo = Todo(id: Todo.newID(),
                            text: t.title, createdAt: now, done: false,
                            dueDate: t.dueDate, sourceNote: noteId, timeBlock: tb)
            appendSingle(todo, at: now)

            do {
                let eventID = try await cal.createEvent(
                    title: CalendarDrift.sanitize(title: t.title),
                    start: tb.start, end: tb.end)
                writeCalEventID(eventID, forTaskID: todo.id, at: now)
            } catch {
                // Write failure: task stays committed (disk wins), no cal_event. Accumulate
                // rather than overwrite so a partially-failed batch is reported in full.
                failureCount += 1
                if firstFailureMessage == nil {
                    firstFailureMessage = (error as? CalendarError).map(Self.describe) ?? "\(error)"
                }
            }
        }

        // Surface the aggregate once: a single failure keeps its exact message; multiple
        // failures report a count so no failure is silently dropped (WR-01).
        if failureCount == 1, let message = firstFailureMessage {
            calendarNotice = .writeFailed(message: message)
        } else if failureCount > 1 {
            calendarNotice = .writeFailed(
                message: "\(failureCount) events couldn't be created")
        }
    }

    /// Appends one already-built Todo to today's doc, best-effort (a disk error surfaces as a
    /// non-blocking notice but never throws into the calendar pass).
    private func appendSingle(_ todo: Todo, at now: Date) {
        do {
            try store.appendCapture(noteText: "", noteId: nil, tasks: [todo], at: now)
        } catch {
            calendarNotice = .writeFailed(message: error.localizedDescription)
        }
    }

    /// Sets `cal_event:<id>` on the matching committed task and re-persists the day's task list.
    private func writeCalEventID(_ eventID: String, forTaskID id: String, at now: Date) {
        guard let doc = try? store.readDoc(on: now) else { return }
        var tasks = doc.tasks
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].calEventID = eventID
        try? store.replaceTasks(tasks, on: now)
    }

    /// Publishes a pending conflict and suspends until the view calls `resolveConflict(...)`.
    private func awaitConflictDecision(title: String) async -> Bool {
        // CQ-02: the window is already gone — no UI can resolve a prompt, so cancel
        // (the task stays uncommitted) instead of suspending the calendar pass forever.
        guard !isTornDown else { return false }
        pendingConflict = CalendarConflict(conflictTitle: title)
        let decision = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            conflictContinuation = c
        }
        pendingConflict = nil
        conflictContinuation = nil
        return decision
    }

    /// Called by the capture view to resolve a pending conflict (SC5). `true` = commit anyway,
    /// `false` = cancel (the time-blocked task is left uncommitted). No-op if nothing is pending.
    func resolveConflict(commitAnyway: Bool) {
        guard let c = conflictContinuation else { return }
        conflictContinuation = nil
        c.resume(returning: commitAnyway)
    }

    /// Called when the capture window goes away (CQ-02): a pending calendar-conflict prompt
    /// resolves to cancel — the safe default — so the suspended calendar pass finishes and
    /// that time-blocked task stays uncommitted.
    ///
    /// Safe to call unconditionally: `resolveConflict` nil-guards and nils the continuation
    /// before resuming, so teardown with nothing pending is a no-op and double-resume is
    /// structurally impossible. Also flags the VM so a conflict raised AFTER the window is
    /// gone (the post-commit close leg) auto-cancels instead of suspending forever.
    func teardown() {
        isTornDown = true
        resolveConflict(commitAnyway: false)
    }

    private static func describe(_ e: CalendarError) -> String {
        switch e {
        case .accessDenied: return "Calendar access not granted"
        case .eventNotFound: return "Calendar event not found"
        case .underlying(let m): return m
        }
    }

    // MARK: - Private

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = text
        let url = draftURL
        autosaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)   // 30ms debounce
            } catch {
                return   // cancelled — do not write
            }
            try? snapshot.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
